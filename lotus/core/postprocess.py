#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import re
f = open("Core.v", "r")
proc = f.read()
f.close()

# Eliminate EN and RDY signals, which are superfluous in Minispec
x = re.search(r"module mkCore\((.*?)\);", proc, flags=re.MULTILINE|re.DOTALL)
signals = [re.sub(",", "", s) for s in x.group(1).split()]
signals = [s for s in signals if not s.startswith("RDY_") and not s.startswith("EN_")];

nproc = re.sub(x.group(1), ",\n                   ".join(signals), proc)
nproc = re.sub(r"input(\s+)EN_(.*);\n", "", nproc);
nproc = re.sub(r"output(\s+)RDY_(.*);\n", "", nproc);

# Bluespec initializes registers to garbage, making reset mandatory and reset
# bugs more likely. In the FPGA, we can initialize registers however we want,
# so initialize them to their reset values. This lets us avoid having a reset
# signal, and makes reset bugs less likely.
rstSeqMatch = re.search(r"always@\(posedge CLK\)\s+begin\s+if \(RST_N == `BSV_RESET_VALUE\)\s+begin(.*?)\s+end\s+else\s+begin", nproc, flags=re.MULTILINE|re.DOTALL)
initSeq = re.sub("<= `BSV_ASSIGNMENT_DELAY", "=", rstSeqMatch.group(1))
nproc = re.sub(r"initial\s+begin\s+(.*?)\s+end\s+`endif", "initial\n    begin\n     // Postprocessed initial values, copied from reset block" + initSeq + "\n    end\n  `endif", nproc, flags=re.DOTALL);

# Remove all synopsys pragma comments. These gate the initial block, which is
# important. If we leave these in, then Vivado interprets all initial registers
# as don't cares and requires a reset.
#
# This also gate the block of $display statements, but the synthesizer can take
# those, so just nix them all.
nproc = re.sub("// synopsys translate(.*)", "", nproc);

# Tweak reset value of d2e, which enables optimizations that shed ~100 LUTs
# dsm: Irrelevant now that d2e isn't a maybe type
#nproc = re.sub("d2e <= `BSV_ASSIGNMENT_DELAY\s+\{ 1'd0,\s+(\d+)'.*?/\* unspecified",
#               "d2e <= `BSV_ASSIGNMENT_DELAY {1'd0, ~\g<1>'d0 /* perf-substituted initial",
#               nproc, flags=re.DOTALL)

f = open("Core.v", "w")
f.write(nproc)
f.close()
