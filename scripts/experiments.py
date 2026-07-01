#!/usr/bin/env python3

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import traceback
import random
import sys
import os
import shutil
current_directory = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, current_directory)

from resultsCommon import globalData, getAllExperiments, getArgs, Experiment, Configuration, getConfigStatus, runConfigDone, copyFile, deadlocked

from itertools import product
import concurrent.futures
import concurrent
import time
from datetime import datetime
import os
from pathlib import Path
import subprocess
import pandas as pd

import re
import argparse
import threading
from contextlib import contextmanager
import tempfile
import time

pd.set_option('display.max_rows', None)
pd.set_option('display.max_columns', None)
pd.set_option('display.width', None)
pd.set_option('display.max_colwidth', None)

def getSharedScratch():
    #if Path("/data/scratch").is_dir():
    pat = f"/data/scratch/{os.getenv('USER')}"
    if os.path.exists(pat):
        return pat
    else:
        basePath = f"{Path(__file__).parent.parent}"
        return f"{basePath}/sweep_lotus_build_shared"

def getPrivateScratch():
    hostname = subprocess.check_output('hostname', shell=True).decode().strip().split(".")[0]
    if hostname == "stg3":
        basePath = f"/scratchLarge/{os.getenv('USER')}"
    elif hostname in ["stg1", "stg2", "stg4", "bcn6"]:
        basePath = f"/scratch/{os.getenv('USER')}"
    else:
        basePath = f"{Path(__file__).parent.parent}"

    basePath = f"{basePath}/sweep_lotus_build"
    return basePath


def safePrint(s):
    import time
    with globalData["printLock"]:
        print(f"[{time.strftime('%X')}] {s}")
        import sys
        sys.stdout.flush()

#####################################################################################

class SafeAccess:
    def __init__(self, initial_data):
        self.data = initial_data
        self.lock = threading.Lock()

    @contextmanager
    def use(self):
        # Acquire the lock before entering the context
        self.lock.acquire()
        try:
            # Provide access to the data
            yield self.data
        finally:
            # Release the lock after leaving the context
            self.lock.release()

    @contextmanager
    def try_use_with_condition(self, callback):
        while True:
            self.lock.acquire()
            try:
                if callback(self.data):
                    yield self.data
                    break
                else:
                    self.lock.release()
                    time.sleep(0.1)
            except Exception as e:
                self.lock.release()
                raise e
            finally:
                if self.lock.locked():
                    self.lock.release()

class ResourcePool:
    def __init__(self, initial_list):
        self.resources = initial_list
        self.lock = threading.Lock()

    def take(self, n):
        if type(n) == str:
            n = 1
        while True:
            with self.lock:
                if len(self.resources) >= n:
                    taken_resources = [self.resources.pop() for _ in range(n)]
                    return taken_resources
            time.sleep(0.1)

    def return_back(self, items):
        with self.lock:
            self.resources.extend(items)

    @contextmanager
    def take_and_return(self, n):
        items = self.take(n)
        try:
            yield items
        finally:
            self.return_back(items)

class NamedResourcePool:
    def __init__(self, count):
        self.count     = count
        self.resources = set()
        self.lock = threading.Lock()

    def take(self, n):
        assert type(n) == str
        while True:
            with self.lock:
                if ".vl" in n:
                    self.count = 1
                if n not in self.resources and len(self.resources) < self.count:
                    self.resources.add(n)
                    return n
            time.sleep(0.1)

    def return_back(self, res):
        with self.lock:
            self.resources.remove(res)

    @contextmanager
    def take_and_return(self, res):
        _ = self.take(res)
        try:
            yield res
        finally:
            self.return_back(res)

class ResourceDict:
    def __init__(self, d = None):
        if d is None:
            d = {}
        self.d = SafeAccess(d)

    def take(self, n):
        done = False
        while not done:
            with self.d.use() as d:
                if not d.get(n, False):
                    d[n] = True
                    done = True
                else:
                    time.sleep(0.1)
    def return_back(self, n):
        assert n is not None, "ASSERT 12"
        done = False
        with self.d.use() as d:
            assert n in d.keys(), "ASSERT 13"
            assert d[n] == True, "ASSERT 14"
            d[n] = False

    @contextmanager
    def take_and_return(self, n):
        items = self.take(n)
        try:
            yield items
        finally:
            self.return_back(n)

