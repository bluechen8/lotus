#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import json
import concurrent.futures
import threading
import subprocess
from pprint import pprint
import re
from datetime import datetime
import pandas as pd
import os
import argparse
from enum import Enum
from pathlib import Path


class Flock:
    import fcntl
    class T(Enum):
        EX = 1
        SH = 2

    def __init__(self, name):
        self.name = name
        self.locked = False
        self.fd = os.open(self.name, os.O_RDWR | os.O_CREAT | os.O_TRUNC)

    def __del__(self):
        os.close(self.fd)

    def unlock(self):
        if not self.locked:
            return
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        assert self.locked, f"Should be locked"
        self.locked = False
        print(f"Release Lock: `{self.name}`")

    def lock(self, type):
        if self.locked:
            return True

        print(f"Doing blocking lock on file: `{self.name}` with type=`{type}`")

        t = None
        if type == Flock.T.EX:
            t = fcntl.LOCK_EX
        elif type == Flock.T.SH:
            t = fcntl.LOCK_SH
        else:
            assert False, f"Unkonwn lock type: {type}"
        assert t is not None

        fcntl.flock(self.fd, t)

        print(f"Aquired lock: `{self.name}`")
        assert not self.locked
        self.locked = True

        return True

    def nb_lock(self, type):
        if self.locked:
            return True

        t = None
        if type == Flock.T.EX:
            t = fcntl.LOCK_EX
        elif type == Flock.T.SH:
            t = fcntl.LOCL_SH
        else:
            assert False, f"Unkonwn lock type: {type}"
        assert t is not None

        try:
            fcntl.flock(self.fd, t | fcntl.LOCK_NB)
        except OSError:
            return False
        else:
            # Managed to aquire the lock quickly, don't bother printing any noise
            assert not self.locked
            self.locked = True
            return True
import contextlib
@contextlib.contextmanager
def lock_file(filename, t):
    f = Flock(filename)
    f.lock(t)
    yield f
    f.unlock()


class AsciFg:
  black = "\u001b[30m"
  red = "\u001b[31m"
  green = "\u001b[32m"
  yellow = "\u001b[33m"
  blue = "\u001b[34m"
  magenta = "\u001b[35m"
  cyan = "\u001b[36m"
  white = "\u001b[37m"
  def rgb(r, g, b): return f"\u001b[38;2;{r};{g};{b}m"

class AsciUtil:
  reset = "\u001b[0m"
  bold = "\u001b[1m"
  underline = "\u001b[4m"
  reverse = "\u001b[7m"
  clear = "\u001b[2J"
  clearline = "\u001b[2K"
  up = "\u001b[1A"
  down = "\u001b[1B"
  right = "\u001b[1C"
  left = "\u001b[1D"
  nextline = "\u001b[1E"
  prevline = "\u001b[1F"
  top = "\u001b[0;0H"
  def to(x, y):
    return f"\u001b[{y};{x}H"

__timeStr = None
def getTimeSig():
    global __timeStr
    if __timeStr is None:
        startScriptTime = datetime.now()
        __timeStr = startScriptTime.strftime("%Y_%m_%d__%H_%M_%S")
    assert __timeStr is not None, f"Should get a valid time"
    return __timeStr

def getBuildSig(args):
    b = getTimeSig()
    if args.buildName:
        b = f"sweep___{args.buildName}__{b}"
    return b

def exec(args):
    ex = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=True)
    res = ex.stdout.decode().split("\n")
    res = [r.replace("\n", "") for r in res if r]
    return res

def run_func_parallel(name, func, max_workers, args):
    results = []
    print(f"[run_func_parallel::{name}] Launching {len(args)} runs with {max_workers} workers")
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = []
        for i, arg in enumerate(args):
            futures.append(executor.submit(func, i, *arg))

        try:
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                results.append(result)
                print(f'[run_func_parallel::{name}] Completed {len(results)} out of {len(args)} commands')
        except:
            cancels = 0
            for future in futures:
                cancels += future.cancel()
            print(f'[run_func_parallel::{name}] Cancelled {cancels} remaining unstarted builds due to error')
            executor.shutdown(wait=False)
            raise

    results = sorted(results, key=lambda x:x[0])
    results = [res for _, res in results]
    return results

def run_func_serial(name, func, args):
    results = []
    print(f"[run_func_serial::{name}] Launching {len(args)} runs")
    for i, arg in enumerate(args):
        assert len(arg) == 1
        r = func(i, arg[0])
        results.append(r)
        print(f'[run_func_serial::{name}] Completed {len(results)} out of {len(args)} commands')

    results = sorted(results, key=lambda x:x[0])
    results = [res for _, res in results]
    return results

