# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import json
import re
import pandas as pd
import sys

def parse_counter_name(full_name):
    components = full_name.split('.')
    dims = {'chip': None, 'tile': None, 'core': None, 'l2bank': None}
    for comp in components:
        if re.match(r'chip(\d+)', comp):
            dims['chip'] = int(re.match(r'chip(\d+)', comp).group(1))
        elif re.match(r'tile(\d+)', comp):
            dims['tile'] = int(re.match(r'tile(\d+)', comp).group(1))
        elif re.match(r'core(\d+)', comp):
            dims['core'] = int(re.match(r'core(\d+)', comp).group(1))
        elif re.match(r'l2bank(\d+)', comp):
            dims['l2bank'] = int(re.match(r'l2bank(\d+)', comp).group(1))
    counter_name = components[-1]
    return dims, counter_name

def process_data(json_data):
    data_rows = []
    for full_name, value in json_data.items():
        dims, counter_name = parse_counter_name(full_name)
        row = {
            'chip': dims['chip'],
            'tile': dims['tile'],
            'core': dims['core'],
            'l2bank': dims['l2bank'],
            'counter_name': counter_name,
            'value': value
        }
        data_rows.append(row)
    df = pd.DataFrame(data_rows)
    return df

def compute_statistics(df_tile, globCycles, is_overall=False):
    counters = df_tile.groupby('counter_name')['value'].sum()
    cycles = counters.get('coreHasTask', 0)
    instrs = counters.get('coreInstrsCommit', 0)
    istalls = counters.get('coreIcacheStall', 0)
    dstalls = counters.get('coreDcacheStall', 0)
    l2IReqs = counters.get('coreIL2Req', 0)
    l2DReadReqs = counters.get('coreDL2ReadReq', 0)
    l2DWriteReqs = counters.get('coreDL2WriteReq', 0)
    l2CoreReqs = counters.get('l2CoreReq', 0)
    l2ReadMiss = counters.get('l2ReadMiss', 0)
    l2WriteMiss = counters.get('l2WriteMiss', 0)
    l2Writeback = counters.get('l2Writeback', 0)
    localEnqs = counters.get('localEnq', 0)
    networkEnqs = counters.get('networkEnq', 0)
    deqTasks = counters.get('deqTask', 0)
    skipTasks = counters.get('skipTask', 0)
    enqs = localEnqs + networkEnqs

    # Correctly count cores and tiles
    if not is_overall:
        cores = df_tile['core'].dropna().nunique()
        tiles = 1  # Since we're computing per-tile statistics
    else:
        cores = df_tile[['chip', 'tile', 'core']].dropna().drop_duplicates().shape[0]
        tiles = df_tile[['chip', 'tile']].dropna().drop_duplicates().shape[0]

    l2banks = df_tile['l2bank'].dropna().nunique()
    pipestalls = cycles - instrs - istalls - dstalls

    # Correct core activity calculation
    coreactivefrac = (cycles / (cores * globCycles)) if (cores > 0 and globCycles > 0) else 0

    fracs = [float(x)/cycles if cycles > 0 else 0.0 for x in [instrs, istalls, dstalls, pipestalls]]
    mpkis = [float(x) * 1000.0 / instrs if instrs > 0 else 0.0 for x in [
        l2IReqs + l2DReadReqs + l2DWriteReqs,
        l2IReqs,
        l2DReadReqs,
        l2DWriteReqs,
        l2CoreReqs,
        l2ReadMiss + l2WriteMiss,
        l2ReadMiss,
        l2WriteMiss,
        l2Writeback
    ]]

    actualDeqs = deqTasks+skipTasks

    reqLoad = (l2IReqs + l2DReadReqs + l2DWriteReqs) / cycles if cycles > 0 else 0.0
    respLoad = ((l2IReqs + l2DReadReqs) * 8.0) / cycles if cycles > 0 else 0.0
    tpkis = [float(x) * 1000.0 / instrs if instrs > 0 else 0.0 for x in [enqs, actualDeqs]]
    enqsPerDeq = (enqs / actualDeqs) if actualDeqs > 0 else 0.0
    localFrac = (localEnqs / enqs) if enqs > 0 else 0.0
    avg_instrs_per_task = (instrs / deqTasks) if deqTasks > 0 else 0.0
    avg_cycles_per_task = (cycles / deqTasks) if deqTasks > 0 else 0.0
    avg_globCycles_per_task = (globCycles / actualDeqs) if actualDeqs > 0 else 0.0

    # Correct task unit load calculation
    enqueues_per_cycle = enqs / globCycles if globCycles > 0 else 0.0
    dequeues_per_cycle = actualDeqs / globCycles if globCycles > 0 else 0.0
    networkEnqs_per_cycle = networkEnqs / globCycles if globCycles > 0 else 0.0

    # Calculate enqs/cycle/port
    num_ports = tiles  # Assuming one port per tile
    if num_ports > 0:
        networkEnqs_per_cycle_per_port = networkEnqs_per_cycle / num_ports
    else:
        networkEnqs_per_cycle_per_port = 0.0

    stats = {
        'cycles': cycles,
        'instrs': instrs,
        'cores': cores,
        'coreactivefrac': coreactivefrac,
        'fracs': fracs,
        'mpkis': mpkis,
        'reqLoad': reqLoad,
        'respLoad': respLoad,
        'tpkis': tpkis,
        'enqsPerDeq': enqsPerDeq,
        'localFrac': localFrac,
        'avg_instrs_per_task': avg_instrs_per_task,
        'avg_cycles_per_task': avg_cycles_per_task,
        'avg_globCycles_per_task': avg_globCycles_per_task,
        'enqueues_per_cycle': enqueues_per_cycle,
        'dequeues_per_cycle': dequeues_per_cycle,
        'tiles': tiles,
        'l2banks': l2banks,
        'networkEnqs_per_cycle': networkEnqs_per_cycle,
        'networkEnqs_per_cycle_per_port': networkEnqs_per_cycle_per_port,
    }
    return stats

