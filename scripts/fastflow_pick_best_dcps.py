# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

# Picks the best DCPs among those produced by rapidwright PerformanceExplorer,
# and optionally produces relocatable ones.

import os, subprocess, sys

# Kill all children processes if this script dies
from ctypes import cdll
def autoterm():
    PR_SET_PDEATHSIG = 1
    SIGTERM = 15
    result = cdll['libc.so.6'].prctl(PR_SET_PDEATHSIG, SIGTERM)
    if result != 0:
        print("ERROR: prctl() failed")
        sys.exit(0)
autoterm()

# Get base pblock names
pblockNames = []
for line in open("tilegen.txt", "r").readlines():
    l = line.strip()
    if l.startswith("#") or "," not in l:
        continue
    comps = [c.strip() for c in l.split(",")]
    pblockNames.append(f"{comps[0]}_{comps[1]}")

# Use ripgrep, it's orders of magnitude faster than grep here...
grepRes = subprocess.run('rg -c --color never "not legally routed" */vivado.log', shell=True, capture_output=True, text=True)
notRoutedDirs = set(line.split("/")[0].strip() for line in str(grepRes.stdout).split("\n") if "/" in line)

results = []
subdirs = next(os.walk('.'))[1]
for dir in subdirs:
    timingFile = os.path.join(dir, "timing.txt")
    if os.path.exists(timingFile):
        timingInfo = open(timingFile, "r").read()
        for line in timingInfo.split("\n"):
            if line.startswith("Slack"):
                pblock = int(dir.split("route_")[1].split("_")[0])
                slack = float(line.split(":")[1].split("ns")[0])
                # Use 0/1 to sort designs that didn't route lower
                routed = 0 if dir in notRoutedDirs else 1
                results.append((pblock, routed, slack, dir))
                break

pblocks = set(x[0] for x in results)
best = [None] * len(pblocks)
for (pblock, routed, slack, dir) in sorted(results):
    best[pblock] = (slack, dir)

for pblock in range(len(best)):
    (slack, dir) = best[pblock]
    slacks = list(sorted([s for (p, r, s, __) in results if p == pblock and r == 1]))
    routingFailed = sum([1-r for (p, r, s, __) in results if p == pblock])
    print(f"{pblockNames[pblock]} (pblock{pblock}) best slack {slack:.3f}ns:  {dir}  [best of {len(slacks)} runs; slack avg {(sum(slacks)/len(slacks)):.3f}ns, median {(slacks[len(slacks) // 2]):.3f}ns, worst {slacks[0]:.3f}ns; {routingFailed} not legally routed]")

if "--produceBaseDCPs" in sys.argv:
    scriptDir = os.path.dirname(os.path.realpath(__file__))
    procs = []
    for pblock in range(len(best)):
        (_, dir) = best[pblock]
        p = subprocess.Popen(f"vivado -nojournal -nolog -mode batch -source {scriptDir}/fastflow_prep_for_reloc.tcl -tclArgs {dir}/routed.dcp {pblockNames[pblock]}.dcp",
            shell=True, stdin=None, stdout=None, stderr=None, text=True)
        procs.append(p)
    for p in procs:
        p.wait()