def run_func_resource(name, func, args, resources):
    results = []
    print(f"[run_func_resource::{name}] Launching {len(args)} runs with {len(resources)} workers and resources {resources}")

    resource_locks = {resource: threading.Lock() for resource in resources}

    def wrapped_func(i, resource, *arg):
        with resource_locks[resource]:
            return func(i, resource, *arg)

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(resources)) as executor:
        futures = []
        for i, arg in enumerate(args):
            # Round-robin assignment of resources
            resource = resources[i % len(resources)]
            futures.append(executor.submit(wrapped_func, i, resource, *arg))

        try:
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                results.append(result)
                print(f'[run_func_resource::{name}] Completed {len(results)} out of {len(args)} commands')
        except Exception as e:
            cancels = 0
            for future in futures:
                cancels += future.cancel()
            print(f'[run_func_resource::{name}] Cancelled {cancels} remaining unstarted builds due to error: {e}')
            executor.shutdown(wait=False)
            raise

    results = sorted(results, key=lambda x: x[0])
    results = [res for _, res in results]
    return results

def isDebugSweep(args):
    #return args.trace or (args.debugFlags is not None)
    return args.trace

def getAbsBuildPath():
    assert os.path.exists("build"), f"Some build directory should have been created"
    baseBuildDir = "build"
    if os.path.islink(baseBuildDir):
        baseBuildDir = Path(baseBuildDir).resolve()
    return baseBuildDir

def genBuildPath(baseBuildDir, cfg, isDbg):
    baseDebug    = ""
    if isDbg:
        baseDebug = "debug_"
    name = f"{baseBuildDir}/{baseDebug}{cfg['cfg']}{cfg['devices']}d{cfg['tiles']}t{cfg['coresPerTile']}c{cfg['threadsPerCore']}w{cfg['l2CacheSizeKb']}l2KB{cfg['tasksPerTile']}e"
    if args.frequency is not None:
        name += f"{args.frequency}MHz"
    return name

def buildConfigs(args, configs):

    def build(id, cfg, parallelism_per_build):
        # scons -j150 --cfg=serial --tiles=1 --coresPerTile=8 --threadsPerCore=2

        cmd = ["scons", f"-j{parallelism_per_build}",
               f"--cfg={cfg['cfg']}",
               f"--devices={cfg['devices']}",
               f"--tiles={cfg['tiles']}",
               f"--coresPerTile={cfg['coresPerTile']}",
               f"--threadsPerCore={cfg['threadsPerCore']}",
               f"--tasksPerTile={cfg['tasksPerTile']}",
               f"--l2CacheSizeKb={cfg['l2CacheSizeKb']}",
               f"--coarsen={cfg['coarsen']}",
               ]

        bench = cfg["benchmark"]
        for nttName in ["ntt", "CustomNTT"]:
            if nttName in bench:
                reg = re.compile(nttName + r"(\d+)")
                m   = reg.match(bench)
                assert m is not None
                nttSize = m.group(1)
                cmd.append(f"--nttSize={nttSize}")
        if "chronos" in bench:
            chronosRe  = re.compile(r"chronos(\d+)t(\d)c_(.+)")
            m = chronosRe.match(bench)
            assert m, f"Chronos Benchmark is doesn't follow correct format"
            tiles = int(m.group(1))
            cores = int(m.group(2))
            coreType = m.group(3)
            assert coreType in ["sssp", "riscv"], f"Unknown coreType: {coreType}"
            cmd.append(f"--chronosTiles={tiles}")
            cmd.append(f"--chronosCores={cores}")
            cmd.append(f"--chronosCoreType={coreType}")
        if "vortex" in bench:
            vortexRe  = re.compile(r"vortex(\d+)t(\d)c")
            m = vortexRe.match(bench)
            assert m, f"Vortex Benchmark is doesn't follow correct format"
            tiles = int(m.group(1))
            cores = int(m.group(2))
            cmd.append(f"--vortexTiles={tiles}")
            cmd.append(f"--vortexCores={cores}")

        if args.trace:
            cmd.append(f"--trace")

        if args.debugBsv:
            cmd.append("--debugBsv")

        if args.frequency:
            #assert args.target in ["hw", "hw-xclbin"]
            cmd.append(f"--frequency={args.frequency}")

        if cfg['target'] == "vl":
            cmd.append(f"{cfg['benchmark']}.vl")
        elif cfg['target'] == "hw":
            cmd.append(f"{cfg['benchmark']}.hw")
        elif cfg['target'] == "hw-xclbin":
            cmd.append(f"hw-xclbin")
        else:
            assert False, f"Unknown target: {cfg['target']}"

        print(f"cmd: {' '.join(cmd)}")
        #assert False

        lockFile = f"{cfg['buildDir']}.bench.lock"
        if not args.runOnly:
            ex = None
            with lock_file(lockFile, Flock.T.EX):
                ex = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            assert ex is not None
            status = "BUILD_WITH_NO_ERRORS"
            if ex.returncode != 0:
                logFile = f"{cfg['buildDir']}.failure"
                status = f"FAILURE -- See {logFile} file for error"
                with open(logFile, "w") as f:
                    f.write(ex.stdout.decode())

            with lock_file(f".print.lock", Flock.T.EX):
                print(f"STATUS: {status} for BUILD {cfg}")
            return (id, [ex.returncode, status])
        else:
            with lock_file(f".print.lock", Flock.T.EX):
                print(f"RUN_ONLY: for BUILD {cfg}")
            return (id, [0, "RUN_ONLY"])

    num_builds_in_parallel = 24
    parallelism_per_build = 60

    isDbg        = isDebugSweep(args)
    baseBuildDir = getAbsBuildPath()
    for cfg in configs:
        cfg["buildDir"] = genBuildPath(baseBuildDir, cfg, isDbg)

    configs.dumpConfig(f"{baseBuildDir}/{getBuildSig(args)}.cfg")
    argz = [[cfg, parallelism_per_build] for cfg in configs]
    results = run_func_parallel("buildConfigs", build, num_builds_in_parallel, argz)

    for cfg, res in zip(configs, results):
        cfg['buildResult'] = res

