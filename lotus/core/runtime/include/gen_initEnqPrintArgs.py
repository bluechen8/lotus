# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

# Helper to produce initEnqPrintArgs functions up to maxArgs
for n in range(16):
    args = ", ".join("arg%d" % i for i in range(n))
    fnArgs = args.replace("arg", "Arg_t arg")
    pargs = '", "'.join(" PARGS " for i in range(n))
    fmtStrPrefix = '"[]' if n == 0 else '"[" ' + pargs + ' "]'
    fmtArgs = '' if n == 0 else ', ' + args
    print(f'inline void initEnqPrintArgs({fnArgs}) {{ printf({fmtStrPrefix}, numArgs={n}"{fmtArgs}); }}')

