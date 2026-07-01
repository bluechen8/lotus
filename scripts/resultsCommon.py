#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import math
import json
import random
import sys
import os
import shutil
current_directory = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, current_directory)

from itertools import product
import concurrent.futures
import concurrent
import time
from datetime import datetime
import os
from pathlib import Path
import subprocess
import pandas as pd
from functools import reduce
import csv
import io


import re
import argparse
import threading
from contextlib import contextmanager
import tempfile
import networkx


globalData = {
              "printLock"          : threading.Lock(),
              "args"               : None,
              "buildDir"           : None,
              }

def getEdgeInfo(config):
    stats = {
        "tasks"            : 0,
        "localEdges"       : 0,
        "crossTileEdges"   : 0,
        "crossDeviceEdges" : 0,
        "localPackets"       : 0,
        "crossTilePackets"   : 0,
        "crossDevicePackets" : 0,
    }
    hostInitPath = os.path.join(globalData["buildDir"], config.build.to_str(), config.bench.to_str_no_target(), "obj_dir", "hostInit.h.dict")
    if not os.path.isfile(hostInitPath):
        b = config.bench.to_str_no_target()
        hostInitPath = os.path.join(globalData["buildDir"], config.build.to_str(), b, f"{b}.host_init")
        if not os.path.isfile(hostInitPath):
            return stats
    with open(hostInitPath, 'r') as file:
        json_data = json.load(file)
    tasks = json_data['tasks']
    recipes = json_data['recipes']
    num_devices = int(json_data['hwConfig']['numDevices'])
    num_tiles_per_device = int(json_data['hwConfig']['numTilesPerDevice'])

    for task in tasks:
        stats["tasks"] += 1
        dest_tile = int(task['destTile'])


        assumed_num_tiles_per_device = 1 << int(math.ceil(math.log2(num_tiles_per_device)))

        device_id = dest_tile // assumed_num_tiles_per_device  # Calculate the deviceId
        local_tile_id = dest_tile & (assumed_num_tiles_per_device-1)

        #print(f"destTile: {dest_tile} => device_id: {device_id} -- local_tile_id: {local_tile_id} -- (num_tiles_per_device={num_tiles_per_device}, assumed_num_tiles_per_device={assumed_num_tiles_per_device})")
        #print(f"Number of recipes at tile: {len(recipes[dest_tile])}")

        first_edge_idx_start = int(task['firstEdgeIdxStart'])
        num_enq_packets = int(task['numOutEdges'])

        for i in range(first_edge_idx_start, first_edge_idx_start + num_enq_packets):
            recipe = recipes[dest_tile][i]
            #finalPacket = int(recipe['finalPacket']) == 1

            n = "targetTileId"
            if n not in recipe:
                n = "destTile"
            child_device_id = int(recipe[n]) // assumed_num_tiles_per_device
            child_local_tile_id = int(recipe[n]) & (assumed_num_tiles_per_device-1)

            if child_device_id == device_id:
                if child_local_tile_id == local_tile_id:
                    stats["localPackets"] += 1
                    #if finalPacket:
                    #    stats["localEdges"] += 1
                else:
                    stats["crossTilePackets"] += 1
                    #if finalPacket:
                    #    stats["crossTileEdges"] += 1
            else:
                stats["crossDevicePackets"] += 1
                #if finalPacket:
                #    stats["crossDeviceEdges"] += 1
    return stats


def copyFile(src, dst):
    if os.path.isfile(src):
        shutil.copy(src, dst)

def compress_item(path, safePrint=print, threads=5):
    try:
        if os.path.exists(path):
            tar_gz_file = f"{path}.tar.gz"
            if os.path.isdir(path):
                command = ["tar", "-czf", tar_gz_file, "-C", os.path.dirname(path), os.path.basename(path)]
            elif os.path.isfile(path):
                command = ["tar", "-czf", tar_gz_file, "-C", os.path.dirname(path), os.path.basename(path)]
            subprocess.run(command, capture_output=True)
            subprocess.run(["rm", "-rf", path], capture_output=True)
    except Exception as e:
        safePrint(f"compress_item {path} exception: {e}")

def decompress_tar_gz(tar_gz_file, safePrint=print, threads=5):
    try:
        if os.path.isfile(tar_gz_file):
            target_dir = os.path.dirname(tar_gz_file)
            command = ["tar", "-xzf", tar_gz_file, "-C", target_dir]
            subprocess.run(command, capture_output=True)
            subprocess.run(["rm", "-f", tar_gz_file], capture_output=True)
    except Exception as e:
        safePrint(f"decompress_tar_gz {tar_gz_file} exception: {e}")

def dict_permute(input_dict):
    keys = input_dict.keys()
    values = input_dict.values()
    permutations = [dict(zip(keys, combination)) for combination in product(*values)]
    return permutations