def runConfigs(target, configs):
    startRe  = re.compile(r"\[(\d*)\] Waiting until completion")
    endRe    = re.compile(r"\[(\d*)\] Execution completed")
    timedOutRe = re.compile(r"\[(\d*)\] APPLICATION TIMED OUT!!")
    def run(id, fpga_id, cfg):
        #if cfg['buildResult'][0] != 0:
        #    with lock_file(f".print.lock", Flock.T.EX):
        #        print(f"STATUS: NOT RUNNING BECAUSE BUILD FAILED for RUN {cfg}")
        #    return (id, [-1, "SKIPPED", 0])
        bench = cfg["benchmark"]
        lines = None
        lockFile = f"{cfg['buildDir']}/{bench}.lock"
        with lock_file(lockFile, Flock.T.EX):
            assert cfg['target'] in ["vl", "hw"], f"Target must be known"
            cmd = f"./{bench}.{cfg['target']} "

            if cfg['target'] == "hw":
                cmd += f" {fpga_id} {cfg['xclbin']}"

            cmd += f" > {bench}.cout 2>&1 "

            ex = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cfg['buildDir'], shell=True)
            subprocess.run(f'grep "HOST_PRINT" {bench}.cout 2>&1 > {bench}.host_cout', cwd=cfg['buildDir'], shell=True)

            ex = subprocess.run(f"cat {bench}.cout", stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cfg['buildDir'], shell=True)
            lines = ex.stdout.decode()
            if True:
                # Get Perf Counters
                marker = "==PERF STATS START=="
                subprocess.run(f"grep -A999999 '{marker}' {bench}.cout | tail -n +2 > {bench}.perf_counters", cwd=cfg['buildDir'], shell=True)

                # Results Identifier
                restPath = cfg['buildDir']
                (restPath, buildType) = os.path.split(restPath)
                (_       , sweepId  ) = os.path.split(restPath)
                useName = f"{sweepId}____{buildType}____{bench}"

                # Generate HTML File
                subprocess.run(f"bash -c \"dashboard_generator.py {useName} {bench}.perf_counters > {useName}.html \"", cwd=cfg['buildDir'], shell=True)

                # Genreate perf_heartbeat stats
                subprocess.run(f"bash -c \"perfSummarize.py {bench}.perf_counters {useName} \"", cwd=cfg['buildDir'], shell=True)

            if cfg['target'] == 'vl':
                for file_to_compress in [f"{bench}.cout", f"{bench}.vl"]:
                    subprocess.run(f"xz -f {file_to_compress} ", cwd=cfg['buildDir'], shell=True)
                subprocess.run(f"tar -czvf {bench}.tar.gz {bench} && rm -rf {bench}", cwd=cfg['buildDir'], shell=True, capture_output=True)
            status = subprocess.run(f'grep "Execution completed" {bench}.host_cout', stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cfg['buildDir'], shell=True).stdout.decode().split("\n")[0]
            if ex.returncode != 0:
                status = "Fail=Return Code"
                with lock_file(f".print.lock", Flock.T.EX):
                    print(f"STATUS: {status} for RUN {cfg}")
                return (id, [ex.returncode, status, None])
        assert lines is not None
        lines = lines.split("\n")
        lines = [r.replace("\n", "") for r in lines if r]

        startCycle = None
        endCycle   = None
        for line in lines:
            m = startRe.match(line)
            if m is not None:
                startCycle = int(m.group(1))
                continue
            m = endRe.match(line)
            if m is not None:
                endCycle = int(m.group(1))
                continue
            m = timedOutRe.match(line)
            if m is not None:
                status = f"Fail=TimedOut At Cycle:{int(m.group(1))}"
                continue

        totalCycles = None
        if (startCycle is not None) and (endCycle is not None):
            totalCycles = endCycle - startCycle

        with lock_file(f".print.lock", Flock.T.EX):
            print(f"STATUS: {status} for RUN {cfg}")
        return (id, [ex.returncode, status, totalCycles])


    args = [[cfg] for cfg in configs]

    if target == "hw":
        #results = run_func_serial("runConfigs", run, args)
        if "stg3" in os.getenv('HOSTNAME'):
            fpga_list = ["01:00.1", "a1:00.1", "c1:00.1", "81:00.1"]
        elif "stg4" in os.getenv('HOSTNAME'):
            fpga_list = ["01:00.1", "21:00.1", "81:00.1", "c1:00.1"]
        else:
            assert False, f"Unknown hostname: {os.getenv('HOSTNAME')}"
        results = run_func_resource("runConfigs", run, args, fpga_list)
    elif target == "vl":
        num_runs_in_parallel = 40
        def run_wrapper(id, cfg):
            return run(id, None, cfg)
        results = run_func_parallel("runConfigs", run_wrapper, num_runs_in_parallel, args)
    else:
        assert False, f"Unknown target: {target}"

    for cfg, res in zip(configs, results):
        cfg[f'runResult-{cfg["benchmark"]}'] = res
    pass


