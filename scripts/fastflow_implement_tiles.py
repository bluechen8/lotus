#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

# This script is similar to RapidWright's PerformanceExplorer, but has several
# enhancements tailored to our use case:
# - Reduces work by implementing the place and route steps separately (with
#   multiple route options, place runs only once and is reused)
# - Times out slow route jobs that are likely bound to fail, which in practice
#   are a major source of slowdown
# - Initially explores all pblocks, then focuses on the pblock with the worst
#   slack, reducing time to get to a reasonable solution (PerformanceExplorer
#   goes pblock by pblock, often spending hours on pblocks that already have a
#   good enough result)
# - Restartable, you can kill it anytime and when restarted, it will reuse
#   finished jobs
# - Reports current status
#
# NOTE(dsm 2026-05-16): Coded with AI (GPT-5.3-Codex)

import argparse
import hashlib
import re
import shlex
import subprocess
import sys
import time
from collections import defaultdict, deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# ---------------------------- Job states ----------------------------
PENDING = "PENDING"
RUNNING = "RUNNING"
FINISHED = "FINISHED"
FAILED = "FAILED"
TIMED_OUT = "TIMED_OUT"

ROUTE_READY = "READY"
ROUTE_BLOCKED = "BLOCKED"

# ---------------------------- Data classes ----------------------------
@dataclass
class PlaceJob:
    jid: str
    pblock_idx: int
    pblock: str
    place_directive: str
    clock_uncertainty: str
    run_dir: Path
    placed_dcp: Path
    state: str = PENDING
    attempts: int = 0
    dependents: List[str] = field(default_factory=list)


@dataclass
class RouteJob:
    jid: str
    pblock_idx: int
    place_jid: str
    place_directive: str
    clock_uncertainty: str
    route_directive: str
    run_dir: Path
    slack_file: Path
    state: str = ROUTE_BLOCKED
    attempts: int = 0
    slack: Optional[float] = None


@dataclass
class RunningProc:
    kind: str               # "place" or "route"
    jid: str
    pblock_idx: int
    proc: subprocess.Popen
    logf: object
    start_time: float


# ---------------------------- Utility ----------------------------
def sanitize(s: str, max_len: int = 24) -> str:
    x = re.sub(r"[^A-Za-z0-9_.-]+", "_", s).strip("_")
    if not x:
        x = "x"
    return x[:max_len]


def stable_uid(*parts: str, n: int = 8) -> str:
    h = hashlib.sha1("|".join(parts).encode("utf-8")).hexdigest()
    return h[:n]


def read_lines(path: Path) -> List[str]:
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append(line)
    return out


def parse_options_file(path: Path) -> Tuple[List[str], List[str], List[str]]:
    """
    Supported formats:

    1) Section format:
      [place_directives]
      Explore
      ExtraPostPlacementOpt

      [clock_uncertainty]
      0.1
      0.2

      [route_directives]
      Explore
      AggressiveExplore

    2) key=value format:
      place_directives=Explore,ExtraPostPlacementOpt
      clock_uncertainty=0.1,0.2
      route_directives=Explore,AggressiveExplore
    """
    place, clocks, route = [], [], []
    mode = None

    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            if section in ("place_directives", "place", "placedirectives"):
                mode = "place"
            elif section in ("clock_uncertainty", "clock", "clock_uncertainties"):
                mode = "clock"
            elif section in ("route_directives", "route", "routedirectives"):
                mode = "route"
            else:
                mode = None
            continue

        if "=" in line:
            k, v = line.split("=", 1)
            key = k.strip().lower()
            vals = [x.strip() for x in v.split(",") if x.strip()]
            if key in ("place_directives", "place"):
                place.extend(vals)
            elif key in ("clock_uncertainty", "clock"):
                clocks.extend(vals)
            elif key in ("route_directives", "route"):
                route.extend(vals)
            continue

        if mode == "place":
            place.append(line)
        elif mode == "clock":
            clocks.append(line)
        elif mode == "route":
            route.append(line)

    if not place or not clocks or not route:
        raise ValueError(
            "options file must provide place directives, clock_uncertainty values, and route directives"
        )

    return place, clocks, route