class InitializeResourceDict:
    def __init__(self, d=None):
        if d is None:
            d = {}
        self.d = SafeAccess(d)
        self.initialized_resources = set()

    def take(self, n):
        return n
        while True:
            with self.d.use() as d:
                if n in self.initialized_resources:
                    #safePrint(f"[InitializeResourceDict] Found {n} in {self.initialized_resources}")
                    return  # Resource already initialized, no need to wait

                if not d.get(n, False):
                    d[n] = True
                    #safePrint(f"[InitializeResourceDict] GAVE {n} to initialize -- {self.initialized_resources}")
                    return  # Resource taken for initialization
                else:
                    time.sleep(0.1)

    def return_back(self, n):
        return
        with self.d.use() as d:
            assert n in d, "ASSERT 13"
            d[n] = False
            self.initialized_resources.add(n)  # Mark resource as initialized
            #safePrint(f"[InitializeResourceDict] RETURN {n}, done init -- {self.initialized_resources}")

    @contextmanager
    def take_and_return(self, n):
        self.take(n)
        try:
            yield
        finally:
            self.return_back(n)

class FpgaResourcePool:
    #FPGA_LIST = ["stg3-01:00.1", "stg3-81:00.1", "stg3-a1:00.1", "stg3-c1:00.1",]
    #FPGA_LIST = ["stg4-01:00.1", "stg4-21:00.1", "stg4-81:00.1", "stg4-c1:00.1"]
    FPGA_LIST = ["stg3-01:00.1", "stg3-81:00.1", "stg3-a1:00.1", "stg3-c1:00.1",
                "stg4-01:00.1", "stg4-21:00.1", "stg4-81:00.1", "stg4-c1:00.1"]

    def __init__(self):
        self.lock = threading.Lock()
        self.allocated = {res: False for res in FpgaResourcePool.FPGA_LIST}

    def take(self, n):
        while True:
            with self.lock:
                configuration = self._find_valid_configuration(n)
                if configuration:
                    for res in configuration:
                        self.allocated[res] = True
                    return configuration
            time.sleep(0.1)

    def return_back(self, items):
        with self.lock:
            for item in items:
                self.allocated[item] = False

    @contextmanager
    def take_and_return(self, n):
        items = self.take(n)
        try:
            yield items
        finally:
            self.return_back(items)

    def _find_valid_configuration(self, n):
        if n == 1:
            for i in range(len(FpgaResourcePool.FPGA_LIST)):
                if not self.allocated[FpgaResourcePool.FPGA_LIST[i]]:
                    return [FpgaResourcePool.FPGA_LIST[i]]
        elif 2 <= n <= 4:
            for i in range(len(FpgaResourcePool.FPGA_LIST) - n + 1):
                slice_resources = FpgaResourcePool.FPGA_LIST[i:i+n]
                if all(res.startswith("stg3") for res in slice_resources) or \
                   all(res.startswith("stg4") for res in slice_resources):
                    if all(not self.allocated[res] for res in slice_resources):
                        return slice_resources
        elif n == 8:
            if all(not self.allocated[res] for res in FpgaResourcePool.FPGA_LIST):
                return FpgaResourcePool.FPGA_LIST
        return None

globalData["buildResources"]            = NamedResourcePool(100)
#globalData["buildResources"]            = Resourcepool(list(range(40)))
globalData["runResources"]              = ResourcePool(list(range(120)))
globalData["fpgaResources"]             = FpgaResourcePool()
globalData["buildsFinished"]            = SafeAccess([])
globalData["runsFinished"]              = SafeAccess([])
globalData["mainThreadSawRunsFinished"] = []
globalData["uniqueConfigs"]             = None
globalData["experimentsFinished"]       = []
globalData["experimentsToRun"]          = []
#globalData["buildLock"]                = InitializeResourceDict({})
globalData["buildLock"]                 = InitializeResourceDict({})
globalData["printLock"]                 = threading.Lock()
globalData["args"]                      = None
globalData["buildDir"]                  = None