class Configs:
    def __init__(self, cfgs=None):
        if cfgs is None:
            cfgs = []
        self.cfgs = cfgs

    def addConfig(self, cfg, devices, tiles, coresPerTile, threadsPerCore, benchmark, l2CacheSizeKb, tasksPerTile, coarsen, target, xclbin):
        self.cfgs.append({
                'cfg':cfg,
                'devices':devices,
                'tiles':tiles,
                'coresPerTile':coresPerTile,
                'threadsPerCore':threadsPerCore,
                'benchmark':benchmark,
                'l2CacheSizeKb': l2CacheSizeKb,
                'tasksPerTile': tasksPerTile,
                'coarsen':coarsen,
                'target': target,
                'xclbin': xclbin,
                })

    def __getitem__(self, key):
        return self.cfgs[key]

    def dumpConfig(self, path):
        with open(path, "w") as outfile:
            json.dump(self.cfgs, outfile, indent=4)

    def readConfig(self, path):
        oldCfgs = None
        with open(path, "r") as infile:
            oldCfgs = json.load(infile)
        assert oldCfgs is not None
        assert type(oldCfgs) is list
        for c in oldCfgs:
            self.addConfig(c['cfg'], c['devices'], c['tiles'], c['coresPerTile'], c['threadsPerCore'], c['benchmark'], c['l2CacheSizeKb'], c['tasksPerTile'], c['coarsen'], c['target'], c['xclbin'])

