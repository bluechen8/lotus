#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import sys
import subprocess
import json
import sys
import numpy as np
import re


def trim_arrays(data_dict, hbs_array):
    import numpy as np

    # Find the indices where hbs_array is greater than 3
    indices_greater_than_3 = np.where(hbs_array > 3)[0]
    if len(indices_greater_than_3) > 0:
        start_index = indices_greater_than_3[0]
    else:
        # If no values are greater than 3, set start_index beyond the array length
        start_index = len(hbs_array)

    # Find the last value in hbs_array
    last_value = hbs_array[-1]

    # Find the first occurrence of the last value
    if hbs_array[-1] == hbs_array[-2]:
        indices_last_value = np.where(hbs_array == last_value)[0]
        end_index = indices_last_value[0]+1 if len(indices_last_value) > 0 else len(hbs_array)
    else:
        end_index = len(hbs_array)

    # Trim the arrays from start_index + 1 up to end_index (excluding end_index)
    for key in data_dict:
        data_dict[key] = data_dict[key][start_index + 1:end_index]

    # If the result is empty, set all arrays to np.array([1])
    if any(len(arr) == 0 for arr in data_dict.values()):
        for key in data_dict:
            if "coreSimFailReg" in key:
                data_dict[key] = np.array([0, 0])
            else:
                data_dict[key] = np.array([1, 1])

    return data_dict

def get_hbs_array(data_dict):
    hbKeys = [k for k in data_dict.keys() if "coreSimNumHbReg" in k]
    assert len(hbKeys) > 0

    def getAddr(k):
        pattern = re.compile(r"chip(\d+)\.Multile\.tile(\d+)\.tile-perf\.core(\d+)\.coreSimNumHbReg")
        m = pattern.match(k)
        assert m is not None
        chip_id, tile_id, _ = m.groups()
        chip_id = int(chip_id)
        tile_id = int(tile_id)
        return (chip_id, tile_id)


    addrToArr = {}

    for k in hbKeys:
        addr = getAddr(k)
        if addr not in addrToArr:
            addrToArr[addr] = data_dict[k].copy()
        else:
            addrToArr[addr] = addrToArr[addr] + data_dict[k]

    maxKey = None
    maxVal = None
    for k, v in addrToArr.items():
        if not len(v):
            continue
        if maxKey is None:
            maxKey = k
            maxVal = v[-1]
        else:
            currVal = v[-1]
            if currVal > maxVal:
                maxKey = k
                maxVal = currVal

    assert maxKey is not None

    return addrToArr[maxKey]


def per_heartbeat_data(data_dict, totalHbs):
    new_data = {}
    for k,v in data_dict.items():
        if "coreSimFailReg" in k:
            new_data[k] = v[-1]
        else:
            new_data[k] = v[-1] / totalHbs
    return new_data

def normalize_dict_arrays(data_dict):
    for name, array in data_dict.items():
        if "coreSimFailReg" in name:
            continue
        if len(array) > 0:  # Ensure the array is not empty
            array -= array[0]
    return data_dict


def safe_div(num, denom):
    return 0.0 if denom == 0 else num / denom


def add_ipc(data):
    instr_keys = [k for k in data.keys() if "coreInstrsCommit" in k]

    new_data = data.copy()

    from pprint import pprint

    for instr_key in instr_keys:
        ipc_key  = instr_key.replace("coreInstrsCommit", "coreIPC")
        ipht_key = instr_key.replace("coreInstrsCommit", "coreInstrPerHasTask")
        ht_key   = instr_key.replace("coreInstrsCommit", "coreHasTask")
        util_key = instr_key.replace("coreInstrsCommit", "coreUtilization")

        prefix = instr_key.split(".")[0]
        cycles_key = f"{prefix}.Multile.SipGlobal.glob-cycleTable.cycles"

        instrs = data[instr_key]
        has_task_cycles = data[ht_key]
        cycles = data[cycles_key]

        #cycles = max(cycles, 1)

        new_data[ipc_key] = safe_div(instrs, cycles)

        new_data[ipht_key] = safe_div(instrs, has_task_cycles)

        new_data[util_key] = has_task_cycles / cycles

    return new_data

def preprocess_data(data):
    data = {k: np.array(v) for k, v in data.items()}

    #new_data = trim_arrays(data, get_hbs_array(data))
    #new_data = normalize_dict_arrays(new_data)
    new_data = data


    #data = {k: v.tolist() for k, v in new_data.items()}

    total_hbs = get_hbs_array(data)[-1]
    if total_hbs < 10:
        print(f"[perfSummarize] WARNING: Total Heartbeats in this run is: {total_hbs} but expected 10.")
        if total_hbs == 0:
            print(f"[perfSummarize] WARNING: Assuming all stats happened in one heartbeat.")
            total_hbs = 1
    #assert total_hbs >= 10

    new_data = per_heartbeat_data(new_data, total_hbs)

    new_data = add_ipc(new_data)

    return new_data

