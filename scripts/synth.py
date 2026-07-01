#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import subprocess, re, os, sys

if len(sys.argv) != 3:
    print(f"ERROR: Usage {sys.argv[0]} <buildDir> <modName>")

buildDir = sys.argv[1]
modName = sys.argv[2]
result = subprocess.run(f"vivado -mode batch -source scripts/synth.tcl -tclArgs {buildDir} {modName}", shell=True, capture_output=True, text=True)
#result = subprocess.run(f"cat vivado.log", shell=True, capture_output=True, text=True)

if result.returncode != 0:
    print("Vivado synthesis failed, see vivado.log for errors")
    sys.exit(-1)

def getUtilMetric(name):
    m = re.search(rf"\|\s+{name}\s+\|\s+(\d+)\s+\|", result.stdout)
    return int(m.group(1))

luts = getUtilMetric("CLB LUTs\*")
lutms = getUtilMetric("LUT as Memory")
regs = getUtilMetric("CLB Registers")
brams = getUtilMetric("RAMB36/FIFO\*") + getUtilMetric("RAMB18") / 2.0
urams = getUtilMetric("URAM")

delayInfo = re.search(r"Timing Report(.*)Location", result.stdout, re.DOTALL).group(1)
delayDict = dict((line.split(":")[0].strip(), line.split(":")[1].strip()) for line in delayInfo.split("\n") if ":" in line)

print(rf"{modName} takes {luts} LUTs ({lutms} as memory LUTs), {brams} BRAMs, {urams} URAMs, {regs} registers")
print(f"{modName} critical path:")
for (name, key) in [("delay", "Data Path Delay"), ("source", "Source"), ("dest", "Destination"), ("logic levels", "Logic Levels")]:
    print(f"  {name}: {delayDict[key]}")
