/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

// Overrides Verilator's VL_PRINTF. Should be -include'd in all source files
#define VL_PRINTF vl_printf
int vl_printf(const char *format, ...);
