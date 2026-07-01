#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import argparse, re, sys

# This script processes bsc-generated or BSV library Verilog to better match
# Vivado and FPGA flows. It (1) properly initializes registers, (2) optionally
# eliminates reset logic, (3) matches Vivado pragmas, and (4) addresses an
# incompatibility with xsim.

def error(msg):
    print("ERROR: %s", msg, file=sys.stderr)
    sys.exit(-1)

parser = argparse.ArgumentParser()
parser.add_argument("--noRegReset", default=False, action="store_true", help="take out reset from module's regs (reset is still passed to submodules)")
parser.add_argument("--removeReset", default=False, action="store_true", help="remove reset from input (if module is BSV-generated), and pass a 0 to all remaining submodules that use it")
parser.add_argument("--keepHierarchy", default=False, action="store_true", help="tag module with Vivado keep_hierarchy pragma")
parser.add_argument("--blackBox", default=False, action="store_true", help="tag module with Vivado black_box pragma")
args = parser.parse_args()

src = sys.stdin.read()

# bsc-generated code and BSV library code have some differences. First, let's
# see what we're dealing with. A reliable distinction is the reset's name.
isBsvLib = False
resetName = "RST_N"
if re.search(r"\s*input\s+RST\s*;", src):
    isBsvLib = True
    resetName = "RST"

if isBsvLib and args.removeReset:
    sys.stderr.write("ERROR: Library code should not use removeReset\n")
    sys.exit(-1)


# Initialize registers to the right values
if not isBsvLib:
    # bsc initializes registers to garbage, making reset mandatory and reset
    # bugs more likely. In the FPGA, we can initialize registers however we want,
    # so initialize them to their reset values. This lets us avoid having a reset
    # signal, and makes reset bugs less likely.
    rstSeqMatch = re.search(r"always@\(posedge CLK\)\s+begin\s+if \(RST_N == `BSV_RESET_VALUE\)\s+begin(.*?)\s+end\s+", src, flags=re.MULTILINE|re.DOTALL)
    if rstSeqMatch: # purely combinational designs don't have this
        initSeq = re.sub("<= `BSV_ASSIGNMENT_DELAY", "=", rstSeqMatch.group(1))
        # Susbtitute the whole initial block, including the translate_off/on pragma
        # comment, which would gate the initial block for synthesis.
        src = re.sub(r"// synopsys translate_off\s+`ifdef BSV_NO_INITIAL_BLOCKS.*?// synopsys translate_on",
                "// Postprocessed initial values, copied from reset block\n  initial\n    begin\n      " + initSeq + "\n    end\n",
                src, flags=re.DOTALL)
else:
    # BSV library code is a bit more heterogeneous, but it's easier to get the
    # initialization right: these files already have an initial block that sets
    # the right values, it's just immediately gated by translate_off/on pragmas
    src = re.sub(r"//\s+synopsys\s+translate_off\s+initial(.*?)//\s+synopsys\s+translate_on",
            r"initial\g<1>", src, flags=re.DOTALL)
    # BSV libary code uses the following expression to initialize with 101010...
    # This triggers a width warning when the value has an even number of bits;
    # be precise instead
    src = src.replace(r"{((width + 1)/2) {2'b10}}", r"{{(width % 2) {1'b0}}, {(width / 2) {2'b10}}}")

# If we're nixing resets entirely, disable reset conditions through the
# design. This affects the reset block and the $display blocks.
#
# Note that this still passes the reset to submodules. This is intended, in
# case we have some BVI submodules that need reset, though I'd expect a
# reset-clean design to just tie RST/RST_N to the non-reset value.
if args.noRegReset or args.removeReset:
    src = re.sub(rf"if\s*\({resetName}\s*==\s*`BSV_RESET_VALUE\)", "if (1'b0 /* in reset */)", src)
    src = re.sub(rf"if\s*\({resetName}\s*!=\s*`BSV_RESET_VALUE\)", "if (1'b1 /* not in reset */)", src)
    # This one shows up in BSV library code
    src = re.sub(rf"if\s*\({resetName}\s*==\s*!\s*`BSV_RESET_VALUE\)", "if (1'b1 /* not in reset */)", src)

if args.keepHierarchy:
    src = re.sub("\nmodule ", '\n(* keep_hierarchy = "soft" *)\nmodule ', src, flags=re.MULTILINE)

if args.blackBox:
    src = re.sub("\nmodule ", '\n(* black_box = "true" *)\nmodule ', src, flags=re.MULTILINE)

if args.removeReset:
    # Remove our reset input,
    src = re.sub(r"\nmodule\s+(\S+)\s*\(CLK,\s*RST_N,", r"\nmodule \g<1>(CLK,", src, flags=re.MULTILINE)
    # Turn the input into a tied-off wire,
    src = re.sub(r"input\s+RST_N;", "wire RST_N = 1'b1;", src)
    # And stop passing the reset to any BSC-generated submodules (starting with mk)
    src = re.sub(r" mk(\S+)\s+(\S+)\(.CLK\(CLK\),\s+.RST_N\(RST_N\),", r" mk\g<1> \g<2>(.CLK(CLK),", src, flags=re.MULTILINE)

# bsc puts parallel_case pragmas in synopsys form, but Vivado doesn't take
# those. Convert them to Vivado form.
src = re.sub(r"case (.*?) // synopsys parallel_case", r"(* parallel_case *) case \g<1>", src)

# Turn comments of the form verilog_pragma: ... into pragmas
# These are produced via BSV doc pragmas, e.g., (* doc = "verilog_pragma: keep_hierarchy = 'true'" *)
# We also chnage single quotes to double quotes to allow strings in pragmas w/o escape chars, e.g.,
# the above produces (* keep_hierarchy = "true" *)
def pragmarepl(m):
    return "(* " + m.group(1).strip().replace("'", '"') + " *)"
src = re.sub("// verilog_pragma:(.*)", pragmarepl, src)

# Finally, xsim errors out due to the file missing a `timescale directive, so prepend it
# (this affects xsim simulations, e.g., the sip testbench, though not hw_emu)
if not re.search("`timescale", src):
    src = "`timescale 1ps/1ps\n\n" + src

print(src)