# ---------------------------- Scheduler ----------------------------
class PRScheduler:
    def __init__(
        self,
        input_dcp: Path,
        pblocks_file: Path,
        options_file: Path,
        workdir: Path,
        max_parallel: int,
        status_interval: int = 10,
        max_place_retries: int = 1,
    ):
        self.input_dcp = input_dcp.resolve()
        self.workdir = workdir.resolve()
        self.max_parallel = max_parallel
        self.status_interval = status_interval
        self.max_place_retries = max_place_retries

        self.workdir.mkdir(parents=True, exist_ok=True)

        self.pblocks = read_lines(pblocks_file)
        if not self.pblocks:
            raise ValueError("No pblocks found in pblocks file")

        self.place_directives, clock_uncertainty_range, self.route_directives = parse_options_file(options_file)

        (cu_start, cu_end, cu_step) = [float(x) for x in clock_uncertainty_range[0].strip().split(":")]
        cu_num = int((cu_end - cu_start) / cu_step)
        def trim_trailing_zeros(s):
            while len(s) > 1 and (s[-1] == '0' or s[-1] == '.'):
                s = s[:-1]
            return s
        self.clock_uncertainties = [trim_trailing_zeros(f"{(cu_start + n*cu_step):.6f}") for n in range(cu_num)]
        #print(self.clock_uncertainties, cu_start, cu_end, cu_step)
        #sys.exit(-1)

        self.place_jobs: Dict[str, PlaceJob] = {}
        self.route_jobs: Dict[str, RouteJob] = {}

        self.pending_place: Dict[int, deque] = defaultdict(deque)
        self.pending_route: Dict[int, deque] = defaultdict(deque)

        self.running: Dict[Tuple[str, str], RunningProc] = {}
        self.running_count_per_pblock: Dict[int, int] = defaultdict(int)

        self.best_slack: Dict[int, Optional[float]] = {i: None for i in range(len(self.pblocks))}
        self.rr_cursor = 0

        # Route runtime stats for timeout policy (successful routes only)
        self.route_runtime_sum: Dict[int, float] = defaultdict(float)
        self.route_runtime_count: Dict[int, int] = defaultdict(int)

        self._build_jobs()
        self._recover_finished_and_init_queues()

    # ---------- Build job graph ----------
    def _build_jobs(self):
        for pidx, pblock in enumerate(self.pblocks):
            for pd in self.place_directives:
                for cu in self.clock_uncertainties:
                    pid = f"P|{pidx}|{pd}|{cu}"
                    puid = stable_uid("place", str(pidx), pblock, pd, cu)
                    pdir_name = f"place_{pidx}_{sanitize(pd)}_{sanitize(cu)}_{puid}"
                    pdir = self.workdir / pdir_name

                    pj = PlaceJob(
                        jid=pid,
                        pblock_idx=pidx,
                        pblock=pblock,
                        place_directive=pd,
                        clock_uncertainty=cu,
                        run_dir=pdir,
                        placed_dcp=pdir / "placed.dcp",
                    )
                    self.place_jobs[pid] = pj

                    for rd in self.route_directives:
                        rid = f"R|{pidx}|{pd}|{cu}|{rd}"
                        ruid = stable_uid("route", str(pidx), pblock, pd, cu, rd)
                        rdir_name = f"route_{pidx}_{sanitize(pd)}_{sanitize(cu)}_{sanitize(rd)}_{ruid}"
                        rdir = self.workdir / rdir_name

                        rj = RouteJob(
                            jid=rid,
                            pblock_idx=pidx,
                            place_jid=pid,
                            place_directive=pd,
                            clock_uncertainty=cu,
                            route_directive=rd,
                            run_dir=rdir,
                            slack_file=rdir / "slack.twr",
                        )
                        self.route_jobs[rid] = rj
                        pj.dependents.append(rid)

    # ---------- TCL generation ----------
    def _tcl_brace(self, s: str) -> str:
        # Safe-ish Tcl braced token
        return "{" + s.replace("}", r"\}") + "}"

    def _tcl_path(self, p: Path) -> str:
        return self._tcl_brace(str(p.resolve()).replace("\\", "/"))

    def _pblock_tcl_lines(self, pblock_line: str) -> List[str]:
        """
        Supports:
          1) Raw Tcl command line (create_pblock / resize_pblock / ...)
          2) Region string (e.g. SLICE_X0Y0:SLICE_X99Y99), mapped to auto_pblock.
        """
        s = pblock_line.strip()
        if not s:
            return []

        if re.match(r"^(create_pblock|resize_pblock|add_cells_to_pblock|set_property|delete_pblock|if|foreach|set)\b", s):
            return [s]

        return [
            "create_pblock auto_pblock",
            f"resize_pblock auto_pblock -add {self._tcl_brace(s)}",
            "add_cells_to_pblock auto_pblock [get_cells -hierarchical *]",
            "set_property CONTAIN_ROUTING 1 [get_pblocks auto_pblock]"
        ]

    def _write_place_tcl(self, pj: PlaceJob):
        lines = [
            f"open_checkpoint {self._tcl_path(self.input_dcp)}",
            "",
            "# Apply pblock",
            *self._pblock_tcl_lines(pj.pblock),
            "",
            "# Apply clock uncertainty to all clocks",
            f"set_clock_uncertainty -setup {str(pj.clock_uncertainty)} [all_clocks]",
            f"place_design -directive {self._tcl_brace(pj.place_directive)}",
            "set_clock_uncertainty -setup 0.0 [all_clocks]",
            "write_checkpoint -force placed.dcp",
            "exit",
        ]
        (pj.run_dir / "place.tcl").write_text("\n".join(lines) + "\n")

    def _write_route_tcl(self, rj: RouteJob):
        place_dcp = self.place_jobs[rj.place_jid].placed_dcp
        lines = [
            f"open_checkpoint {self._tcl_path(place_dcp)}",
            f"route_design -directive {self._tcl_brace(rj.route_directive)}",
            "write_checkpoint -force routed.dcp",
            "report_timing -file timing.txt",
            "report_design_analysis -file congestion.txt -congestion",
            "# Extract worst setup slack into slack.twr",
            "set wns -9999.0",
            "set paths [get_timing_paths -setup -max_paths 1 -nworst 1]",
            "if {[llength $paths] > 0} {",
            "  set wns [get_property SLACK [lindex $paths 0]]",
            "}",
            "set fp [open slack.twr w]",
            "puts $fp $wns",
            "close $fp",
            "exit",
        ]
        (rj.run_dir / "route.tcl").write_text("\n".join(lines) + "\n")

    # ---------- Marker helpers ----------
    def _touch_finished_place(self, d: Path):
        (d / ".finished").write_text("ok\n")

    def _touch_finished_route(self, d: Path, elapsed_sec: float):
        (d / ".finished").write_text(f"ok runtime_sec={elapsed_sec:.3f}\n")

    def _mark_route_timeout(self, rj: RouteJob, elapsed_sec: float):
        rj.state = TIMED_OUT
        (rj.run_dir / ".timeout").write_text(f"timed out after {elapsed_sec:.2f}s\n")

    def _mark_route_failed(self, rj: RouteJob, reason: str):
        rj.state = FAILED
        (rj.run_dir / ".failed").write_text(reason.rstrip() + "\n")

    def _parse_runtime_from_finished(self, marker: Path) -> Optional[float]:
        try:
            txt = marker.read_text()
            m = re.search(r"runtime_sec=([0-9]+(?:\.[0-9]+)?)", txt)
            if m:
                return float(m.group(1))
        except Exception:
            pass
        return None

    # ---------- Parse outputs ----------
    def _read_slack(self, slack_file: Path) -> Optional[float]:
        try:
            txt = slack_file.read_text().strip().split()[0]
            return float(txt)
        except Exception:
            return None

    def _route_log_has_not_legally_routed(self, run_dir: Path) -> bool:
        vlog = run_dir / "vivado.log"
        try:
            return "not legally routed" in vlog.read_text(errors="ignore").lower()
        except Exception:
            return False

    # ---------- Recovery ----------
    def _recover_finished_and_init_queues(self):
        # Recover place jobs
        for pj in self.place_jobs.values():
            finished_marker = pj.run_dir / ".finished"
            if finished_marker.exists() and pj.placed_dcp.exists():
                pj.state = FINISHED
            else:
                pj.state = PENDING

        # Recover route jobs
        for rj in self.route_jobs.values():
            timeout_marker = rj.run_dir / ".timeout"
            failed_marker = rj.run_dir / ".failed"
            finished_marker = rj.run_dir / ".finished"

            if timeout_marker.exists():
                rj.state = TIMED_OUT
                continue

            if failed_marker.exists():
                rj.state = FAILED
                continue

            if finished_marker.exists() and rj.slack_file.exists():
                slack = self._read_slack(rj.slack_file)
                if slack is not None:
                    rj.state = FINISHED
                    rj.slack = slack
                    self._update_best_slack(rj.pblock_idx, slack)

                    rt = self._parse_runtime_from_finished(finished_marker)
                    if rt is not None:
                        self.route_runtime_sum[rj.pblock_idx] += rt
                        self.route_runtime_count[rj.pblock_idx] += 1
                else:
                    rj.state = ROUTE_BLOCKED
            else:
                rj.state = ROUTE_BLOCKED

        # Infer place FINISHED from finished routes if placed.dcp exists
        for rj in self.route_jobs.values():
            if rj.state == FINISHED:
                pj = self.place_jobs[rj.place_jid]
                if pj.placed_dcp.exists():
                    pj.state = FINISHED

        # Init queues
        for pj in self.place_jobs.values():
            if pj.state == PENDING:
                self.pending_place[pj.pblock_idx].append(pj.jid)

        for rj in self.route_jobs.values():
            if rj.state in (FINISHED, FAILED, TIMED_OUT):
                continue
            pj = self.place_jobs[rj.place_jid]
            if pj.state == FINISHED:
                rj.state = ROUTE_READY
                self.pending_route[rj.pblock_idx].append(rj.jid)
            elif pj.state == FAILED:
                rj.state = FAILED
            else:
                rj.state = ROUTE_BLOCKED

    # ---------- Metrics ----------
    @property
    def total_jobs(self):
        return len(self.place_jobs) + len(self.route_jobs)

    @property
    def total_route_jobs(self):
        return len(self.route_jobs)

    def _finished_place_jobs(self):
        return sum(1 for j in self.place_jobs.values() if j.state == FINISHED)

    def _finished_route_jobs(self):
        return sum(1 for j in self.route_jobs.values() if j.state == FINISHED)

    def _failed_route_jobs(self):
        return sum(1 for j in self.route_jobs.values() if j.state == FAILED)

    def _timeout_route_jobs(self):
        return sum(1 for j in self.route_jobs.values() if j.state == TIMED_OUT)

    def _terminal_route_jobs(self):
        return sum(
            1 for j in self.route_jobs.values()
            if j.state in (FINISHED, FAILED, TIMED_OUT)
        )

    def _finished_jobs_success(self):
        return self._finished_place_jobs() + self._finished_route_jobs()

    def _remaining_jobs(self):
        # Not terminal, not running
        cnt = 0
        for j in self.place_jobs.values():
            if j.state not in (FINISHED, RUNNING, FAILED):
                cnt += 1
        for j in self.route_jobs.values():
            if j.state not in (FINISHED, RUNNING, FAILED, TIMED_OUT):
                cnt += 1
        return cnt

    def _has_active_work(self):
        if self.running:
            return True
        if any(j.state == PENDING for j in self.place_jobs.values()):
            return True
        if any(j.state == ROUTE_READY for j in self.route_jobs.values()):
            return True

        # Blocked routes can become ready if dependent place is pending/running
        for rj in self.route_jobs.values():
            if rj.state == ROUTE_BLOCKED:
                pj = self.place_jobs[rj.place_jid]
                if pj.state in (PENDING, RUNNING):
                    return True
        return False

    def _update_best_slack(self, pidx: int, slack: float):
        cur = self.best_slack[pidx]
        if cur is None or slack > cur:
            self.best_slack[pidx] = slack

    # ---------- Timeout policy (route only) ----------
    def _route_timeout_limit(self, pidx: int) -> Optional[float]:
        cnt = self.route_runtime_count[pidx]
        if cnt < 2:
            return None
        avg = self.route_runtime_sum[pidx] / cnt
        return 4.0 * avg

    # ---------- Scheduling ----------
    def _use_focus_mode(self):
        # Focus after 10% of route jobs are terminal (ok/fail/timeout)
        threshold = max(1, int(0.10 * self.total_route_jobs))
        return self._terminal_route_jobs() >= threshold

    def _launchable_pblocks(self) -> List[int]:
        cands = []
        for pidx in range(len(self.pblocks)):
            if self.pending_route[pidx] or self.pending_place[pidx]:
                cands.append(pidx)
        return cands

    def _choose_pblock_balanced(self) -> Optional[int]:
        cands = self._launchable_pblocks()
        if not cands:
            return None

        min_run = min(self.running_count_per_pblock[i] for i in cands)
        best = {i for i in cands if self.running_count_per_pblock[i] == min_run}

        n = len(self.pblocks)
        for _ in range(n):
            idx = self.rr_cursor % n
            self.rr_cursor += 1
            if idx in best:
                return idx
        return next(iter(best))

    def _choose_pblock_worst_slack(self) -> Optional[int]:
        cands = self._launchable_pblocks()
        if not cands:
            return None

        def score(pidx: int):
            s = self.best_slack[pidx]
            sval = float("-inf") if s is None else s   # unknown treated as worst
            return (sval, self.running_count_per_pblock[pidx])

        return min(cands, key=score)

    def _pick_next_job(self) -> Optional[Tuple[str, str]]:
        pidx = self._choose_pblock_worst_slack() if self._use_focus_mode() else self._choose_pblock_balanced()
        if pidx is None:
            return None

        # Prefer route first for faster slack feedback
        if self.pending_route[pidx]:
            return ("route", self.pending_route[pidx].popleft())
        if self.pending_place[pidx]:
            return ("place", self.pending_place[pidx].popleft())
        return None

    # ---------- Launch ----------
    def _start_place(self, pj: PlaceJob):
        pj.run_dir.mkdir(parents=True, exist_ok=True)
        self._write_place_tcl(pj)

        script = "\n".join([
            "set -e",
            "vivado -mode batch -source place.tcl -log vivado.log -journal vivado.jou",
        ])

        logf = open(pj.run_dir / "job.log", "a", buffering=1)
        proc = subprocess.Popen(
            ["bash", "-lc", script],
            cwd=str(pj.run_dir),
            stdout=logf,
            stderr=subprocess.STDOUT,
        )

        pj.state = RUNNING
        pj.attempts += 1
        self.running[("place", pj.jid)] = RunningProc(
            kind="place",
            jid=pj.jid,
            pblock_idx=pj.pblock_idx,
            proc=proc,
            logf=logf,
            start_time=time.time(),
        )
        self.running_count_per_pblock[pj.pblock_idx] += 1

    def _start_route(self, rj: RouteJob):
        rj.run_dir.mkdir(parents=True, exist_ok=True)
        self._write_route_tcl(rj)

        script = "\n".join([
            "set -e",
            "vivado -mode batch -source route.tcl -log vivado.log -journal vivado.jou",
        ])

        logf = open(rj.run_dir / "job.log", "a", buffering=1)
        proc = subprocess.Popen(
            ["bash", "-lc", script],
            cwd=str(rj.run_dir),
            stdout=logf,
            stderr=subprocess.STDOUT,
        )

        rj.state = RUNNING
        rj.attempts += 1
        self.running[("route", rj.jid)] = RunningProc(
            kind="route",
            jid=rj.jid,
            pblock_idx=rj.pblock_idx,
            proc=proc,
            logf=logf,
            start_time=time.time(),
        )
        self.running_count_per_pblock[rj.pblock_idx] += 1

    # ---------- Completion ----------
    def _finish_place(self, pj: PlaceJob, rc: int):
        ok = (rc == 0 and pj.placed_dcp.exists())
        if ok:
            pj.state = FINISHED
            self._touch_finished_place(pj.run_dir)

            # Unblock dependents
            for rid in pj.dependents:
                rj = self.route_jobs[rid]
                if rj.state == ROUTE_BLOCKED:
                    rj.state = ROUTE_READY
                    self.pending_route[rj.pblock_idx].append(rid)
            return

        # Place retry policy only
        if pj.attempts <= self.max_place_retries:
            pj.state = PENDING
            self.pending_place[pj.pblock_idx].append(pj.jid)
        else:
            pj.state = FAILED
            for rid in pj.dependents:
                rj = self.route_jobs[rid]
                if rj.state in (ROUTE_BLOCKED, ROUTE_READY):
                    rj.state = FAILED

    def _finish_route(self, rj: RouteJob, rc: int, elapsed_sec: float):
        # Rule: if "not legally routed" appears in vivado.log, mark failed.
        if self._route_log_has_not_legally_routed(rj.run_dir):
            self._mark_route_failed(rj, "not legally routed")
            return

        slack = self._read_slack(rj.slack_file) if (rc == 0 and rj.slack_file.exists()) else None
        if slack is not None:
            rj.state = FINISHED
            rj.slack = slack
            self._touch_finished_route(rj.run_dir, elapsed_sec)
            self._update_best_slack(rj.pblock_idx, slack)
            self.route_runtime_sum[rj.pblock_idx] += elapsed_sec
            self.route_runtime_count[rj.pblock_idx] += 1
            return

        # Route failures are terminal (no retry)
        self._mark_route_failed(rj, f"route failed (rc={rc}); no valid slack.twr slack")

    def _poll_running(self):
        now = time.time()

        # 1) Timeout enforcement (route only)
        timed_out_entries = []
        for key, rp in list(self.running.items()):
            if rp.kind != "route":
                continue

            limit = self._route_timeout_limit(rp.pblock_idx)
            if limit is None:
                continue

            elapsed = now - rp.start_time
            if elapsed > limit and rp.proc.poll() is None:
                try:
                    rp.proc.terminate()
                except Exception:
                    pass
                time.sleep(0.2)
                if rp.proc.poll() is None:
                    try:
                        rp.proc.kill()
                    except Exception:
                        pass
                timed_out_entries.append((key, rp, elapsed))

        for key, rp, elapsed in timed_out_entries:
            try:
                rp.logf.close()
            except Exception:
                pass
            self.running_count_per_pblock[rp.pblock_idx] -= 1
            del self.running[key]
            rj = self.route_jobs[rp.jid]
            self._mark_route_timeout(rj, elapsed)

        # 2) Normal completion handling
        done = []
        for key, rp in list(self.running.items()):
            rc = rp.proc.poll()
            if rc is not None:
                elapsed = time.time() - rp.start_time
                done.append((key, rp, rc, elapsed))

        for key, rp, rc, elapsed in done:
            try:
                rp.logf.close()
            except Exception:
                pass
            self.running_count_per_pblock[rp.pblock_idx] -= 1
            del self.running[key]

            if rp.kind == "place":
                self._finish_place(self.place_jobs[rp.jid], rc)
            else:
                self._finish_route(self.route_jobs[rp.jid], rc, elapsed)

    # ---------- Status ----------
    def _status_lines(self) -> List[str]:
        lines = []
        route_ok = self._finished_route_jobs()
        route_to = self._timeout_route_jobs()
        route_fail = self._failed_route_jobs()

        lines.append(
            f"Global: {self.total_jobs} jobs total, {self._finished_jobs_success()} finished, "
            f"{len(self.running)} running, {self._remaining_jobs()} to run | "
            f"route ok={route_ok}, timeout={route_to}, failed={route_fail}"
        )

        running_place = defaultdict(int)
        running_route = defaultdict(int)
        for rp in self.running.values():
            if rp.kind == "place":
                running_place[rp.pblock_idx] += 1
            else:
                running_route[rp.pblock_idx] += 1

        for i in range(len(self.pblocks)):
            best = self.best_slack[i]
            best_s = "N/A" if best is None else f"{best:.3f}ns"
            ok_i = sum(1 for r in self.route_jobs.values() if r.pblock_idx == i and r.state == FINISHED)
            to_i = sum(1 for r in self.route_jobs.values() if r.pblock_idx == i and r.state == TIMED_OUT)
            fail_i = sum(1 for r in self.route_jobs.values() if r.pblock_idx == i and r.state == FAILED)

            lines.append(
                f"pblock{i}: best slack {best_s}, {ok_i} route ok, {to_i} timed-out, {fail_i} failed, "
                f"{running_place[i]} place jobs running, {running_route[i]} route jobs running"
            )
        return lines

    def _print_status(self):
        # Paint over previous output
        sys.stdout.write("\033[2J\033[H")
        sys.stdout.write("\n".join(self._status_lines()) + "\n")
        sys.stdout.flush()

    # ---------- Main loop ----------
    def run(self):
        next_status = 0.0
        while self._has_active_work():
            self._poll_running()

            while len(self.running) < self.max_parallel:
                nxt = self._pick_next_job()
                if nxt is None:
                    break
                kind, jid = nxt
                if kind == "place":
                    self._start_place(self.place_jobs[jid])
                else:
                    self._start_route(self.route_jobs[jid])

            now = time.time()
            if now >= next_status:
                self._print_status()
                next_status = now + self.status_interval

            time.sleep(0.5)

        self._print_status()

    def stop_all(self):
        for rp in list(self.running.values()):
            try:
                rp.proc.terminate()
            except Exception:
                pass
        time.sleep(1.0)
        for rp in list(self.running.values()):
            if rp.proc.poll() is None:
                try:
                    rp.proc.kill()
                except Exception:
                    pass


