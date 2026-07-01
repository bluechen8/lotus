#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

#!/usr/bin/env python3
import subprocess
import os
import sys

freqs = [200, 280]

def launch(log, args):
    log_path = f"build/{log}.log"
    f = open(log_path, "w")
    f.write(f"=== Starting {log} ===\n")
    f.flush()
    proc = subprocess.Popen(
        ["scons", "-j60"] + args,
        stdout=f,
        stderr=f,
    )
    print(f"Launched {log} (pid={proc.pid})")
    return proc, f, log

procs = []  # list of (proc, file, log)

for freq in [160]:
    for tiles in [1, 4, 8, 32]:
        args = [
            "--cfg=serial",
            f"--tiles={tiles}",
            "--coresPerTile=8",
            "--devices=8",
            f"--frequency={freq}",
            "--tasksPerTile=2048",
            "hw-xclbin",
        ]
        procs.append(launch(f"build_t{tiles}_c8_f{freq}", args))

for freq in freqs:
    for sw in [2]:
        for banks in [4]:
            args = [
                "--cfg=serial",
                "--tiles=36",
                "--coresPerTile=8",
                "--devices=8",
                f"--frequency={freq}",
                "--tasksPerTile=2048",
                f"--tilesPerSwitchPort={sw}",
                f"--tilesPerMemChannel={sw}",
                f"--l2CacheBanks={banks}",
                "hw-xclbin",
            ]
            procs.append(launch(f"build_t36_c8_f{freq}_sw{sw}_b{banks}", args))

    for sw in [2, 4]:
        for banks in [1, 2]:
            args = [
                "--cfg=serial",
                "--tiles=64",
                "--coresPerTile=4",
                "--devices=8",
                f"--frequency={freq}",
                "--tasksPerTile=1024",
                f"--tilesPerSwitchPort={sw}",
                "--tilesPerMemChannel=2",
                "--l2CacheSizeKb=128",
                f"--l2CacheBanks={banks}",
                "hw-xclbin",
            ]
            procs.append(launch(f"build_t64_c4_f{freq}_sw{sw}_b{banks}", args))

fail = False
while procs:
    for proc, f, log in procs:
        ret = proc.poll()
        if ret is not None:
            f.close()
            procs.remove((proc, f, log))
            status = "success" if ret == 0 else f"failed (exit {ret})"
            print(f"DONE ({status}): {log} (pid={proc.pid})")
            if ret != 0:
                fail = True
            break  # restart iteration after mutating list

sys.exit(1 if fail else 0)