def createCfgs(args):
    def try_parsing_as_input(cfgs, useCfg):
        basicFormat = re.compile(r"\( *([\w.]+) *, *([\d.]+) *, *([\d.]+) *, *([\d.]+) *, *([\d.]+) *, *([\d.]+) *\)")
        match = basicFormat.match(useCfg)
        if match is None:
            return True

        def get_range(input):
            rangeRe = re.compile(r"(\d*)\.\.(\d+)")
            match = rangeRe.match(input)
            if match is None:
                return [int(input)]
            start = int(match.group(1))
            end   = int(match.group(2))

            assert (end >= start), f"Start must be less than end: start={start} -- end={end}"

            ring = [start]
            while True:
                n = ring[-1] * 2
                if n > end:
                    break
                ring.append(n)

            return ring

        benchmarksArr     = match.group(1).split(".")
        #for b in benchmarksArr:
        #    assert b in ["ntt", "alu", "unit"]
        devicesArr        = get_range(match.group(2))
        tilesArr          = get_range(match.group(3))
        coresPerTileArr   = get_range(match.group(4))
        threadsPerCoreArr = get_range(match.group(5))
        coarsenArr        = get_range(match.group(6))
        #print(f"devices: {devicesArr}")
        #print(f"tilesArr: {tilesArr}")
        #print(f"coresPerTileArr: {coresPerTileArr}")
        #print(f"threadsPerCoreArr: {threadsPerCoreArr}")
        #print(f"coarsenArr: {coarsenArr}")
        for device in devicesArr:
            for bench in benchmarksArr:
                for cfg in ["serial"]:
                    for tiles in tilesArr:
                        for coresPerTile in coresPerTileArr:
                            for threadsPerCore in threadsPerCoreArr:
                                uca = coarsenArr
                                if "CustomNTT" in bench:
                                    uca = [1]
                                for coarsen in uca:
                                    cfgs.addConfig(cfg, device, tiles, coresPerTile, threadsPerCore, bench, args.l2CacheSizeKb, args.tasksPerTile, coarsen, args.target, args.xclbin)
        return False

    if args.target == "hw":
        assert args.xclbin is not None

    def try_parsing_as_path(cfgs, useCfg):
        if not os.path.isfile(useCfg):
            return True
        cfgs.readConfig(useCfg)
        return False

    if args.useConfig is None:
        assert False, f"Some config must be specified (--useConfig)"

    useConfig = args.useConfig
    if type(useConfig) is not list:
        useConfig = [useConfig]

    cfgs = Configs()
    for useCfg in useConfig:
        failed = try_parsing_as_input(cfgs, useCfg)
        if not failed:
            continue
        failed = try_parsing_as_path(cfgs, useCfg)
        if not failed:
            continue
        assert False, f"Don't know how to parse config: `{useCfg}`"

    return cfgs


def newBuild(args):
    b = getBuildSig(args)

    basePath = f"/scratch/{os.getenv('USER')}/sweep_lotus_build/{b}"

    usePath = None
    if not os.path.exists(basePath):
        usePath = basePath
    else:
        i = 0
        while True:
            currPath = f"{basePath}-{i}"
            if not os.path.exists(currPath):
                usePath = currPath
                break
            if (i > 100):
                print(f"ERROR: i is at: {i}")
    assert usePath is not None, f"Should have assigned a path"
    print(f"newBuild: `{usePath}`")
    os.system(f"mkdir -p {usePath} && rm -rf build && ln -s {usePath} build")

def doSweep(args, cfgs, buildLock):
    with lock_file(".sweep_worker", Flock.T.SH):
        buildPath = getAbsBuildPath()
        basePath = f"{buildPath}/{getBuildSig(args)}"

        buildConfigs(args, cfgs)
        if buildLock is not None:
            buildLock.unlock()
        pprint(cfgs.cfgs)
        cfgs.dumpConfig(f"{basePath}.build.json")

        # TODO: Add support for other targets
        if args.target in ["vl", "hw"]:
            if not args.buildOnly:
                runConfigs(args.target, cfgs)
                pprint(cfgs.cfgs)
                cfgs.dumpConfig(f"{basePath}.run.json")
        else:
            print(f"sweep.py doesnt know how to run target={args.target}")


def main(args, cfgs):
    createNewDir = not args.useOldBuild
    if createNewDir or (not os.path.exists("build")):
        #with lock_file(".sweep_changer", Flock.T.EX) as buildLock:
        #    with lock_file(".sweep_worker", Flock.T.EX):
        newBuild(args)
        doSweep(args, cfgs, None)
    else:
        doSweep(args, cfgs, None)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--buildName', default="", type=str)
    parser.add_argument('--useOldBuild', action='store_true')
    parser.add_argument('--debugBsv', action="store_true")
    parser.add_argument('--buildOnly', action="store_true")
    parser.add_argument('--runOnly', action="store_true")
    parser.add_argument('--trace', action='store_true')
    parser.add_argument('--target', default="vl", type=str)
    parser.add_argument("--tasksPerTile", default=4096, type=str)
    parser.add_argument("--l2CacheSizeKb", default=128, type=str)
    parser.add_argument("--frequency", default=None, type=str)
    parser.add_argument("--xclbin", default=None, type=str)

    parser.add_argument('--useConfig', default=None, type=str, nargs="+", help="One or more of: 1) '(nTiles, nCores, nThreads)' where any of them can be either 'x' or 'x..y' or 2) Path to previous file. ")
    args = parser.parse_args()

    cfgs = createCfgs(args)
    main(args, cfgs)