def createEmptyFile(f):
    open(f, "w").close()

def saveConfigStatus(config, stage, status):
    assert stage in ["build", "run"], "ASSERT 15"
    assert status in ["pass", "fail"], "ASSERT 16"
    buildDir = globalData["buildDir"]

    base = os.path.join(buildDir, f"{config.to_str(stage == 'run')}")

    for cs in ["pass", "fail"]:
        subprocess.run(["rm", "-f", f"{base}.{stage}.{cs}"], capture_output=True)

    open(f"{base}.{stage}.{status}", "w").close()


@contextmanager
def finishBuild(config):
    try:
        #decompress_tar_gz(os.path.join(globalData["buildDir"], config.build.to_str(), f"{config.bench.to_str()}.tar.gz"), safePrint)
        #decompress_tar_gz(os.path.join(globalData["buildDir"], config.build.to_str(), f"{config.bench.to_str_no_target()}.tar.gz"), safePrint)
        yield None
        with globalData["buildsFinished"].use() as buildsFinished:
            buildsFinished.append(config.to_str())
            safePrint(f"[BuildStatus] Finished {len(buildsFinished)}/{len(globalData['uniqueConfigs'])}")
    except Exception as e:
        safePrint(f"finishBuild exception: {e}")

@contextmanager
def finishRun(config):
    try:
        yield None
        with globalData["runsFinished"].use() as runsFinished:
            runsFinished.append(config.to_str())
            safePrint(f"[RunStatus] Finished {len(runsFinished)}/{len(globalData['uniqueConfigs'])}")
        #compress_item(os.path.join(globalData["buildDir"], config.build.to_str(), config.bench.to_str()), safePrint)
        #compress_item(os.path.join(globalData["buildDir"], config.build.to_str(), config.bench.to_str_no_target()), safePrint)
    except Exception as e:
        safePrint(traceback.format_exc())
        safePrint(f"finishRun exception: {e}")

def getAbsBuildPath():
    assert os.path.exists("build"), f"Some build directory should have been created"
    baseBuildDir = "build"
    if os.path.islink(baseBuildDir):
        baseBuildDir = Path(baseBuildDir).resolve()
    return baseBuildDir

def run_func_parallel(func, args, poll):
    results = []
    stop_polling = threading.Event()
    threads_finished = threading.Event()

    def poller():
        manualStop = False
        while not stop_polling.is_set():
            if not poll(threads_finished.is_set()):
                safePrint("Stopping polling manually")
                manualStop = True
                stop_polling.set()
            time.sleep(0.1)
        if not manualStop:
            poll(True)

    # Start the poller thread
    poll_thread = threading.Thread(target=poller)
    poll_thread.start()

    with concurrent.futures.ThreadPoolExecutor() as executor:
        futures = []
        for arg in args:
            futures.append(executor.submit(func, arg))
        try:
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                results.append(result)
        except Exception as e:
            safePrint(f"zamba Exception: {e}")
            safePrint(f"Exception type: {type(e)}")
            safePrint("Traceback:")
            for future in futures:
                future.cancel()
            executor.shutdown(wait=False)
            stop_polling.set()
            poll_thread.join()
            raise e
        finally:
            safePrint(f"Finally setting threads_finished")
            threads_finished.set()
            stop_polling.set()
            poll_thread.join()

    return results

