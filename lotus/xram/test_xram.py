# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import itertools, subprocess, string, os, sys

# See https://support.xilinx.com/s/question/0D52E00007CioCcSAJ/why-is-synth-87080-a-warning-, making this an INFO
scriptTemplate = string.Template('''
set_msg_config -id {[Synth 8-7080]} -severity WARNING -new_severity INFO
set_part xcu250-figd2104-2L-e
add_files {XRAM.sv}
set_property top $top [current_fileset]
$props
synth_design -mode out_of_context
''')

modes = [0, 1, 2]
addrw = [8, 12]
dataw = [8, 64]
chunksizes = [4, 8]
ratios = [0, 1, 4, 5]
styles = ["auto", "distributed", "block", "ultra"]

tests = {
    "XRAM2": [("ADDR_WIDTH", addrw), ("DATA_WIDTH", dataw), ("MODEA", modes), ("MODEB", modes), ("LOG_RATIOB", ratios)],
    "XRAM2BE": [("ADDR_WIDTH", addrw), ("DATA_WIDTH", dataw), ("MODEA", modes), ("MODEB", modes), ("CHUNK_SIZE", chunksizes)],
    "XRAM1": [("ADDR_WIDTH", addrw), ("DATA_WIDTH", dataw), ("MODE", modes), ("STYLE", styles)],
    "XRAM1BE": [("ADDR_WIDTH", addrw), ("DATA_WIDTH", dataw), ("MODE", modes), ("CHUNK_SIZE", chunksizes)]
}

def param(val):
    return '"' + val + '"' if isinstance(val, str) else str(val)

def expand(configList):
    configs = itertools.product(*([(name, val) for val in vals] for (name, vals) in configList))
    return ["set_property generic {" + " ".join("%s=%s" % (name, param(val)) for (name, val) in config) + "} [current_fileset]" for config in configs]


# NOTE: This launches all tests in parallel; 288 tests consume ~400GB of RAM.
# Use a large machine, or limit the number of parallel runs by editing the
# code below (e.g., use pmap).
procs = []

for top in tests.keys():
    expandedTests = list(expand(tests[top]))
    print("Running %d tests for module %s" % (len(expandedTests), top))
    for props in expand(tests[top]):
        script = scriptTemplate.substitute({"top" : top, "props" : props})
        p = subprocess.Popen("vivado -nolog -nojournal -mode tcl".split(), stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize = 10*1000*1000)
        p.stdin.write(script.encode())
        p.stdin.close()
        p.stdin = None
        procs.append(p)

for p in procs:
    out = p.communicate()[0]
    print(out.decode())
    print("Return code: %d\n\n" % p.returncode)