# ---------------------------- CLI ----------------------------
def main():
    ap = argparse.ArgumentParser(description="Parallel place-and-route scheduler")
    ap.add_argument("--dcp", required=True, type=Path, help="Input synthesized DCP file")
    ap.add_argument("--pblocks", required=True, type=Path, help="Pblocks file (one pblock per line)")
    ap.add_argument("--options", required=True, type=Path, help="Implementation options file")
    ap.add_argument("--workdir", default=Path("runs"), type=Path, help="Run directory")
    ap.add_argument("--max-parallel", default=16, type=int, help="Maximum number of concurrent jobs")
    ap.add_argument("--status-interval", default=10, type=int, help="Status print interval (s)")
    ap.add_argument("--max-place-retries", default=1, type=int, help="Retries for place jobs only")
    args = ap.parse_args()

    sch = PRScheduler(
        input_dcp=args.dcp,
        pblocks_file=args.pblocks,
        options_file=args.options,
        workdir=args.workdir,
        max_parallel=args.max_parallel,
        status_interval=args.status_interval,
        max_place_retries=args.max_place_retries,
    )

    try:
        sch.run()
    except KeyboardInterrupt:
        sch.stop_all()
        print("\nInterrupted. Safe to restart; .finished/.timeout/.failed markers are reused.")


if __name__ == "__main__":
    main()