def doBuildConfig(config):
    time.sleep(random.uniform(0, 5))
    parallelism_per_build = 60
    cmd = ["scons", f"-j{parallelism_per_build}"]

    if globalData["args"].checkOutputs:
        cmd.append(f"--checkOutputs")

    cmd.append(f"--buildDir={globalData['buildDir']}")

    for flag, value in config.build.config.items():
        cmd.append(f"--{flag}={value}")

    for flag, value in config.bench.bench.items():
        if flag in ["bench", "target", "selective"]:
            continue
        if flag == "enableCoarsening":
            assert isinstance(value, bool)
            if value == True:
                cmd.append("--enableCoarsening")
            continue
        cmd.append(f"--{flag}={value}")

    if config.bench.bench["target"] == "baseline":
        cmd.append(f"--cfg=baseline")

    cmd.append(config.bench.to_str(False))

    if not globalData["args"].runOnly:
        ex = None
        with globalData["buildLock"].take_and_return(config.build.to_str()):
            logFile = os.path.join(globalData['buildDir'], f"{config.to_str(False)}.build_log")
            with open(logFile, "w") as f:
                safePrint(f"[{config.to_str()}] BUILD CMD: {' '.join(cmd)}")
                ex = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT)
        assert ex is not None, "ASSERT 18"

        status = "SUCCESS"
        if ex.returncode != 0:
            saveConfigStatus(config, "build", "fail")
            status = f"FAILURE"
        else:
            saveConfigStatus(config, "build", "pass")
        safePrint(f"[{config.to_str()}] BUILD FINISHED: with status: {status} -- logFile: {logFile}")
    else:
        safePrint(f"[{config.to_str()}] BUILD FINISHED: with status: SKIPPED")