def print_statistics(stats, title):
    fracs = stats['fracs']
    mpkis = stats['mpkis']
    tpkis = stats['tpkis']
    print(f"{title}: IPC = {fracs[0]:.3f}, stalls: {fracs[1]*100:.2f}% ICache, {fracs[2]*100:.2f}% DCache, {fracs[3]*100:.2f}% Pipeline")
    print(f"      Core cycles: {int(stats['cycles'])}, Instructions: {int(stats['instrs'])}, Core activity: {int(stats['coreactivefrac']*100.0)}%")
    print(f"      L1 MPKI = {mpkis[0]:.1f}, breakdown: {mpkis[1]:.1f} IFetches, {mpkis[2]:.1f} Loads, {mpkis[3]:.1f} Stores ({mpkis[4]:.1f} L2-side)")
    print(f"      L2 bank load: {stats['reqLoad']:.2f} reqs/core cycle, {stats['respLoad']:.2f} chunk resps/core cycle")
    print(f"      L2 MPKI = {mpkis[5]:.1f}, breakdown: {mpkis[6]:.1f} Reads, {mpkis[7]:.1f} Writes (+{mpkis[8]:.1f} Writebacks)")
    print(f"      Task events PKI: {tpkis[0]:.1f} enqueues, {tpkis[1]:.2f} dequeues (skip+nonSkip) ({stats['enqsPerDeq']:.1f} enqs/deq, {stats['localFrac']*100:.2f}% enqs local)")
    print(f"      Task avg length: {stats['avg_instrs_per_task']:.1f} instructions, {stats['avg_cycles_per_task']:.1f} cycles, {stats['avg_globCycles_per_task']:.1f} cycles/task issue (skip+nonSkip)")
    print(f"      Task unit load: {stats['enqueues_per_cycle']:.3f} enqueues/cycle, {stats['dequeues_per_cycle']:.3f} dequeues/cycle")
    if stats['tiles'] > 1:
        print(f"      Switch load: {stats['networkEnqs_per_cycle_per_port']:.3f} enqs/cycle/port, {stats['networkEnqs_per_cycle']:.3f} enqs/cycle")
    else:
        print(f"      Switch load: {stats['networkEnqs_per_cycle']:.3f} enqs/cycle")
    print("")

def main():
    # Load the JSON data
    import perfSummarize
    data = perfSummarize.get_data(sys.argv[1])
    #data = perfSummarize.preprocess_data(json_data)

    df = process_data(data)

    # Get globCycles from 'cycles' counter with chip0
    globCycles = df[(df['counter_name'] == 'cycles') & (df['chip'] == 0)]['value'].sum() or 1  # Avoid division by zero

    # Get the list of tiles with chips
    tiles = df[['chip', 'tile']].dropna().drop_duplicates()

    tile_stats_list = []

    # Compute and print statistics per tile
    for idx, row in tiles.iterrows():
        chip = row['chip']
        tile = row['tile']
        df_tile = df[(df['chip'] == chip) & (df['tile'] == tile)]
        stats = compute_statistics(df_tile, globCycles)
        stats['chip'] = chip
        stats['tile'] = tile
        tile_stats_list.append(stats)
        tile_name = f"Chip {int(chip)}, Tile {int(tile)}"
        print_statistics(stats, tile_name)

    # Compute and print overall statistics
    stats_overall = compute_statistics(df, globCycles, is_overall=True)
    print_statistics(stats_overall, "Overall")

    # Additional analysis: Max, Min, and Average of each statistic
    tile_stats_df = pd.DataFrame(tile_stats_list)
    print("----- Additional Analysis -----")
    stats_to_analyze = {
        'IPC': ('fracs', 0),
        "Instructions": ('instrs', None),
        'Core Activity': ('coreactivefrac', None),
        'L1 MPKI': ('mpkis', 0),
        'L2 Bank Load': ('reqLoad', None),
        'Task Enqueues PKI': ('tpkis', 0),
        'Task Dequeues PKI': ('tpkis', 1),
        'Enqueues per Dequeue': ('enqsPerDeq', None),
        'Local Enqueue Fraction': ('localFrac', None),
        'Average Instructions per Task': ('avg_instrs_per_task', None),
        'Task Unit Enqueue Load': ('enqueues_per_cycle', None),
        'Task Unit Dequeue Load': ('dequeues_per_cycle', None),
        'Switch Load (enqs/cycle/port)': ('networkEnqs_per_cycle_per_port', None),
        'Switch Load (enqs/cycle)': ('networkEnqs_per_cycle', None),
    }

    for stat_name, (key, idx) in stats_to_analyze.items():
        if idx is not None:
            values = tile_stats_df.apply(lambda row: row[key][idx], axis=1)
        else:
            values = tile_stats_df[key]
        max_value = values.max()
        min_value = values.min()
        avg_value = values.mean()
        max_tile = tile_stats_df.iloc[values.idxmax()][['chip', 'tile']]
        min_tile = tile_stats_df.iloc[values.idxmin()][['chip', 'tile']]
        print(f"{stat_name}:")
        print(f"  Max: {max_value:.4f} (Chip {int(max_tile['chip'])}, Tile {int(max_tile['tile'])})")
        print(f"  Min: {min_value:.4f} (Chip {int(min_tile['chip'])}, Tile {int(min_tile['tile'])})")
        print(f"  Avg: {avg_value:.4f}")
        print("")

if __name__ == '__main__':
    main()