def deadlocked(config):
    def grep_phrase(file_path, phrase):
        result = subprocess.run(
            ['grep', '-q', phrase, file_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        return result.returncode == 0

    cout = os.path.join(globalData['buildDir'], config.build.to_str(), f"{config.bench.to_str(True)}.cout")
    if not os.path.isfile(cout):
        return False
    phrase = "deadlocked=1"

    return grep_phrase(cout, phrase)

def runConfigDone(config):
    def grep_phrase(file_path, phrase):
        result = subprocess.run(
            ['grep', '-q', phrase, file_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        return result.returncode == 0

    cout = os.path.join(globalData['buildDir'], config.build.to_str(), f"{config.bench.to_str(True)}.cout")
    if not os.path.isfile(cout):
        return False
    phrase = "done=1"

    return grep_phrase(cout, phrase)

def getConfigStatus(config, stage):
    assert stage in ["build", "run"], "ASSERT 17"
    buildDir = globalData["buildDir"]

    base = os.path.join(buildDir, f"{config.to_str(stage == 'run')}")

    didPass = os.path.isfile(f"{base}.{stage}.pass")
    didFail = os.path.isfile(f"{base}.{stage}.fail")

    if didFail:
        return "fail"

    if didPass:
        if stage == "run" and deadlocked(config):
            return "fail"
        return "pass"

    return None

def parse_perf_output(perf_output: str):
    TARGET_EVENTS = {
        "instructions": "instructions",
        "cycles": "cycles",
        "stalled-cycles-frontend": "stalled-cycles-frontend",
        "stalled-cycles-backend": "stalled-cycles-backend",
    }

    result = {
        "instructions": None,
        "cycles": None,
        "cpus_utilized": None,
        "frequency": None,
        "stalled-cycles-frontend": None,
        "stalled-cycles-backend": None,
    }

    def _clean(s):
        return (s or "").strip()

    def _to_int(s):
        s = _clean(s).replace(",", "")
        if not s:
            return None
        # perf sometimes emits scaled decimals
        try:
            return int(float(s))
        except ValueError:
            return None

    def _to_float(s):
        s = _clean(s).replace(",", "")
        if not s:
            return None
        try:
            return float(s)
        except ValueError:
            return None

    for raw in perf_output.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        parts = [_clean(p) for p in line.split(",")]
        if not parts:
            continue

        # CPUs utilized row: last cell is literally "CPUs utilized"
        if parts[-1] == "CPUs utilized" and len(parts) >= 2:
            result["cpus_utilized"] = _to_float(parts[-2])
            continue

        # Frequency row: last cell is literally "GHz"
        if parts[-1] == "GHz" and len(parts) >= 2:
            # don't 'continue'; the same row can be the 'cycles' row
            if result["frequency"] is None:
                result["frequency"] = _to_float(parts[-2])

        # Identify event rows by exact token match anywhere in the row
        # (avoids substring collisions like 'stalled-cycles-backend')
        # For perf csv-ish output, the count is the leftmost numeric field (usually parts[0]).
        # We still scan from left to right to find the first numeric value to be safe.
        present_tokens = set(parts)  # exact tokens only
        for key, token in TARGET_EVENTS.items():
            if token in present_tokens:
                # Find the first numeric-looking field from the left
                value = None
                for cell in parts:
                    value = _to_int(cell)
                    if value is not None:
                        break
                if value is not None and result[key] is None:
                    result[key] = value

        # Ignore lines like ",,,,0.22,stalled cycles per insn" — they have no target token

    # Strict failure if missing required fields
    if result["cycles"] is None:
        raise ValueError("Missing 'cycles' in perf output")
    if result["cpus_utilized"] is None:
        raise ValueError("Missing 'CPUs utilized' in perf output")

    # Keep your original normalization
    result["cycles"] = int(result["cycles"] / result["cpus_utilized"])
    return result


def calculate_task_frequency_khz(cycles, clock_frequency):
    task_frequency_hz = clock_frequency / cycles

    task_frequency_khz = task_frequency_hz / 1e3

    return task_frequency_khz

def getConfigResultBaseline(config, resultDicts):
    perf_name = os.path.join(globalData["buildDir"], config.build.to_str(), f"{config.bench.to_str(False)}.perf.csv")


    perf = None
    if os.path.isfile(perf_name):
        try:
            with open(perf_name, "r") as f:
                perf = parse_perf_output(f.read())
        except:
            perf = None

    if perf is not None:
        cyclesPerBaselineBinary = 100000
        unroll = config.bench.bench["unrollFactor"]
        assert unroll >= 1
        cyclesPerBaselineBinary = cyclesPerBaselineBinary // unroll
        for k in perf.keys():
            if k == "frequency":
                continue
            perf[k] = perf[k] / cyclesPerBaselineBinary

        # ipc-system
        resultDicts["ipc-system"]["ipc-system"] = perf["instructions"] / perf["cycles"]
        # ipc-core
        resultDicts["ipc-core"]["ipc-core"] = perf["instructions"] / (perf["cycles"] * config.build.config["coresPerTile"])
        # instructions
        resultDicts["instructions"]["instructions"] = perf["instructions"]
        # simSpeed
        freq = perf["frequency"] * 1e9
        simSpeedRatio = 1.0
        if "nttVirtualized" in config.bench.bench["bench"]:
            simSpeedRatio = 2.0
        elif "systolicVirtualized" in config.bench.bench["bench"]:
            simSpeedRatio = 4.0
        resultDicts["cycles"]["cycles"]         = perf["cycles"] / simSpeedRatio
        resultDicts["simSpeed"]["simSpeed-KHz"] = calculate_task_frequency_khz(perf["cycles"], freq) * simSpeedRatio
        ## busy
        resultDicts["breakdown"]["busy"]           = perf["instructions"] / config.build.config["coresPerTile"]
        resultDicts["breakdown"]["frontend-stall"] = perf["stalled-cycles-frontend"] / config.build.config["coresPerTile"]
        resultDicts["breakdown"]["backend-stall"]  = perf["stalled-cycles-backend"] / config.build.config["coresPerTile"]
        resultDicts["breakdown"]["idle"]           = 0 / config.build.config["coresPerTile"]
        #
        resultDicts["tasks"]["tasks"]                       = 0
        resultDicts["totalEnqs"]["totalEnqs"]                       = 0
        resultDicts["localEnqs"]["localEnqs"]                       = 0
        resultDicts["networkEnqs"]["netowrkEnqs"]                       = 0
        resultDicts["localEdges"]["localEdges"]             = 0
        resultDicts["crossTileEdges"]["crossTileEdges"]     = 0
        resultDicts["crossDeviceEdges"]["crossDeviceEdges"] = 0
        resultDicts["localPackets"]["localPackets"]             = 0
        resultDicts["crossTilePackets"]["crossTilePackets"]     = 0
        resultDicts["crossDevicePackets"]["crossDevicePackets"] = 0
        resultDicts["testFail"]["testFail"] = 0
        resultDicts["skipPerc"]["skipPerc"] = 0.0
    else:
        # ipc-system
        resultDicts["cycles"]["cycles"]         = 0
        resultDicts["ipc-system"]["ipc-system"] = 0
        # ipc-core
        resultDicts["ipc-core"]["ipc-core"] = 0
        # instructions
        resultDicts["instructions"]["instructions"] = 0
        # simSpeed
        resultDicts["simSpeed"]["simSpeed-KHz"] = 0
        ## busy
        resultDicts["breakdown"]["busy"]           = 0
        resultDicts["breakdown"]["frontend-stall"] = 0
        resultDicts["breakdown"]["backend-stall"]  = 0
        resultDicts["breakdown"]["idle"]           = 0
        #
        resultDicts["tasks"]["tasks"]                       = 0
        resultDicts["totalEnqs"]["totalEnqs"]                       = 0
        resultDicts["localEnqs"]["localEnqs"]                       = 0
        resultDicts["networkEnqs"]["networkEnqs"]                       = 0
        resultDicts["localEdges"]["localEdges"]             = 0
        resultDicts["crossTileEdges"]["crossTileEdges"]     = 0
        resultDicts["crossDeviceEdges"]["crossDeviceEdges"] = 0
        resultDicts["localPackets"]["localPackets"]             = 0
        resultDicts["crossTilePackets"]["crossTilePackets"]     = 0
        resultDicts["crossDevicePackets"]["crossDevicePackets"] = 0
        resultDicts["testFail"]["testFail"] = 0
        resultDicts["skipPerc"]["skipPerc"] = 0.0

def getConfigResultLotus(config, resultDicts):
    def getPerfCounters():
        nonlocal config
        import perfSummarize
        import json
        perf_name = os.path.join(globalData["buildDir"], config.build.to_str(), f"{config.bench.to_str(True)}.perf_counters")
        if not os.path.isfile(f"{perf_name}.parent"):
            return None
        #with open(perf_name) as f:
        #    data = f.read()
        data = perfSummarize.get_data(perf_name)
        with globalData["printLock"]:
            #data = json.loads(perfSummarize.remove_extra(data))
            #data = perfSummarize.preprocess_data(data)

            toRet = {}
            for op in ["sum", "avg", "std"]:
                nd = perfSummarize.get_summary(data, op)
                nd = {k.split(".")[-1]: v for (k, v) in nd.items()}
                toRet[op] = nd
        return toRet

    perfCounters = getPerfCounters()

    if perfCounters is not None:
        numDevices = config.build.config["devices"]
        if config.bench.bench["target"] == "hw":
            numDevices = numDevices
            #numDevices = min(4, numDevices)
        numCores = numDevices * config.build.config["tiles"] * config.build.config["coresPerTile"]
        def core_avg(perfCounterName):
            # This function exists because sometimes config is smaller than fpga image
            # Thus, instead of relying on the provided average, re-calculates it
            perfCounterValue = perfCounters["sum"][perfCounterName]
            return float(perfCounterValue) / float(numCores)

        # ipc-system
        resultDicts["ipc-system"]["ipc-system"]     = perfCounters["sum"]["coreIPC"]
        # ipc-core
        resultDicts["ipc-core"]["ipc-core"]         = core_avg("coreInstrPerHasTask")
        # instructions
        resultDicts["instructions"]["instructions"] = int(perfCounters["sum"]["coreInstrsCommit"])
        # simSpeed
        freq  = config.build.config["frequency"] * 1e6
        simSpeedRatio = 1.0
        if "nttVirtualized" in config.bench.bench["bench"]:
            simSpeedRatio = 2.0
        elif "systolicVirtualized" in config.bench.bench["bench"]:
            simSpeedRatio = 4.0
        resultDicts["cycles"]["cycles"]             = int(perfCounters["avg"]["cycles"] / simSpeedRatio)
        resultDicts["simSpeed"]["simSpeed-KHz"]     = int(calculate_task_frequency_khz(perfCounters["avg"]["cycles"], freq) * simSpeedRatio)
        # breakdown
        ## busy
        resultDicts["breakdown"]["busy"]            = core_avg("coreInstrsCommit")
        resultDicts["breakdown"]["frontend-stall"]  = core_avg("coreIcacheStall")
        resultDicts["breakdown"]["backend-stall"]   = core_avg("coreDcacheStall")
        resultDicts["breakdown"]["idle"]            = perfCounters["avg"]["cycles"] - core_avg("coreHasTask")

        resultDicts["utilization"]["utilization"]   = perfCounters["avg"]["coreUtilization"] * 100
        #resultDicts["utilization"]["utilization"]   = perfCounters["sum"]["coreHasTask"] / perfCounters["avg"]["cycles"]
        #if perfCounters["avg"]["cycles"] > 0:
        #    resultDicts["utilization"]["utilization"]   = int((core_avg("coreHasTask") / perfCounters["avg"]["cycles"]) * 100.0)
        #else:
        #    resultDicts["utilization"]["utilization"]   = 0
        totalTasks                                  = (float(perfCounters["sum"]["deqTask"]) + float(perfCounters["sum"]["skipTask"]))
        resultDicts["tasks"]["tasks"]               = int(totalTasks)
        resultDicts["skipPerc"]["skipPerc"]         = float(perfCounters["sum"]["skipTask"]) / totalTasks
        resultDicts["totalEnqs"]["totalEnqs"]       = int(perfCounters["sum"]["totalEnq"])
        resultDicts["localEnqs"]["localEnqs"]       = int(perfCounters["sum"]["localEnq"])
        resultDicts["networkEnqs"]["networkEnqs"]   = int(perfCounters["sum"]["networkEnq"])
        resultDicts["testFail"]["testFail"]         = perfCounters["sum"]["coreSimFailReg"]
    else:
        resultDicts["tasks"]["tasks"]               = 0
        resultDicts["skipPerc"]["skipPerc"]               = 0.0
        resultDicts["totalEnqs"]["totalEnqs"]               = 0
        resultDicts["localEnqs"]["localEnqs"]               = 0
        resultDicts["networkEnqs"]["networkEnqs"]               = 0
        resultDicts["ipc-system"]["ipc-system"]     = 0
        resultDicts["ipc-core"]["ipc-core"]         = 0
        resultDicts["instructions"]["instructions"] = 0
        resultDicts["cycles"]["cycles"]             = 0
        resultDicts["simSpeed"]["simSpeed-KHz"]     = 0
        resultDicts["breakdown"]["busy"]            = 0
        resultDicts["breakdown"]["frontend-stall"]  = 0
        resultDicts["breakdown"]["backend-stall"]   = 0
        resultDicts["breakdown"]["idle"]            = 0
        resultDicts["utilization"]["utilization"]   = 0
        resultDicts["testFail"]["testFail"]   = 0

    edgeInfo = getEdgeInfo(config)
    resultDicts["localEdges"]["localEdges"]             = edgeInfo["localEdges"]
    resultDicts["crossTileEdges"]["crossTileEdges"]     = edgeInfo["crossTileEdges"]
    resultDicts["crossDeviceEdges"]["crossDeviceEdges"] = edgeInfo["crossDeviceEdges"]
    resultDicts["localPackets"]["localPackets"]             = edgeInfo["localPackets"]
    resultDicts["crossTilePackets"]["crossTilePackets"]     = edgeInfo["crossTilePackets"]
    resultDicts["crossDevicePackets"]["crossDevicePackets"] = edgeInfo["crossDevicePackets"]

def getConfigResults(config):
    baseDict = {**config.build.config}
    baseDict["selective"] = config.bench.bench["selective"]
    if "enableCoarsening" in config.bench.bench:
        baseDict["coarsen"] = config.bench.bench["enableCoarsening"]
    else:
        baseDict["coarsen"] = True
    if "unrollFactor" in config.bench.bench:
        baseDict["unroll"] = config.bench.bench["unrollFactor"]
    else:
        baseDict["unroll"] = 1
    baseDict["target"] = config.bench.bench["target"]
    baseDict["bench"] = config.bench.to_str_bench_only()
    baseDict["buildStatus"] = getConfigStatus(config, "build")
    if deadlocked(config):
        baseDict["runStatus"] = "deadlock"
    else:
        baseDict["runStatus"] = getConfigStatus(config, "run")
        if baseDict["runStatus"] is None:
            baseDict["runStatus"] = "NA"
    resultDicts = {
        'cycles'           : {**baseDict},
        'simSpeed'         : {**baseDict},
        'ipc-system'       : {**baseDict},
        'ipc-core'         : {**baseDict},
        'instructions'     : {**baseDict},
        'breakdown'        : {**baseDict},
        'utilization'      : {**baseDict},
        'tasks'            : {**baseDict},
        'skipPerc'         : {**baseDict},
        'totalEnqs'        : {**baseDict},
        'localEnqs'        : {**baseDict},
        'networkEnqs'      : {**baseDict},
        'localEdges'       : {**baseDict},
        'crossTileEdges'   : {**baseDict},
        'crossDeviceEdges' : {**baseDict},
        'localPackets'       : {**baseDict},
        'crossTilePackets'   : {**baseDict},
        'crossDevicePackets' : {**baseDict},
        'testFail'           : {**baseDict},
    }

    #if resultDicts["simSpeed"]["target"] == "baseline":
    #    getConfigResultBaseline(config, resultDicts)
    #else:
    #    getConfigResultLotus(config, resultDicts)
    #return resultDicts
    try:
        if resultDicts["simSpeed"]["target"] == "baseline":
            getConfigResultBaseline(config, resultDicts)
        else:
            getConfigResultLotus(config, resultDicts)
        return resultDicts
    except Exception as e:
        print(f"Ignoring Exception: {e}")
        #import traceback
        #traceback.print_exc()
        resultDicts = {
            'cycles'           : {**baseDict},
            'simSpeed'         : {**baseDict},
            'ipc-system'       : {**baseDict},
            'ipc-core'         : {**baseDict},
            'instructions'     : {**baseDict},
            'breakdown'        : {**baseDict},
            'utilization'      : {**baseDict},
            'tasks'            : {**baseDict},
            'skipPerc'         : {**baseDict},
            'totalEnqs'        : {**baseDict},
            'localEnqs'        : {**baseDict},
            'networkEnqs'      : {**baseDict},
            'localEdges'       : {**baseDict},
            'crossTileEdges'   : {**baseDict},
            'crossDeviceEdges' : {**baseDict},
            'localPackets'       : {**baseDict},
            'crossTilePackets'   : {**baseDict},
            'crossDevicePackets' : {**baseDict},
            'testFail'           : {**baseDict},
        }
        return resultDicts


def getConfigsResults(configs):
    resultDicts = {
        'cycles'           : [],
        'simSpeed'         : [],
        'ipc-system'       : [],
        "ipc-core"         : [],
        'instructions'     : [],
        'breakdown'        : [],
        'utilization'      : [],
        'tasks'            : [],
        'skipPerc'         : [],
        'totalEnqs'        : [],
        'localEnqs'        : [],
        'networkEnqs'      : [],
        'localEdges'       : [],
        'crossTileEdges'   : [],
        'crossDeviceEdges' : [],
        'localPackets'       : [],
        'crossTilePackets'   : [],
        'crossDevicePackets' : [],
        'testFail'           : [],
    }
    for c in configs:
        res = getConfigResults(c)
        for k,v in res.items():
            resultDicts[k].append(v)

    for k in resultDicts.keys():
        df = pd.DataFrame(resultDicts[k])
        df = df.sort_values(by=['cfg', 'bench', 'devices', 'tiles', 'coresPerTile', "unroll", "coarsen", "selective"])
        resultDicts[k] = df

    return resultDicts

#####################################################################################

class Benchmark:
    def __init__(self, bench):
        self.bench = bench
        assert self.to_str(True) is not None, "ASSERT 1"

    def __eq__(self, other):
        other_str = other.to_str(True)
        my_str    = self.to_str(True)
        return other_str == my_str

    def change_target(self, newTarget):
        assert newTarget in ["hw", "vl", "baseline"], "ASSERT 2"
        self.bench["target"] = newTarget

    def requires_fpga(self):
        return self.bench["target"] in ["hw"]

    def from_str(inStr):
        benchDict = None
        if inStr.count(".") == 2:
            reg = re.compile(r"(.*)__(\d+)u_(y|n)c\.(hw|vl|baseline)\.(SE|DF)")
            top = reg.match(inStr)
            bench     = top.group(1)
            unroll    = int(top.group(2))
            coarsen   = True if top.group(3) == "y" else False
            target    = top.group(4)
            selective = True if top.group(5) == "SE" else False
        else:
            reg = re.compile(r"(.*)__(\d+)u_(y|n)c\.(hw|vl|baseline)")
            top = reg.match(inStr)
            bench     = top.group(1)
            unroll    = int(top.group(2))
            coarsen   = True if top.group(3) == "y" else False
            target    = top.group(4)
            selective = False
        benchDict = {"target": target, "selective": selective, "unrollFactor": unroll, "enableCoarsening": coarsen}
        if "nttRetimed" in bench:
            reg = re.compile(r"nttRetimed(\d+)")
            m   = reg.match(bench)
            assert m is not None, "ASSERT 5"
            nttSize = m.group(1)
            benchDict["bench"] = "nttRetimed"
            benchDict["nttSize"] = int(nttSize)
        elif "nttVirtualized" in bench:
            reg = re.compile(r"nttVirtualized(\d+)")
            m   = reg.match(bench)
            assert m is not None, "ASSERT 5"
            nttSize = m.group(1)
            benchDict["bench"] = "nttVirtualized"
            benchDict["nttSize"] = int(nttSize)
        elif "ntt" in bench:
            reg = re.compile(r"ntt(\d+)")
            m   = reg.match(bench)
            assert m is not None, "ASSERT 5"
            nttSize = m.group(1)
            benchDict["bench"] = "ntt"
            benchDict["nttSize"] = int(nttSize)
        elif "systolicRetimed" in bench:
            reg = re.compile(r"systolicRetimed(\d+)")
            m   = reg.match(bench)
            assert m is not None, "ASSERT 5"
            systolicSize = m.group(1)
            benchDict["bench"] = "systolicRetimed"
            benchDict["systolicSize"] = int(systolicSize)
        elif "systolicVirtualized" in bench:
            reg = re.compile(r"systolicVirtualized(\d+)")
            m   = reg.match(bench)
            assert m is not None, "ASSERT 5"
            systolicSize = m.group(1)
            benchDict["bench"] = "systolicVirtualized"
            benchDict["systolicSize"] = int(systolicSize)
        elif "systolic" in bench:
            reg = re.compile(r"systolic(\d+)")
            m   = reg.match(bench)
            assert m is not None, "ASSERT 5"
            systolicSize = m.group(1)
            benchDict["bench"] = "systolic"
            benchDict["systolicSize"] = int(systolicSize)
        elif "coresWithCaches" in bench:
            reg = re.compile(r"coresWithCaches(\d+)")
            m   = reg.match(bench)
            assert m is not None, "ASSERT 5"
            coresSize = m.group(1)
            benchDict["bench"] = "coresWithCaches"
            benchDict["coresSize"] = int(coresSize)
        elif "cores" in bench:
            reg = re.compile(r"cores(\d+)")
            m   = reg.match(bench)
            assert m is not None, "ASSERT 5"
            coresSize = m.group(1)
            benchDict["bench"] = "cores"
            benchDict["coresSize"] = int(coresSize)
        else:
            assert "unit" in bench
            benchDict["bench"] = f"{bench}"

        assert benchDict is not None, "ASSERT 7"
        return Benchmark(benchDict)

    def to_str(self, with_se):
        benchName = None
        if self.bench["bench"] ==  "ntt":
            nttSize = self.bench["nttSize"]
            benchName = f"ntt{nttSize}"
        elif self.bench["bench"] ==  "nttRetimed":
            nttSize = self.bench["nttSize"]
            benchName = f"nttRetimed{nttSize}"
        elif self.bench["bench"] ==  "nttVirtualized":
            nttSize = self.bench["nttSize"]
            benchName = f"nttVirtualized{nttSize}"
        elif self.bench["bench"] == "systolic":
            systolicSize = self.bench["systolicSize"]
            benchName = f"systolic{systolicSize}"
        elif self.bench["bench"] == "systolicRetimed":
            systolicSize = self.bench["systolicSize"]
            benchName = f"systolicRetimed{systolicSize}"
        elif self.bench["bench"] == "systolicVirtualized":
            systolicSize = self.bench["systolicSize"]
            benchName = f"systolicVirtualized{systolicSize}"
        elif self.bench["bench"] == "coresWithCaches":
            coresSize = self.bench["coresSize"]
            benchName = f"coresWithCaches{coresSize}"
        elif self.bench["bench"] == "cores":
            coresSize = self.bench["coresSize"]
            benchName = f"cores{coresSize}"
        elif "unit" in self.bench["bench"]:
            benchName = self.bench["bench"]
        assert benchName is not None
        target = self.bench["target"]
        unroll = self.bench["unrollFactor"]
        coarsen = "y" if self.bench["enableCoarsening"] else "n"
        benchName = f"{benchName}__{unroll}u_{coarsen}c.{target}"
        if with_se:
            se = "SE" if self.bench["selective"] else "DF"
            benchName = f"{benchName}.{se}"
        return benchName

    def same_bench_binary(self, other):
        return self.to_str(False) == other.to_str(False)

    def to_str_no_target(self):
        s = self.to_str(False)
        return s.split(".")[0]

    def to_str_bench_only(self):
        s = self.to_str(False)
        return s.split("__")[0]

    def to_dict(self):
        return self.bench
    def __str__(self):
        return self.to_str(True)
    def __repr__(self):
        return self.to_str(True)

class Build:
    Default = {
        "cfg": "serial",
        "tiles" : 1,
        "coresPerTile" : 8,
        "tasksPerTile": 2048,
        "l2CacheSizeKb": 512,
        "devices" : 1,
        "frequency": 400,
    }
    def __init__(self, config):
        self.config = {**Build.Default, **config}

    def __eq__(self, other):
        other_str = other.to_str()
        my_str    = self.to_str()
        return other_str == my_str
    def to_str(self):
        cfg = self.config
        base = f"{cfg['cfg']}{cfg['devices']}d{cfg['tiles']}t{cfg['coresPerTile']}c{cfg['l2CacheSizeKb']}l2KB{cfg['tasksPerTile']}e{cfg['frequency']}MHz"
        return base

    def from_str(inStr):
        c = re.compile(
            r"(serial|baseline)(\d+)d(\d+)t(\d+)c(\d+)l2KB(\d+)e(\d+)MHz$"
        )
        c = c.match(inStr)
        assert c is not None, "ASSERT 9"
        config = {}
        config["cfg"]           =     c.group(1)
        config["devices"]       = int(c.group(2))
        config["tiles"]         = int(c.group(3))
        config["coresPerTile"]  = int(c.group(4))
        config["l2CacheSizeKb"] = int(c.group(5))
        config["tasksPerTile"]  = int(c.group(6))
        config["frequency"]     = int(c.group(7))

        return Build(config)

    def __str__(self):
        return self.to_str()
    def __repr__(self):
        return self.to_str()

class Configuration:
    def __init__(self, build, bench):
        assert type(build) is Build, "ASSERT 10"
        assert type(bench) is Benchmark, "ASSERT 11"
        self.build = build
        self.bench = bench

    def __eq__(self, other):
        other_str = other.to_str()
        my_str    = self.to_str()
        return other_str == my_str

    def __hash__(self):
        return hash(self.to_str(True))

    def to_str(self, with_se=True):
        return f"{self.build.to_str()}___{self.bench.to_str(with_se)}"

    def from_str(name):
        matches = name.split("___")
        build = Build.from_str(matches[0])
        bench = Benchmark.from_str(matches[1])
        return Configuration(build, bench)

    def __str__(self):
        return self.to_str()
    def __repr__(self):
        return self.to_str()

    def cast_str(c):
        if type(c) is str:
            return c
        return c.to_str()

class Experiment:
    def __init__(self, name, configs, callback):
        self.name = name
        self.configs = configs
        self.callback = callback

    def __str__(self):
        return f"Experiment(name={self.name}, configs={self.configs})"

    def __repr__(self):
        return self.__str__()

    def check_finished(self):
        done = True
        with globalData["runsFinished"].use() as runsFinished:
            for config in self.configs:
                if config.to_str() not in runsFinished:
                    done = False
                    break
        return done
    def config_in_experiment(self, config):
        return any([Configuration.cast_str(config) == Configuration.cast_str(c) for c in self.configs])

    def prettyPrintExperiments(exps):
        for ex in exps:
            builds_to_runs = {}
            for config in ex.configs:
                buildName = config.build.to_str()
                runName   = config.bench.to_str(True)
                if buildName not in builds_to_runs.keys():
                    builds_to_runs[buildName] = []
                builds_to_runs[buildName].append(runName)
            print(f"\tExperiment: {ex.name}")
            for (buildName, benchNames) in builds_to_runs.items():
                print(f"\t\t{buildName}")
                for benchName in benchNames:
                    print(f"\t\t\t{benchName}")


def getSmallBenches(target="vl", threads=None):
    assert target in ["vl", "hw", "baseline"], "ASSERT 21"
    useCoarse = {"ntt256": 128, "vortex2t2c": 128, "chronos2t2c_sssp": 128, "chronos2t2c_riscv": 128}
    if target == "baseline":
        assert threads is not None, f"Must provide threads in baseline benchmarks"
        for k in useCoarse.keys():
            useCoarse[k] = threads
    builds = []
    for (bench, coarsen) in useCoarse.items():
        builds.append(Benchmark.from_str(f"{bench}__{coarsen}z_256tc_60b.{target}"))
    return builds

def getMediumBenches(target="vl", threads=None):
    assert target in ["vl", "hw", "baseline"], "ASSERT 22"
    useCoarse = {"ntt1024": 512, "vortex4t2c": 128, "chronos4t2c_sssp": 64, "chronos4t2c_riscv": 64}
    if target == "baseline":
        assert threads is not None, f"Must provide threads in baseline benchmarks"
        for k in useCoarse.keys():
            useCoarse[k] = threads
    builds = []
    for (bench, coarsen) in useCoarse.items():
        builds.append(Benchmark.from_str(f"{bench}__{coarsen}z_256tc_60b.{target}"))
    return builds

def getLargeBenches(target="vl", threads=None):
    assert target in ["vl", "hw", "baseline"], "ASSERT 23"
    useCoarse = {"ntt4096": [512, 1024], "vortex8t2c": [128, 256], "chronos8t2c_sssp": [64, 128], "chronos8t2c_riscv": [64, 128]}
    if target == "baseline":
        assert threads is not None, f"Must provide threads in baseline benchmarks"
        for k in useCoarse.keys():
            useCoarse[k] = [threads]
    builds = []
    for (bench, coarsenList) in useCoarse.items():
        for coarsen in coarsenList:
            builds.append(Benchmark.from_str(f"{bench}__{coarsen}z_256tc_60b.{target}"))
    return builds

def getExtraLargeBenches(target="vl", threads=None):
    assert target in ["vl", "hw", "baseline"], "ASSERT 23"
    useCoarse = {"vortex16t2c": [128, 256], "chronos16t2c_sssp": [64, 128], "chronos16t2c_riscv": [64, 128]}
    if target == "baseline":
        assert threads is not None, f"Must provide threads in baseline benchmarks"
        for k in useCoarse.keys():
            useCoarse[k] = [threads]
    builds = []
    for (bench, coarsenList) in useCoarse.items():
        for coarsen in coarsenList:
            builds.append(Benchmark.from_str(f"{bench}__{coarsen}z_256tc_60b.{target}"))
    return builds

def printAllResults(allTables):
    s = ""
    # Master table
    master = ["testFail", "simSpeed", "cycles", "utilization", "skipPerc", "ipc-core", "instructions", "tasks", "totalEnqs"]
    common_cols = None
    for m in master:
        table = allTables[m]
        if common_cols is None:
            common_cols = set(table.columns)
        else:
            common_cols &= set(table.columns)
    common_cols = list(common_cols)
    merged = reduce(lambda left, right: pd.merge(left, right, on=common_cols, how="outer"), [allTables[m] for m in master])
    merged = merged.drop(columns=["cfg", "tasksPerTile", "l2CacheSizeKb", "target"])
    s += f"===================== MASTER\n"
    s += f"{merged.to_string(index=False)}\n"

    # Individual tables
    for tableName, table in allTables.items():
        s += f"===================== {tableName}\n"
        s += f"{table.to_string(index=False)}\n"
    return s

def genericCallback(exp, safePrint=print):
    def find_filepath(orig):
        i = 0
        while True:
            n = f"{orig}.{i}"
            if not os.path.isfile(n):
                return n
            i += 1

    name = exp.name
    if globalData["args"].buildName:
        name = f"{name}.{globalData['args'].buildName}"
    filepath = os.path.join(globalData["buildDir"], f"{name}.genericCallback.experiment")
    filepath = find_filepath(filepath)
    with open(filepath, "w") as f:
        f.write(printAllResults(getConfigsResults(exp.configs)))
    safePrint(f"[{exp.name}] Experiment Updated: {filepath}")


def isca26_benches(scale, scaleBuilds, target="hw"):
    if scale:
        nttSizes      = [256, 1024, 2048, 4096, 8192]
        systolicSizes = [64, 128, 256, 512, 1024]
        coresSizes    = [1024, 2048, 4096, 8192, 16384]
    else:
        nttSizes      = [2048]
        systolicSizes = [256]
        coresSizes    = [4096]

    main = False
    if scale or scaleBuilds:
        cu            = [("n", 1), ("y", 2)]
    else:
        main = True
        cu            = [("n", 1), ("y", 2), ("y", 3)]

    if target == "baseline":
        cu = [("n", 1)]
        #cu            = [("n", 1)]
    #cu            = [("n", 1)]
    benchs = []
    #for selective in ["DF"]:
    for selective in ["DF"]:
        #for coarsen, unroll in [("n", 1)]:
        #for coarsen, unroll in [("n", 1), ("y", 2)]:
        #for coarsen, unroll in [("n", 1)]:
        for coarsen, unroll in cu:
            for nttSize in nttSizes:
                if main:
                    benchs.append(Benchmark.from_str(f"ntt{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                #benchs.append(Benchmark.from_str(f"nttRetimed{nttSize}__{unroll}u_{coarsen}c.{target}"))
                benchs.append(Benchmark.from_str(f"nttVirtualized{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))

            for systolicSize in systolicSizes:
                if main:
                    benchs.append(Benchmark.from_str(f"systolic{systolicSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                #benchs.append(Benchmark.from_str(f"systolicRetimed{systolicSize}__{unroll}u_{coarsen}c.{target}"))
                benchs.append(Benchmark.from_str(f"systolicVirtualized{systolicSize}__{unroll}u_{coarsen}c.{target}.{selective}"))

            for coresSize in coresSizes:
                benchs.append(Benchmark.from_str(f"cores{coresSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                benchs.append(Benchmark.from_str(f"coresWithCaches{coresSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
    return benchs

def isca26_builds(scale):
    builds = []

    if scale:
        devices = [1, 2, 4, 8]
    else:
        devices = [8]

    build_configs = []
    build_configs.extend(dict_permute({
        "devices": devices,
        ##############################
        "tiles": [68],
        "coresPerTile": [4],
        "tasksPerTile": [1024],
        ##############################
        #"tiles": [36],
        #"coresPerTile": [8],
        #"tasksPerTile": [2048],
        ##############################
        "frequency": [400],
    }))

    builds = [Build(c) for c in build_configs]

    return builds



def isca26_configs(scaleBuilds, scaleBenchs):
    benchs = isca26_benches(scaleBenchs, scaleBuilds)
    builds = isca26_builds(scaleBuilds)
    configs = [Configuration(build, bench) for (build, bench) in product(builds, benchs)]
    return configs

def isca26_unrolling_impact_configs():
    benchs = []
    if True:
        target = "hw"
        nttSizes      = [2048]
        systolicSizes = [256]
        coresSizes    = [4096]
        benchs = []
        for selective in ["DF"]:
            #for coarsen, unroll in [("n", 1), ("n", 2), ("y", 2), ("y", 3), ("y", 4)]:
            for coarsen, unroll in [("n", 1), ("y", 2)]:
                for nttSize in nttSizes:
                    benchs.append(Benchmark.from_str(f"ntt{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                    benchs.append(Benchmark.from_str(f"nttVirtualized{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))

                for systolicSize in systolicSizes:
                    benchs.append(Benchmark.from_str(f"systolic{systolicSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                    benchs.append(Benchmark.from_str(f"systolicVirtualized{systolicSize}__{unroll}u_{coarsen}c.{target}.{selective}"))

    builds = isca26_builds(False)
    configs = [Configuration(build, bench) for (build, bench) in product(builds, benchs)]
    return configs

def isca26_selective_impact_configs():
    configs = []
    scales = [1, 2, 4, 8, 16, 32]

    for scale in scales:
        benchs = []
        if True:
            target = "hw"
            nttSizes      = [int(256/scale)]
            benchs = []
            for selective in ["DF", "SE"]:
                #for coarsen, unroll in [("n", 1), ("n", 2), ("y", 2), ("y", 3), ("y", 4)]:
                for coarsen, unroll in [("n", 1), ("y", 2)]:
                    for nttSize in nttSizes:
                        benchs.append(Benchmark.from_str(f"nttVirtualized{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))

        builds = []
        if True:
            devices = [1]
            build_configs = []
            build_configs.extend(dict_permute({
                "devices": devices,
                "tiles": [int(32/scale)],
                "coresPerTile": [8],
                "tasksPerTile": [2048],
                "frequency": [400],
            }))

            builds = [Build(c) for c in build_configs]

        configs.extend([Configuration(build, bench) for (build, bench) in product(builds, benchs)])
    return configs

def isca26_unrolling_impact(exps):
    configs = isca26_unrolling_impact_configs()
    exps.append(Experiment(f"isca26-unroll-impact", configs, genericCallback))

def isca26_selective_impact(exps):
    configs = isca26_selective_impact_configs()
    exps.append(Experiment(f"isca26-selective-impact", configs, genericCallback))

def isca26_baseline(exps):

    benchs = isca26_benches(False, True, "baseline")

    build_configs = dict_permute({
        "cfg": ["baseline"],
        "devices": [1],
        "tiles": [1],
        "coresPerTile": [1, 2, 4, 8, 16, 32, 40],
        "tasksPerTile": [1],
        "l2CacheSizeKb": [1],
    })
    builds = [Build(c) for c in build_configs]

    configs = [Configuration(build, bench) for (build, bench) in product(builds, benchs)]

    exps.append(Experiment(f"isca26-main-baseline", configs, genericCallback))

def isca26_main(exps):
    configs = isca26_configs(False, False)
    exps.append(Experiment(f"isca26-main-lotus", configs, genericCallback))


def isca26_scale_hw(exps):
    configs = isca26_configs(True, False)
    exps.append(Experiment(f"isca26-scale-hw", configs, genericCallback))

def isca26_scale_benchs(exps):
    configs = isca26_configs(False, True)
    exps.append(Experiment(f"isca26-scale-benchs", configs, genericCallback))

def doNow(exps):

    def getBenches(target):
        benchs = []
        #for selective in ["DF", "SE"]:
        for selective in ["DF"]:

            ##for unroll, coarsen in [(1, "n"), (2, "n"), (2, "y")]:
            nttSizes = [128, 256, 512, 1024]
            systolicSizes = [] # 64
            unrolls = [1, 2, 4, 5, 6, 7, 8, 16, 24, 32, 48, 64]

            coarsen = "n"
            for unroll in [1]:
                for nttSize in nttSizes:
                    benchs.append(Benchmark.from_str(f"ntt{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                for systolicSize in systolicSizes:
                    benchs.append(Benchmark.from_str(f"systolic{systolicSize}__{unroll}u_{coarsen}c.{target}.{selective}"))

            coarsen = "y"
            for unroll in unrolls:
                for nttSize in nttSizes:
                    benchs.append(Benchmark.from_str(f"ntt{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                for systolicSize in systolicSizes:
                    benchs.append(Benchmark.from_str(f"systolic{systolicSize}__{unroll}u_{coarsen}c.{target}.{selective}"))


        return benchs

    for target in ["hw", "vl"]:
        builds = []

        build_configs = []
        build_configs.extend(dict_permute({
            #"devices": [1, 2, 4],
            #"devices": [4],
            "devices": [1],
            "tiles": [68],
            #"tiles": [4],
            #"tiles": [1],
            "coresPerTile": [4],
            "tasksPerTile": [1024],
            "frequency": [400],
            #"selective": [False],
        }))

        builds = [Build(c) for c in build_configs]

        configs = [Configuration(build, bench) for (build, bench) in product(builds, getBenches(target))]

        exps.append(Experiment(f"now-{target}", configs, genericCallback))



def doNowBaseline(exps):

    def getBenches(target):
        benchs = []
        for selective in ["DF", "SE"]:

            nttSizes = [64]
            systolicSizes = [32]
            coresSizes = [32]
            unrolls = [1]

            coarsen = "n"
            for unroll in [1]:
                for nttSize in nttSizes:
                    benchs.append(Benchmark.from_str(f"ntt{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                for systolicSize in systolicSizes:
                    benchs.append(Benchmark.from_str(f"systolic{systolicSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                for coresSize in coresSizes:
                    benchs.append(Benchmark.from_str(f"cores{coresSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                    benchs.append(Benchmark.from_str(f"coresWithCaches{coresSize}__{unroll}u_{coarsen}c.{target}.{selective}"))

            coarsen = "y"
            for unroll in unrolls:
                for nttSize in nttSizes:
                    benchs.append(Benchmark.from_str(f"ntt{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                for systolicSize in systolicSizes:
                    benchs.append(Benchmark.from_str(f"systolic{systolicSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                for coresSize in coresSizes:
                    benchs.append(Benchmark.from_str(f"cores{coresSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                    benchs.append(Benchmark.from_str(f"coresWithCaches{coresSize}__{unroll}u_{coarsen}c.{target}.{selective}"))


        return benchs

    for target in ["baseline"]:
        builds = []

        build_configs = []
        build_configs.extend(dict_permute({
            "cfg": ["baseline"],
            "devices": [1],
            "tiles": [1],
            "coresPerTile": [1, 2],
            "tasksPerTile": [1],
            "l2CacheSizeKb": [1]
        }))

        builds = [Build(c) for c in build_configs]

        configs = [Configuration(build, bench) for (build, bench) in product(builds, getBenches(target))]

        exps.append(Experiment(f"now-{target}", configs, genericCallback))


def unitExp(exps):
    def getBenches(target):
        benchs = []
        ## Fib
        #for fib in ["basic_reg", "basic_mem"]:
        #    benchs.append(Benchmark.from_str(f"unit_{fib}_fib.{target}"))

        ## custom_type
        #for i in range(5):
        #    benchs.append(Benchmark.from_str(f"unit_custom_type_{i}.{target}"))

        ## packing
        #for i in range(4):
        #    benchs.append(Benchmark.from_str(f"unit_packing_{i}.{target}"))

        ## overflow
        #for i in range(1):
        #    benchs.append(Benchmark.from_str(f"unit_overflow_{i}.{target}"))

        ## same_cycle
        #for i in range(1):
        #    benchs.append(Benchmark.from_str(f"unit_same_cycle_{i}.{target}"))

        # selective
        #for i in range(1):
        #    benchs.append(Benchmark.from_str(f"unit_selective_{i}.{target}"))

        # pipeline
        for i in range(2):
            benchs.append(Benchmark.from_str(f"unit_pipeline_{i}.{target}"))

        return benchs

    for target in ["hw", "vl"]:
        builds = []


        build_configs = []
        if target == "hw":
            build_configs.extend(dict_permute({
                "devices": [1],
                "tiles": [1],
                "coresPerTile": [8],
                "tasksPerTile": [2048],
                "frequency": [300],
                "selective": [True, False],
            }))
        elif target == "vl":
            build_configs.extend(dict_permute({
                "devices": [1],
                "tiles": [1],
                "coresPerTile": [1],
                "tasksPerTile": [2048],
                "frequency": [300],
            }))
        else:
            assert False, f"Unkown target: {target}"

        builds = [Build(c) for c in build_configs]

        configs = [Configuration(build, bench) for (build, bench) in product(builds, getBenches(target))]

        exps.append(Experiment(f"unit-{target}", configs, genericCallback))


def demoExperiment(exps):
    def getBenches(target):
        benchs = []
        for selective in ["DF", "SE"]:

            nttSizes = [64]
            systolicSizes = [32]
            coresSizes = [32]
            unrolls = [1]

            coarsen = "n"
            for unroll in [1]:
                for nttSize in nttSizes:
                    benchs.append(Benchmark.from_str(f"ntt{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                for systolicSize in systolicSizes:
                    benchs.append(Benchmark.from_str(f"systolic{systolicSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                for coresSize in coresSizes:
                    benchs.append(Benchmark.from_str(f"cores{coresSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                    benchs.append(Benchmark.from_str(f"coresWithCaches{coresSize}__{unroll}u_{coarsen}c.{target}.{selective}"))

            coarsen = "y"
            for unroll in unrolls:
                for nttSize in nttSizes:
                    benchs.append(Benchmark.from_str(f"ntt{nttSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                for systolicSize in systolicSizes:
                    benchs.append(Benchmark.from_str(f"systolic{systolicSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                for coresSize in coresSizes:
                    benchs.append(Benchmark.from_str(f"cores{coresSize}__{unroll}u_{coarsen}c.{target}.{selective}"))
                    benchs.append(Benchmark.from_str(f"coresWithCaches{coresSize}__{unroll}u_{coarsen}c.{target}.{selective}"))


        return benchs

    for target in ["hw", "vl"]:
        builds = []

        build_configs = []
        build_configs.extend(dict_permute({
            "devices": [1],
            "tiles": [4],
            "coresPerTile": [4],
            "tasksPerTile": [1024],
            "frequency": [400],
            #"selective": [False],
        }))

        builds = [Build(c) for c in build_configs]
        configs = [Configuration(build, bench) for (build, bench) in product(builds, getBenches(target))]

        exps.append(Experiment(f"demo-{target}", configs, genericCallback))

def getAllExperiments():
    exps = []
    demoExperiment(exps)
    #unitExp(exps)
    isca26_baseline(exps)
    isca26_main(exps)
    isca26_scale_hw(exps)
    isca26_scale_benchs(exps)
    isca26_unrolling_impact(exps)
    isca26_selective_impact(exps)
    doNow(exps)
    doNowBaseline(exps)
    return exps

def getArgs(exps):
    names = [ex.name for ex in exps]
    parser = argparse.ArgumentParser()
    parser.add_argument('--buildName', default="", type=str)
    parser.add_argument("--buildDir", default=None, type=str)
    parser.add_argument('--useOldBuild', action='store_true', help="Uses Old Build")
    parser.add_argument('--buildOnly', action="store_true", help="Only call Scon")
    parser.add_argument('--runOnly', action="store_true", help="Only try to run the benchmarks")
    parser.add_argument("--forceUpdate", action="store_true", help="Force a succesful run to be re-updated (whether through scons or re-running the binary)")
    parser.add_argument("--checkOutputs", action="store_true", help="Force a succesful run to be re-updated (whether through scons or re-running the binary)")
    parser.add_argument("--noRebuildFailure", action="store_true", help="Doesn't rebuild builds that have failed")
    parser.add_argument("--xclbin", default=None, type=str, help="Path to xclbin")
    parser.add_argument("--describe", action="store_true", help="Describes experiments")
    parser.add_argument("--experiments", default=None, nargs="+", help=f"All experiments: {names}")
    args = parser.parse_args()
    if args.describe:
        print(f"Describing all Experiments: ")
        Experiment.prettyPrintExperiments(exps)
        exit(0)
    assert len(args.experiments) > 0, "ASSERT 24"
    if args.runOnly:
        assert args.useOldBuild, f"runOnly requires useOldBuild"
    return args


def getAbsBuildPath():
    assert os.path.exists("build"), f"Some build directory should have been created"
    baseBuildDir = "build"
    if os.path.islink(baseBuildDir):
        baseBuildDir = Path(baseBuildDir).resolve()
    return baseBuildDir
def setBuildDir():
    if globalData["args"].buildDir is not None:
        globalData["buildDir"] = globalData["args"].buildDir
    elif os.path.exists("build"):
        globalData["buildDir"] = getAbsBuildPath()
    else:
        print(f"Please either create a build directory or pass --buildDir")
        assert False, f"Unknown build"
    print(f"BuildDir={globalData['buildDir']}")