def doRunConfigLotus(config, fpga_ids):
    if globalData["args"].buildOnly:
        safePrint(f"[{config.to_str()}] Skipping RUN due to --buildOnly")
        return

    def sort_by_hostname(hostname, ids):
        yes = []
        no = []
        for i in ids:
            if hostname in i:
                yes.append(i)
            else:
                no.append(i)
        yes.extend(no)
        return yes

    def get_fpga_ids_args(remote_running_on, fpga_ids):
        args = []
        didOther = False
        for fpga_id in fpga_ids:
            fpga_id = fpga_id.split("-")
            fpga_host = fpga_id[0]
            aid       = fpga_id[1]
            if not didOther and (fpga_host != remote_running_on):
                didOther = True
                args.append(f"remote={fpga_host}")
            args.append(aid)
        return args

    def get_command_on_other_host(other_host, command):
        command = " ".join(command)
        import shlex
        return shlex.split(f"ssh {other_host} -t 'zsh -l -c \"source ~/.zshrc && {command}\"'")

    real_buildDir = os.path.join(globalData['buildDir'], config.build.to_str())
    real_bin = os.path.join(real_buildDir, config.bench.to_str(False))

    # Move binary to temporary directory that's shared across machines
    temp_base = getSharedScratch()
    if temp_base is None:
        temp_base = real_buildDir
    temp_base = f"{temp_base}/temp"
    os.makedirs(temp_base, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=temp_base) as temp_dir_path:
        temp_bin = os.path.join(temp_dir_path, config.bench.to_str(False))
        shutil.copy(real_bin, temp_bin)
        cmd = []
        cmd.append(f"{temp_bin}")

        if config.bench.bench["selective"]:
            cmd.append("-s")

        if config.bench.requires_fpga():
            hostname = subprocess.check_output('hostname', shell=True).decode().strip().split(".")[0]
            if hostname not in ["stg3", "stg4"]:
                safePrint(f"[{config.to_str()}] [ERROR] can't run on {hostname} Must be on stg3 or stg4")
                saveConfigStatus(config, "run", "fail")
                return
            other_hostname = {"stg3": "stg4", "stg4": "stg3"}
            xclbin = globalData["args"].xclbin
            if xclbin is None:
                safePrint(f"[{config.to_str()}] [ERROR] hw builds need xclbin, but none provided")
                saveConfigStatus(config, "run", "fail")
                return

            if fpga_ids[0].startswith(hostname):
                cmd.extend(get_fpga_ids_args(hostname, fpga_ids))
                cmd.append(xclbin)
            else:
                cmd.extend(get_fpga_ids_args(other_hostname[hostname], fpga_ids))
                cmd.append(xclbin)
                cmd = get_command_on_other_host(other_hostname[hostname], cmd)


        ###
        cmdJoined = ' '.join(cmd)
        logFile = os.path.join(real_buildDir, f"{config.bench.to_str(True)}.cout")
        if True:
            with open(f"{logFile}.runCmd", "w") as f:
                f.write(cmdJoined)
        tries = 0
        max_tries = 1
        if config.bench.requires_fpga():
            max_tries = 2
        temp_perf_counters = [os.path.join(temp_dir_path, f"{config.bench.to_str(True)}.perf_counters.{post}") for post in ["parent", "child"]]
        real_perf_counters = [os.path.join(real_buildDir, f"{config.bench.to_str(True)}.perf_counters.{post}") for post in ["parent", "child"]]
        while tries < max_tries:
            safePrint(f"[{config.to_str()}] RUN COMMAND({tries}): {cmdJoined}")
            safePrint(f"[{config.to_str()}] Producing Run Output in({tries}): {logFile}")
            with open(logFile, "w") as f:
                try:
                    timeoutMins = 1000
                    subprocess.run(cmd, stdout=f, cwd=real_buildDir, stderr=subprocess.STDOUT, timeout=timeoutMins*60)
                except Exception as e:
                    safePrint(f"[{config.to_str()}] ERROR:  Got exception when running cmd: {cmdJoined}")
                    safePrint(f"Exception string: {e}")
            if runConfigDone(config):
                break
            safePrint(f"[{config.to_str()}] Failure on try on try (deadlocked={deadlocked(config)}) {tries}/{max_tries}")
            if deadlocked(config):
                break
            copyFile(logFile, f"{logFile}.failure.try{tries}")
            for (t, r) in zip(temp_perf_counters, real_perf_counters):
                copyFile(t, f"{r}.failure.try{tries}")
            tries += 1
            time.sleep(10)
        # IMPORTANT: Copy back perf_couters file:
        time.sleep(10)
        subprocess.run(f'ls -lrh {temp_dir_path} 2>&1 > temp_dir.contents', cwd=real_buildDir, shell=True)
        for (t, r) in zip(temp_perf_counters, real_perf_counters):
            copyFile(t, r)

    try:
        bench = config.bench.to_str(True)
        subprocess.run(f'grep "HOST_PRINT" {bench}.cout 2>&1 > {bench}.host_cout', cwd=real_buildDir, shell=True)

        ex = subprocess.run(f"cat {bench}.cout", stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=real_buildDir, shell=True)
        lines = ex.stdout.decode()
        retcode = ex.returncode

        if True:
            # Get Perf Counters
            #marker = "==PERF STATS START=="
            #subprocess.run(f"grep -A999999 '{marker}' {bench}.cout | tail -n +2 > {bench}.perf_counters", cwd=real_buildDir, shell=True)

            # Results Identifier
            restPath = real_buildDir
            (restPath, buildType) = os.path.split(restPath)
            (_       , sweepId  ) = os.path.split(restPath)
            useName = config.to_str()
            useName = f"{sweepId}____{useName}"

            # Generate HTML File
            #subprocess.run(f"bash -c \"dashboard_generator.py {useName} {bench}.perf_counters > {useName}.html \"", cwd=real_buildDir, shell=True)

            # Genreate perf_heartbeat stats
            perfSummarize = f"{os.path.dirname(os.path.abspath(__file__))}/perfSummarize.py"
            subprocess.run(f"bash -c \"python3.10 {perfSummarize} {bench}.perf_counters {useName} \"", cwd=real_buildDir, shell=True)

            if os.path.isfile(os.path.join(real_buildDir, f"{bench}.perf_counters.parent")):
                rateAnalysis = f"{os.path.dirname(os.path.abspath(__file__))}/rateAnalysis.py"
                subprocess.run(f"bash -c \"python3.10 {rateAnalysis} {bench}.perf_counters > {bench}.rateAnalysis \"", cwd=real_buildDir, shell=True)
            else:
                with open(os.path.join(real_buildDir, f"{bench}.rateAnalysis"), "w") as f:
                    f.write("FILE NOT FOUND\n")

            #analyzeEdgeTimes = f"{os.path.dirname(os.path.abspath(__file__))}/analyzeEdgeTimes.py"
            #subprocess.run(f"bash -c \"python3.10 {analyzeEdgeTimes} {bench}.cout > {bench}.analyzeEdgeTimes \"", cwd=real_buildDir, shell=True)

            #analyzeEdgeTrace = f"{os.path.dirname(os.path.abspath(__file__))}/analyzeEdgeTrace.py"
            #subprocess.run(f"bash -c \"python3.10 {analyzeEdgeTrace} {bench}.cout > {bench}.analyzeEdgeTrace \"", cwd=real_buildDir, shell=True)

            #analyzeSwitch = f"{os.path.dirname(os.path.abspath(__file__))}/analyzeSwitch.py"
            #subprocess.run(f"bash -c \"python3.10 {analyzeSwitch} {bench}.cout > {bench}.analyzeSwitch \"", cwd=real_buildDir, shell=True)

            #analyzeSwitchPorts = f"{os.path.dirname(os.path.abspath(__file__))}/analyzeSwitchPorts.py"
            #subprocess.run(f"bash -c \"python3.10 {analyzeSwitchPorts} {bench}.cout > {bench}.analyzeSwitchPorts \"", cwd=real_buildDir, shell=True)

            #staticGraphAnalysis = f"{os.path.dirname(os.path.abspath(__file__))}/../verilator/include/staticGraphAnalysis.py"
            #subprocess.run(f"bash -c \"python3.10 {staticGraphAnalysis} ./{config.bench.to_str_no_target()}/obj_dir/hostInit.h.dict {bench}.dynamic_analysis --runtime_file {bench}.cout \"", cwd=real_buildDir, shell=True)

        #if config.bench.bench['target'] == 'vl':
        #    for file_to_compress in [f"{bench}.cout", f"{bench}.vl"]:
        #        subprocess.run(f"xz -f {file_to_compress} ", cwd=real_buildDir, shell=True)
        #    subprocess.run(f"tar -czvf {bench}.tar.gz {bench} && rm -rf {bench}", cwd=real_buildDir, shell=True, capture_output=True)
        status = subprocess.run(f'grep "Execution completed" {bench}.host_cout', stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=real_buildDir, shell=True).stdout.decode().split("\n")[0]
    except Exception as e:
        safePrint(f"[{config.to_str()}] ERROR:  Got exception when doing perf stuff {e}")
        import traceback
        safePrint(traceback.format_exc())
        safePrint(e)
        status = "EXCEPTION"

    if retcode != 0:
        status = f"Fail=Return Code {retcode}"
        safePrint(f"[{config.to_str()}] RUN STATUS RET CODE: {status}")
        saveConfigStatus(config, "run", "fail")
        return
    if lines is None:
        safePrint(f"[{config.to_str()}] Lines is None")
        saveConfigStatus(config, "run", "fail")
        return

    lines = lines.split("\n")
    lines = [r.replace("\n", "") for r in lines if r]

    endRe    = re.compile(r"\[(\d*)\] Execution completed.*")
    timedOutRe = re.compile(r"\[(\d*)\] APPLICATION TIMED OUT!!")

    l = None
    for line in lines:
        if "Execution completed" in line:
            l = line
            break
        if "APPLICATION TIMED OUT" in line:
            if l is None:
                l = line

    if l is None or "TIMED OUT" in l:
        saveConfigStatus(config, "run", "fail")
    else:
        saveConfigStatus(config, "run", "pass")
    safePrint(f"[{config.to_str()}] RUN STATUS: {l} -- len: {len(lines)}")

