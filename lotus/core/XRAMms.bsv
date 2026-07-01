/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

import XRAM::*;

// XRAM typedefs that enable use within Minispec (add others as needed)
typedef XRAM_PORT#(addrT, dataT) XRAM1#(type addrT, type dataT);
typedef XRAM_DUAL_PORT#(addrAT, dataAT, addrBT, dataBT) XRAM2#(type addrAT, type dataAT, type addrBT, type dataBT);
typedef XRAM_DUAL_PORT_BE#(addrT, dataT, n) XRAM2BE#(type addrT, type dataT, numeric type n);
