# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

# Auto-generates C++ code to initialize memory channels; this can't be done
# easily through macros alone because each channel needs to be tied to
# verilator-generated memory locations
import sys
print("    // Auto-generated")
for i in range(int(sys.argv[1])):
    print("    memChannels[%d] = new MemChannel{SET_MEMCHANNEL_PORTS(top.m%02d_axi_), .channelId = %d, .mem = mem};" % (i, i, i))