def doRunConfigBaseline(config, _):
    if globalData["args"].buildOnly:
        safePrint(f"[{config.to_str()}] Skipping RUN due to --buildOnly")
        return

    def wrap_in_perf(cmd, path):
        return f"perf stat -x ',' --output {path} {cmd}"

    cmd = []
    if True:
        cmd.append(f"numactl --physcpubind=0-{config.build.config['coresPerTile']-1}")
    cmd.append(f"./{config.bench.to_str(False)}")

    buildDir = os.path.join(globalData['buildDir'], config.build.to_str())

    perfOut = os.path.join(buildDir, f"{config.bench.to_str(False)}.perf.csv")
    logFile = os.path.join(buildDir, f"{config.bench.to_str(False)}.cout")
    ###
    cmd = wrap_in_perf(' '.join(cmd), perfOut)
    safePrint(f"[{config.to_str()}] RUN COMMAND: {cmd}")
    safePrint(f"[{config.to_str()}] Producing Run Output in: {logFile}")
    status = "UNSET"
    with open(logFile, "w") as f:
        try:
            ex = subprocess.run(cmd, stdout=f, cwd=buildDir, stderr=subprocess.STDOUT, shell=True)
            saveConfigStatus(config, "run", "pass")
            if ex.returncode != 0:
                status = "FAIL"
            else:
                status = "PASS"
        except Exception as e:
            status = "EXCEPTION"
            safePrint(f"[{config.to_str()}] ERROR:  Got exception when running cmd: {cmd}")
            safePrint(e)
            saveConfigStatus(config, "run", "fail")

    safePrint(f"[{config.to_str()}] RUN STATUS: {status}")

