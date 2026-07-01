# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import subprocess
import re
from collections import defaultdict
import sys

# Define the categories and their respective patterns
categories = {
    "VMTask": '___VMTask',
    "DTT": '__DTT_',
    "spawner_task": 'spawner_task',
    "reducing__reduction_task": 'reducing__reduction_task_',
    "betweenCyclesAutoGen": 'betweenCyclesAutoGen'
}

# Initialize dictionaries to store the sizes and counts of each category
category_sizes = defaultdict(int)
category_counts = defaultdict(int)

# Check for command-line argument
if len(sys.argv) != 2:
    print("Usage: python script.py <binary_name>")
    sys.exit(1)

binary_name = sys.argv[1]

# Get the nm output and demangle it
nm_output = subprocess.check_output(['riscv32-unknown-linux-gnu-nm', '--size-sort', binary_name])
demangled_output = subprocess.check_output(['c++filt'], input=nm_output).decode('utf-8')

# Parse the nm output
for line in demangled_output.splitlines():
    parts = line.split()
    if len(parts) < 3:
        continue

    size = int(parts[0], 16)
    symbol = parts[2]

    # Check which category the symbol belongs to
    for category, pattern in categories.items():
        if pattern in symbol:
            if category == 'VMTask' and 'spawner_task' in symbol:
                category = 'spawner_task'
            category_sizes[category] += size
            category_counts[category] += 1
            break

# Function to format size
def format_size(size):
    if size >= 1024**2:
        return f"{size / 1024**2:.2f} MB"
    elif size >= 1024:
        return f"{size / 1024:.2f} KB"
    else:
        return f"{size} bytes"

# Print the sizes and counts of each category
for category, size in category_sizes.items():
    count = category_counts[category]
    avg_size = size / count if count > 0 else 0
    print(f"{category}: {format_size(size)}")
    print(f"  Number of functions: {count}")
    print(f"  Average size per function: {format_size(avg_size)}")

# If needed, you can also sum all the sizes to get the total
total_size = sum(category_sizes.values())
print(f"Total size: {format_size(total_size)}")