def get_summary(data, op):

    import re
    isVar = re.compile(r"^([^\d]+)(\d+)$")
    isl2Var = re.compile(r"^(l2[^\d]+)(\d+)$")
    def new_key(key):
        keys = key.split(".")

        newKeys = []
        for k in keys:
            if k == "l2":
                newKeys.append((k, None))
            elif "l2" in k:
                newKeys.append((k, isl2Var.match(k)))
            else:
                newKeys.append((k, isVar.match(k)))
        keys = newKeys

        key = ".".join([f"{m.group(1)}*" if m else k for (k, m) in keys ])
        return key

    new_data = {}
    for k, v in data.items():
        new_k = new_key(k)
        if new_k not in new_data.keys():
            new_data[new_k] = []
        new_data[new_k].append(v)


    for k in new_data.keys():
        if op == "sum":
            new_data[k] = sum(new_data[k])
        elif op == "avg":
            if "cycles" in k:
                new_data[k] = min(new_data[k])
            else:
                dataLen  = len(new_data[k])
                r = sum(new_data[k]) / dataLen
                new_data[k] = r
        elif op == "std":
            import statistics
            if len(new_data[k]) == 1:
                new_data[k] = new_data[k][0]
            else:
                try:
                    new_data[k] = statistics.pstdev(new_data[k])
                except:
                    new_data[k] = new_data[k][0]
        else:
            assert False, f"Unknown op: {op}"


    return new_data

def format_data(data):
    new_data = {}
    for k, v in data.items():
        new_data[k] = f'{v:.2f}'

    return new_data

def format_dict_as_table(dictionary):
    # Determine the maximum length of the keys and values
    max_key_len = max(len(key) for key in dictionary.keys())
    max_val_len = max(len(value) for value in dictionary.values())

    # Create a format string for aligned output
    row_format = f"{{:<{max_key_len}}}  |  {{:>{max_val_len}}}\n"

    # Generate the table string
    table = ""
    for key, value in dictionary.items():
        table += row_format.format(key, value)

    return table

def remove_extra(data):
    def starts_with_any(string, options):
        for option in options:
            if string.startswith(option):
                return True
        return False
    data = data.split("\n")
    filtered = ""
    for line in data:
        if starts_with_any(line, ["{", "}", "\""]):
            filtered += line + "\n"
    return filtered

def get_data(filename):
    import os
    datas = []
    for post in ["parent", "child"]:
        fn = f"{filename}.{post}"
        if os.path.isfile(fn):
            with open(fn) as f:
                data = f.read()
        else:
            continue
            print(f"Not found: {fn}")
            assert False, f"Not found {fn}"
        data = json.loads(remove_extra(data))
        datas.append(data)
    assert len(datas)
    if len(datas) == 1:
        #data = preprocess_data(data)
        return preprocess_data(datas[0])
    #return preprocess_data(datas[0])
    assert len(datas) == 2
    parent = datas[0]
    child  = datas[1]
    def increment_chip_id(s, increment=4):
        return re.sub(r'chip(\d+)', lambda m: f'chip{int(m.group(1)) + increment}', s)
    for k, v in child.items():
        parent[increment_chip_id(k)] = v
    return preprocess_data(parent)

def main():
    import os
    filename = sys.argv[1]
    outBase = sys.argv[2]
    try:
        data = get_data(filename)
    except Exception as e:
        name = outBase + ".per_heartbeat.exception"
        with open(name, "w") as f:
            f.write(f"{e}")
            f.write("\n================\n")
            #try:
            #    with open(filename) as ff:
            #        d = remove_extra(ff.read())
            #        for i, l in enumerate(d.split("\n")):
            #            f.write(f"i={i} -- {l}\n")
            #except Exception as ee:
            #    f.write(f"{ee}")
        exit(0)

    dumps = []

    name = outBase + ".per_heartbeat.sum"
    dumps.append((name, get_summary(data, "sum")))

    name = outBase + ".per_heartbeat.avg"
    dumps.append((name, get_summary(data, "avg")))

    name = outBase + ".per_heartbeat.std"
    dumps.append((name, get_summary(data, "std")))

    name = outBase + ".per_heartbeat.verbose"
    dumps.append((name, data))

    for fname, d in dumps:
        with open(fname, "w") as f:
            with open(fname, 'w') as file:
                f.write(format_dict_as_table(format_data(d)))
            #print(f"Produced {fname}")

if __name__ == "__main__":
    main()