def runConfig(config):
    if globalData['args'].forceUpdate:
        assert not globalData["args"].noRebuildFailure, f"Can't have --noRebuildFailure and --forceUpdate at the same time "
    noUpdate = not globalData["args"].forceUpdate
    buildDir = globalData["buildDir"]


    def getBuildStatus():
        if globalData["args"].noRebuildFailure:
            skipBuild = getConfigStatus(config, "build") == "fail"
        else:
            skipBuild = noUpdate and getConfigStatus(config, "build") == "pass"
        return skipBuild

    skipRun   = noUpdate and getConfigStatus(config, "run") == "pass"

    with finishBuild(config):
            with globalData["buildResources"].take_and_return(config.to_str(False)):
                if not getBuildStatus():
                    doBuildConfig(config)
                else:
                    safePrint(f"[{config.to_str()}] Skipping Build! forceUpdate={globalData['args'].forceUpdate}, noRebuildFailure={globalData['args'].noRebuildFailure}, buildStatus={getConfigStatus(config, 'build')}")

    def runHelper(runFunc, numFpgas):
        nonlocal config
        with finishRun(config):
            doWork = True
            if skipRun:
                safePrint(f"[{config.to_str()}] Skipping Run due to no --forceUpdate")
                doWork = False
            buildStatus = getConfigStatus(config, "build")
            if buildStatus != "pass":
                safePrint(f"[{config.to_str()}] Skipping Run due to buildStatus: {buildStatus}")
                doWork = False
            if doWork:
                if numFpgas is not None:
                    with globalData[f"fpgaResources"].take_and_return(numFpgas) as resources:
                        runFunc(config, resources)
                else:
                    runFunc(config, None)

    if config.bench.requires_fpga():
        runHelper(doRunConfigLotus, config.build.config["devices"])
        #with globalData[f"fpgaResources"].take_and_return(config.build.config["devices"]) as res:
    elif config.bench.bench["target"] == "baseline":
        with globalData["runResources"].take_and_return(config.bench.to_str(False)):
            runHelper(doRunConfigBaseline, None)
    else:
        assert config.bench.bench["target"] == "vl", "ASSERT 19"
        runHelper(doRunConfigLotus, None)

def mainThread(threadsFinished):
    experimentsToRun    = globalData["experimentsToRun"]
    experimentsFinished = globalData["experimentsFinished"]

    doneExps = len(experimentsToRun) == len(experimentsFinished)
    if not doneExps:
        with globalData["runsFinished"].use() as runsFinished:
            experiments_to_call = []
            for run in runsFinished:
                if run not in globalData["mainThreadSawRunsFinished"]:
                    for exp in experimentsToRun:
                        if exp.config_in_experiment(run):
                            if exp not in experiments_to_call:
                                experiments_to_call.append(exp)
            for exp in experiments_to_call:
                exp.callback(exp, safePrint)

            globalData["mainThreadSawRunsFinished"] = runsFinished[:]

        for exp in experimentsToRun:
            if exp.name not in experimentsFinished:
                if exp.check_finished():
                    experimentsFinished.append(exp.name)
                    safePrint(f"[ExperimentStatus] Finished {len(experimentsFinished)}/{len(experimentsToRun)}")

    doneExps = len(experimentsToRun) == len(experimentsFinished)
    if threadsFinished:
        assert doneExps, "ASSERT 20"
    pending = not doneExps
    if not pending:
        safePrint(f"NOTE: mainThread stopping itself")
    return pending

__timeStr = None
def getTimeSig():
    global __timeStr
    if __timeStr is None:
        startScriptTime = datetime.now()
        __timeStr = startScriptTime.strftime("%Y_%m_%d__%H_%M_%S")
    assert __timeStr is not None, f"Should get a valid time"
    return __timeStr

def getBuildSig(args, defaultSig):
    b = getTimeSig()
    if args.buildName:
        b = f"sweep___{args.buildName}__{b}"
    else:
        b = f"sweep___{defaultSig}__{b}"
    return b

def newBuild(args, defaultSig):
    b = getBuildSig(args, defaultSig)

    #if hostname not in ["stg3", "stg4"]:
    basePath = f"{getPrivateScratch()}/{b}"

    usePath = None
    if not os.path.exists(basePath):
        usePath = basePath
    else:
        i = 0
        while True:
            currPath = f"{basePath}-{i}"
            if not os.path.exists(currPath):
                usePath = currPath
                break
            if (i > 100):
                print(f"ERROR: i is at: {i}")
    assert usePath is not None, f"Should have assigned a path"
    safePrint(f"newBuild: `{usePath}`")
    os.system(f"mkdir -p {usePath} && rm -rf build && ln -s {usePath} build")

def runExperiments(args, experiments):
    print(f"Experiments to run:")
    all_exp_names = "___".join([exp.name for exp in experiments])
    Experiment.prettyPrintExperiments(experiments)
    if args.buildDir is None:
        createNewDir = ((not args.useOldBuild)) and (not args.runOnly)
        buildDoesntExist = not os.path.exists("build")
        safePrint(f"createNewDir: {createNewDir} -- buildDoesntExist: {buildDoesntExist}")
        if createNewDir or buildDoesntExist:
            newBuild(args, all_exp_names)
        globalData["buildDir"] = getAbsBuildPath()
    else:
        subprocess.run(f'mkdir -p {args.buildDir}', shell=True)
        globalData["buildDir"] = args.buildDir

    safePrint(f"buildDir: {globalData['buildDir']}")

    unique_configs = set()
    gexps = globalData["experimentsToRun"]
    hostname = subprocess.check_output('hostname', shell=True).decode().strip().split(".")[0]
    for experiment in experiments:
        gexps.append(experiment)
        [unique_configs.add(config.to_str()) for config in experiment.configs]
        for config in experiment.configs:
            if config.bench.requires_fpga():
                if args.xclbin is None:
                    safePrint(f"ERROR: Experiment: `{experiment.name}` Has config: `{config.to_str()}` which requires to set xclbin")
                    return
                if hostname not in ["stg3", "stg4"]:
                    safePrint(f"ERROR: Experiment: `{experiment.name}` Has config: `{config.to_str()}` which requires stg3 or stg4")
                    return
    globalData["args"] = args
    unique_configs = [Configuration.from_str(c) for c in unique_configs]
    globalData["uniqueConfigs"] = unique_configs
    run_func_parallel(runConfig, unique_configs, mainThread)

#####################################################################################


if __name__ == "__main__":
    experiments = getAllExperiments()
    args = getArgs(experiments)
    regexExps = [re.compile(e) for e in args.experiments]
    def matches_any_regex(regexExps, name):
        for r in regexExps:
            if r.match(name):
                return True
        return False

    filtered_experiments = [exp for exp in experiments if matches_any_regex(regexExps, exp.name)]

    assert len(filtered_experiments) > 0, f"Needs to match at least one experiment -- do --help"

    runExperiments(args, filtered_experiments)










None
