# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

from __future__ import (absolute_import, division, print_function)

import os, sys
import subprocess as sp
import contextlib
import fcntl
import time
import math
import importlib

# This is a complex project with several variables that must be in sync across
# source files in different languages (e.g., Verilog and C++). we also need to
# work around weird HDL tooling constraints, e.g., it's not easy to find the
# compile order of files in a Verilog project.
#
# To do this, we use configuration variables to (1) generate the source code
# from templates, and (2) determine the variant build directory. Note that
# builds are hierarchical: within build/, the system config is the first level,
# e.g., build/base8t8c1h2MBl2/, and many benchmarks and host configurations live
# within the second level, e.g., build/base8t/ntt.vl or build/base8t/ntt.u55c.
#
# This organization enables us to compile the FPGA image once per configuration,
# and then build different benchmark binaries and host configs within it.
# This is key, because synthesizing the FPGA bitstream is very slow.

# API version. This is used to protect against bugs stemming from using
# incompatible HW images and host/SW programs (e.g., trying to run old
# benchmarks on a new image). It's passed to the host and HW, and it's checked
# before every run.
# IMPORTANT: Update this on EVERY API-BREAKING CHANGE. For example, when
# changing the ISA, removing SIP elements, etc. Use YYYY_MM_DD_RR, where RR is
# a monotonically increasing revision to disambiguate changes made in the same
# day. This is a 32-bit integer (31, really...).
apiVersion = 2026_04_14_01

# System configs. These affect the generation of HDL code, and HDL is
# independent of any other parameters.
sysConfigs = {}

# Base configurations. These define common configs, so that you don't have to
# specify all options on the command line. Try to have sensible configurations
# for testing, using an entire FPGA, etc.

sysConfigs["serial"] = {
    "tiles" : 1,
    "coresPerTile" : 1,
    "tasksPerTile": 2048,
    "l2CacheSizeKb": 512,
    "l2CacheBanks": 4,
    "avgOutEdgesPerTask": 8,  # determines edge sender memory size (tasksPerTile*avgOutEdgesPerTask entries)
    "maxOutEdgesPerTask": 63, # per-task limit (set to 2^k-1 to maximize bits usage, e.g., 31 rake 5-bit offsets, but 32 requires 6 bits)
    "avgArgsPerTask": 4,  # determines args memory size
    "maxArgsPerTask": 15, # per-task limit
    "platform" : "u55c",
    "devices" : 1, # for multi-FPGA runs
    "tilesPerSwitchPort" : 1,
    "tilesPerMemChannel" : 1,
    "tilePairs" : False, # have pairs of tiles encapsulated in a single mkTilePair module; used only in some fastflow configs, to implement tiles in pairs (makes finding suitable pblocks more tractable)
    "frequency" : 300,
}

sysConfigs["base"] = {
    "tiles" : 16,
    "coresPerTile" : 16,
    "tasksPerTile": 2048,
    "l2CacheSizeKb": 512,
    "l2CacheBanks": 4,
    "avgOutEdgesPerTask": 8,
    "maxOutEdgesPerTask": 63,
    "avgArgsPerTask": 4,
    "maxArgsPerTask": 15,
    "platform" : "u55c",
    "devices" : 8,
    "tilesPerSwitchPort" : 1,
    "tilesPerMemChannel" : 1,
    "tilePairs" : False,
    "frequency" : 300,
}

# NOTE: This config is coupled with --fastflow. Using --fastflow will use this config unless told otherwise.
sysConfigs["fast"] = {
    "tiles" : 68,
    "coresPerTile" : 4,
    "tasksPerTile": 1024,
    "l2CacheSizeKb": 128,
    "l2CacheBanks": 2,
    "avgOutEdgesPerTask": 8,
    "maxOutEdgesPerTask": 63,
    "avgArgsPerTask": 4,
    "maxArgsPerTask": 15,
    "platform" : "u55c",
    "devices" : 1,
    "tilesPerSwitchPort" : 4,
    "tilesPerMemChannel" : 4,
    "tilePairs" : True,
    "tileGen" : "68t_pairs_sep",
    #"tileGen" : "68t_pairs", # variant with fewer pblocks (only top row); faster to compile, but relocation drops some routes due to differences in routing resources
    "tileMap" : "68t_pairs",
    "frequency" : 380,
}

# Old fast config, with 8 core per tile and 36 tiles (used in ISCA 2026 submission)
sysConfigs["fast8c"] = {
    "tiles" : 36,
    "coresPerTile" : 8,
    "tasksPerTile": 2048,
    "l2CacheSizeKb": 256,
    "l2CacheBanks": 2,
    "avgOutEdgesPerTask": 8,
    "maxOutEdgesPerTask": 63,
    "avgArgsPerTask": 4,
    "maxArgsPerTask": 15,
    "platform" : "u55c",
    "devices" : 1,
    "tilesPerSwitchPort" : 2,
    "tilesPerMemChannel" : 2,
    "tilePairs" : False,
    "tileGen" : "36t",
    "tileMap" : "36t",
    "frequency" : 350,
}

sysConfigs["baseline"] = {
    "tiles" : 0,
    "coresPerTile" : 1,
    "tasksPerTile": 0,
    "l2CacheSizeKb": 0,
    "l2CacheBanks": 4,
    "avgOutEdgesPerTask": 0,
    "maxOutEdgesPerTask": 0,
    "avgArgsPerTask": 0,
    "maxArgsPerTask": 0,
    "platform" : "cpu",
    "devices" : 0,
    "tilesPerSwitchPort" : 0,
    "tilesPerMemChannel" : 0,
    "tilePairs" : False,
    "frequency" : 0,
}

#### Locking a file
@contextlib.contextmanager
def Flock(filename, timeout=60.0):
    locked = False
    fd = os.open(filename, os.O_RDWR | os.O_CREAT | os.O_TRUNC)
    start_time = time.time()
    while time.time() < start_time + timeout:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            pass
        else:
            # Managed to aquire the lock quickly, don't bother printing any noise
            assert not locked
            locked = True
            break
    else:
        # Acquiring the lock is taking a while, let the user know what we're waiting on
        print('Blocking on lock ', filename)
        fcntl.flock(fd, fcntl.LOCK_EX)
        print('Unblocking. Acquired lock ', filename)
        assert not locked
        locked = True
    assert locked
    try:
        yield fd
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
        # Never delete the lock file, that would cause race conditions because
        # other processes could still have an open file descriptor for it!
        # https://github.com/tox-dev/py-filelock/issues/31
        #os.remove(filename)
        assert locked
        locked = False

# Configuration modifiers
AddOption("--cfg", default="serial", help="baseline system configuration")
AddOption("--devices", default=None, type=int, help="change config's default devices (FPGAs)")
AddOption("--tiles", default=None, type=int, help="change config's default tiles")
AddOption("--coresPerTile", default=None, type=int, help="change config's default cores per tile")
AddOption("--tasksPerTile", default=None, type=int, help="change config's default tasks per tile")
AddOption("--l2CacheSizeKb", default=None, type=int, help="change config's default L2 cache size")
AddOption("--l2CacheBanks", default=None, type=int, help="change config's default L2 cache banks")
AddOption("--tilesPerSwitchPort", default=None, type=int, help="change config's default tiles per task switch port")
AddOption("--tilesPerMemChannel", default=None, type=int, help="change config's default tiles per memory channel")
AddOption("--platform", default=None, type=str, help="change config's default FPGA platform")
AddOption("--frequency", default=None, type=int, help="change config's target FPGA frequency (in MHz)")

AddOption("--buildDir", default=None, type=str, help="Build directory path")
AddOption("--tag", default=None, type=str, help="Give the build directory name, suffixed by the tag (useful when e.g., building a series of xclbins concurrently with the same configuration)")
AddOption("--reuseLastTagIdx", default=False, action="store_true", help="If found, reuses last tag index (useful when working with tags, e.g., to keep going on a build error)")

AddOption("--fastflow", default=False, action="store_true", help="Use RapidWright-based fast flow to build FPGA images")
AddOption("--reuseTiles", default=None, type=str, help="In fastflow mode, reuse tiles from a previous build (give build folder here)")
AddOption("--reuseLotusXO", default=None, type=str, help="Reuse lotus.xo from a previous build (give build folder here)")
AddOption("--reuseAuroraXO", default=None, type=str, help="Reuse aurora.xo from a previous build (give build folder here)")

AddOption("--nox", default=False, action="store_true", help="Avoid X values when compiling Bluespec to Verilog (less efficient, but retains correspondence between bluesim and Verilog, and may avoid x-related hw_emu simulation issues)")
AddOption("--debugBsv", default=False, action="store_true", help="Debug Configuration")
AddOption("--trace", default=False, action="store_true", help="Enable VCD tracing")
AddOption("--xunique", default=False, action="store_true", help="Initialize/assign x (undefined) values using unique values (Verilator only, requires runtime flags, see manual for usage)")
AddOption("--shh", default=False, action="store_true", help="Reduce output of tool calls (combine with --quiet to mute scons as well)")

# Benchmark options
AddOption("--unrollFactor", default=1, type=int, help="Temporal Unrolling Factor")
AddOption("--enableCoarsening", default=False, action="store_true", help="Enable coarsening in (lotus_exec) benchmarks")

AddOption("--nttSize", default=64, type=int, help="Size of NTT benchmark")
AddOption("--systolicSize", default=4, type=int, help="Size of Systolic Array benchmark")
AddOption("--coresSize", default=1, type=int, help="Number of cores in cores and coresWithCaches benchmark")

AddOption("--checkOutputs", default=False, action="store_true", help="Add tasks (and overheads) that check correctness")

isFastflow = GetOption("fastflow")
# An ASIC-only invocation elaborates RTL; no software, simulator, or FPGA
# toolchain is needed. Mixed/default builds retain the normal bootstrap.
asicOnly = bool(COMMAND_LINE_TARGETS) and all(t == "asic-tile" for t in COMMAND_LINE_TARGETS)


# Configuration step - check for external tools, and if not available, build them
# There are two levels of external tools:
# 1. Unmanaged = Required in $PATH: bsc; vivado and v++ (if producing FPGA images)
# 2. Managed = Not in $PATH; you can specify an existing directory instead, and we build and install them under ext/ if unspecified: msc, RISC-V toolchain, LLVM Lotus, Spike, verilator, RapidWright
#
# Managed tools are kept out of $PATH to avoid versioning conflicts (e.g., we don't want calls to clang to use the Lotus version, we use a known-working verion of the RISC-V toolchain, or we use a specific version of verilator that often differs from the system's). However, you can still use preinstalled versions (useful if e.g. you have multiple Lotus repositories, are on a shared cluster, etc.)

# All paths to external tools of the latter type
pathVars = Variables('.path_vars.py')
pathVars.Add(PathVariable('MINISPEC', 'Path to the Minispec compiler', None, PathVariable.PathIsDir))
pathVars.Add(PathVariable('RISCV_TOOLCHAIN', 'Path to the RISC-V toolchain (riscv32-unknown-elf)', None, PathVariable.PathIsDir))
pathVars.Add(PathVariable('SPIKE', 'Path to spike RISC-V simulator and pk (built for rv32)', None, PathVariable.PathIsDir))
pathVars.Add(PathVariable('LOTUS_LLVM', 'Path to the LLVM compiler with the Lotus calling convention', None, PathVariable.PathIsDir))
pathVars.Add(PathVariable('VERILATOR_ROOT', 'Path to verilator root directory (needs to be v4)', None, PathVariable.PathIsDir))
pathVars.Add(PathVariable('PATOH', 'Path to PaToH binary directory', None, PathVariable.PathIsDir))
pathVars.Add(PathVariable('RAPIDWRIGHT', 'Path to RapidWright binary', None, PathVariable.PathIsDir))

env = Environment(ENV = os.environ, tools = ['default', 'textfile'], variables = pathVars)

# Automatically build managed external tools
with Flock(".scons_untracked_lock"):
    if not env.Detect("bsc"):
        print(f"Missing Bluespec compiler bsc")
        print(f"Please install bsc in your system (https://github.com/B-Lang-org/bsc/releases), and ensure bsc is in your PATH")
        Exit(-1)

    def buildExtSw(name, buildCmds):
        logFileName = "ext_build.log"
        with open(logFileName, "a") as logFile:
            print(f"Building {name} under ext/...")
            try:
                sp.check_call(buildCmds, shell=True, stderr=sp.STDOUT, stdout=logFile)
            except:
                print(f"Build failed, check {logFileName}")
                Exit(-1)
            print("Done")

    if "MINISPEC" not in env:
        buildExtSw("Minispec", "mkdir -p ext/ && cd ext/ && ([ -d minispec ] || git clone --depth 1 https://github.com/minispec-hdl/minispec) && cd minispec && scons -j`nproc`")
        env["MINISPEC"] = "ext/minispec"

    if not asicOnly and "RISCV_TOOLCHAIN" not in env:
        buildExtSw("RISC-V toolchain", "mkdir -p ext/repos && cd ext/repos && ([ -d riscv-gnu-toolchain ] || git clone --depth 1 https://github.com/riscv-collab/riscv-gnu-toolchain -b 2026.06.06) && cd riscv-gnu-toolchain && mkdir -p ../../riscv_toolchain && ./configure --prefix=`realpath ../../riscv_toolchain` --with-arch=rv32ima --with-abi=ilp32 && make -j`nproc`")
        env["RISCV_TOOLCHAIN"] = "ext/riscv_toolchain"

    if not asicOnly and "SPIKE" not in env:
        buildExtSw("Spike", "mkdir -p ext/repos && cd ext/repos && ([ -d riscv-isa-sim ] || git clone --depth 1 https://github.com/riscv-software-src/riscv-isa-sim.git) && cd riscv-isa-sim && git submodule update --init --recursive && mkdir -p ../../spike && ./configure --prefix=`realpath ../../spike` && make -j`nproc` && make install")
        buildExtSw("RISC-V PK", f"cd ext/repos && ([ -d riscv-pk ] || git clone --depth 1 https://github.com/riscv-software-src/riscv-pk.git) && cd riscv-pk && mkdir -p build && cd build && PATH={os.path.abspath(env['RISCV_TOOLCHAIN'])}/bin:$PATH bash -c '../configure --prefix=`realpath ../../../spike` --host=riscv32-unknown-elf --with-arch=rv32i_zicsr_zifencei && make -j`nproc` && make install'")
        env["SPIKE"] = "ext/spike"

    if not asicOnly and "LOTUS_LLVM" not in env:
        buildExtSw("Lotus LLVM", "mkdir -p ext/repos && cd ext/repos && if [ ! -d llvm-project ]; then git clone --depth 1 --branch llvmorg-21.1.4 https://github.com/llvm/llvm-project.git && (cd llvm-project && git apply ../../../misc/lotus_llvm_patch/riscv_lotus_task_cc.patch); fi && cd llvm-project && mkdir -p ../../lotus_llvm && cmake -S llvm -B build -G Ninja -DCMAKE_BUILD_TYPE='Release' -DLLVM_ENABLE_PROJECTS='clang;lld' -DLLVM_ENABLE_LLD=ON -DLLVM_INSTALL_UTILS=ON -DCMAKE_INSTALL_PREFIX=`realpath ../../lotus_llvm` && ninja -C build install")
        env["LOTUS_LLVM"] = "ext/lotus_llvm"

    if not asicOnly and "VERILATOR_ROOT" not in env:
        buildExtSw("Verilator", "mkdir -p ext && cd ext && ([ -d verilator ] || git clone --depth 1 --branch v4.228 https://github.com/verilator/verilator) && cd verilator && autoconf && ./configure && make -j`nproc`")
        env["VERILATOR_ROOT"] = "ext/verilator"

    if not asicOnly and "PATOH" not in env:
        buildExtSw("PaToH", "mkdir -p ext/repos && cd ext/repos && ([ -f patoh-Linux-x86_64.tar.gz ] || wget https://faculty.cc.gatech.edu/~umit/PaToH/patoh-Linux-x86_64.tar.gz) && mkdir -p ../patoh && cd ../patoh && tar xf ../repos/patoh-Linux-x86_64.tar.gz")
        env["PATOH"] = "ext/patoh/build/Linux-x86_64"

    if not asicOnly and isFastflow and 'RAPIDWRIGHT' not in env:
        buildExtSw("RapidWright", "mkdir -p ext && cd ext && git clone --depth 1 https://github.com/Xilinx/RapidWright.git && (cd RapidWright && ./gradlew compileJava)")
        env['RAPIDWRIGHT'] = "ext/RapidWright"

    if not asicOnly:
        pathVars.Save('.path_vars.py', env)

    # Check python dependencies
    def checkPythonDep(package):
        res = sp.run(["pip3", "show", package], capture_output=True, text=True)
        if res.returncode != 0:
            print(f"Missing required python package: {package}")
            print(f"  pip3 show output: {res.stderr.strip()}")
            print(f"Please install this package, e.g., pip3 install {package} (or use a venv)")
            Exit(-1)
    if not asicOnly:
        checkPythonDep("networkx")
        checkPythonDep("pydot")
        checkPythonDep("sortedcontainers")

# The following paths are used by other tools and should be in the ENV
for path in ["MINISPEC", "RISCV_TOOLCHAIN", "SPIKE", "VERILATOR_ROOT", "PATOH"]:
    if path in env:
        env["ENV"][path] = os.path.abspath(env[path])


# Parse config
cfgName = GetOption("cfg")
if isFastflow and cfgName == "serial":
    cfgName = "fast"
if cfgName not in sysConfigs:
    print("ERROR: Base config %s not valid, must be one of %s" % (cfgName, str(sysConfig.keys())))
    sys.exit(-1)
cfg = sysConfigs[cfgName]
isBaseline = cfgName == "baseline"

for (name, suffix) in [("devices", "d"), ("tiles", "t"), ("coresPerTile", "c"), ("l2CacheSizeKb", "l2KB"), ("l2CacheBanks", "l2bn"),("tasksPerTile", "e"), ("tilesPerSwitchPort", "s"), ("tilesPerMemChannel", "m"), ("platform", ""), ("frequency", "MHz")]:
    if GetOption(name):
        cfg[name] = GetOption(name)
        cfgName += "%s%s" % (str(cfg[name]), suffix)

# tilePairs makes sense only for fastflow
cfg["tilePairs"] = cfg["tilePairs"] and isFastflow

if GetOption("nox"):
    cfgName += "_nox"

buildDirName = 'build'
if GetOption("buildDir"):
    buildDirName = GetOption("buildDir")
print(f"Build Directory Name: {buildDirName}")

# Import tilemap config as a module
tileMapCfg = None
if isFastflow:
    tileMapSrcFile =  f"config/fastflow_tilemap_{cfg['tileMap']}.py"
    tileMapSpec = importlib.util.spec_from_file_location("tileMap", tileMapSrcFile)
    tileMapCfg = importlib.util.module_from_spec(tileMapSpec)
    tileMapSpec.loader.exec_module(tileMapCfg)

# Set debug/trace flags (affects config name)
debugFlags = []
trace = GetOption("trace")
if len(debugFlags) or trace:
    cfgName = "debug_" + cfgName

tag = GetOption("tag")
reuseLastTagIdx = GetOption("reuseLastTagIdx")
if tag != None:
    prefix = time.strftime("%Y_%m_%d-")
    lastSameDateIdx = 0
    for k in [f.split("-")[1] for f in os.listdir(buildDirName) if f.startswith(prefix)]:
        try:
            n = int(k)
            lastSameDateIdx = max(n, lastSameDateIdx)
        except:
            pass
    cfgName = prefix + ("%02d-" % (lastSameDateIdx + (1 if (lastSameDateIdx == 0 or not reuseLastTagIdx) else 0))) + cfgName
    if (len(tag)): cfgName += "-" + tag
buildDir = os.path.join(buildDirName, cfgName)

# Copy all HDL files in a single folder
# NOTE: This works w.r.t deps, and while we could keep sources in place,
# copying eases concurrency: we can start a build and immediately go back to
# editing the source. This matters, because *packing* a kernel in Vitis can
# take minutes.
hdlSrcs = []
for fp in ["top/lotus.sv", "top/xrt_top.v", "top/*.vh", "sip/sip.sv", "sip/sip.vh", "xram/X*.sv", "utils/*.sv"]:
    hdlSrcs += Glob(os.path.join("lotus", fp))

hdlFiles = []
for file in hdlSrcs:
    dst = os.path.join(buildDir, "hdl", os.path.basename(file.rstr()))
    env.Command(dst, file, "printf '%s\\n\\n' '`include \"global_defines.vh\"' > $TARGET && cat $SOURCE >> $TARGET")
    hdlFiles.append(dst)

def getNumMemChannels():
    if cfg["tilesPerMemChannel"] == 0:
        # Baseline
        return 1
    else:
        return -(-cfg["tiles"] // cfg["tilesPerMemChannel"]) # ceiling division

# TODO: We need to also configure the actual connection to MultiTile
def axiDefs():
    mdefs = getNumMemChannels()
    cdefs = 0 if cfg["devices"] == 1 else cfg["devices"]
    return {
        "@@memAxiDefs" : " ".join("`MEM_AXI_DEF(m%02d)" % i for i in range(mdefs)),
        "@@memAxiConnects" : " ".join("`MEM_AXI_CONNECT(m%02d)" % i for i in range(mdefs)),
        "@@memAxiToTileIfcs" : " ".join("`MEM_AXI_TO_TILE_IFC(%02d, ifcName)" % i for i in range(mdefs)),
        "@@crossDeviceAxisDefs" : " ".join("`CROSS_DEVICE_AXIS_DEF(%d)" % i for i in range(cdefs)),
        "@@crossDeviceAxisConnects" : " ".join("`CROSS_DEVICE_AXIS_CONNECT(%d)" % i for i in range(cdefs)),
        "@@crossDeviceAxisTiles" : " ".join("`CROSS_DEVICE_AXIS_TILE(%d)" % i for i in range(cdefs)),
        "@@memAxiFires" : " ".join([f"`MEM_AXI_FIRE(m{i:02d})" for i in range(mdefs)]),
        "@@memAxiDestructs" : " ".join([f"`MEM_AXI_DESTRUCT(m{i:02d})" for i in range(mdefs)]),
        "@@memAxiTiles" : " ".join([f"`MEM_AXI_TILE(_{i}, m{i:02d})" for i in range(mdefs)])
    }

# Handle templated files
globalDefinesHdlFile = os.path.join(buildDir, "hdl", "global_defines.vh")
env.Substfile(globalDefinesHdlFile, "lotus/top/global_defines.vh.in",
    SUBST_DICT = {**{"@@" + key : str(value) for (key, value) in cfg.items()}, **axiDefs()})
hdlFiles = [globalDefinesHdlFile] + hdlFiles

####### Compile Bluespec to Verilog
bsvFilesOrig = sp.check_output(["find", "lotus/", "-name", "*.bsv"]).decode().split("\n")
msFilesOrig  = sp.check_output(["find", "lotus/", "-name", "*.ms" ]).decode().split("\n")

bsvFilesOrig = [f for f in bsvFilesOrig if f]
msFilesOrig  = [f for f in msFilesOrig if f]

bsvFilesCopy = [os.path.join(buildDir, "hdl/bsv", os.path.basename(f)) for f in bsvFilesOrig]
msFilesCopy  = [os.path.join(buildDir, "hdl/bsv", os.path.basename(f)) for f in msFilesOrig]

[env.Command(copyF, origF, "cp $SOURCE $TARGET") for (origF, copyF) in zip(bsvFilesOrig, bsvFilesCopy)]
[env.Command(copyF, origF, "cp $SOURCE $TARGET") for (origF, copyF) in zip(msFilesOrig, msFilesCopy)]

generatedCoreFromMs = os.path.join(buildDir, 'hdl', 'bsv', 'Core.bsv')
env.Command(generatedCoreFromMs, msFilesCopy + bsvFilesCopy, f"cd {os.path.join(buildDir, 'hdl/bsv')} && rm -f *.bo *.v && {env['ENV']['MINISPEC']}/msc -o bsv Core.ms")

allBsvFiles = [*bsvFilesCopy, generatedCoreFromMs]

# TODO: Make parametization cleaner
bscOptions = "-check-assert -aggressive-conditions -show-schedule"
if not GetOption("nox"):
    bscOptions += " -opt-undetermined-vals -unspecified-to X"

if GetOption("shh"):
    bscOptions += " -quiet"

# All BSV modules with (* synthesize *) pragmas. This needs to be in sync with
# the design, since it's used to derive dependences. We later check and error
# out if there's a mismatch here.
bsvSynthModules = ["MultiTile", "L2Cache", "L2CacheBank", "TaskUnit", "TaskPrioQueue", "TokenSwitch", "CoreReqSwitch", "CoreRespSwitchEven", "CoreRespSwitchOdd", "TokenSender", "MemToSIP"]
if cfg["tilePairs"]:
    bsvSynthModules.append("TilePair")

# Tag these modules with keep_hierarchy, which guides Vivado to preserve synthesis boundaries
bsvKeepHierarchyModules = ["CoreBsv", "L2Cache", "Tile", "TaskUnit"]
if cfg["tilePairs"]:
    bsvKeepHierarchyModules.append("TilePair")

bsvBlackBoxModules = []
if isFastflow:
    bsvBlackBoxModules.append("TilePair" if cfg["tilePairs"] else "Tile")

if not GetOption("debugBsv"):
    bsvSynthModules.extend(["CoreBsv", "Tile"])

bsvDefines = ""
if GetOption("debugBsv"):
    bsvDefines += " -D EXPOSE_MODULE_IDS_FOR_DEBUGGING "
#bsvDefines += " -D RUNTIME_ANALYSIS "
#bsvDefines += " -D FPGA_DEBUGGING "
if cfg["tilePairs"]:
    bsvDefines += " -D TILE_PAIRS "

# Floorplanning defines (override conservative defaults)
if isFastflow:
    numTiles = cfg["tiles"]
    tilesPerSwitchPort = cfg["tilesPerSwitchPort"]
    numLocalSwitchPorts = numTiles // tilesPerSwitchPort + (1 if numTiles % tilesPerSwitchPort != 0 else 0)
    tilesPerMemChannel = cfg["tilesPerMemChannel"]
    numMemChannels = numTiles // tilesPerMemChannel + (1 if numTiles % tilesPerMemChannel != 0 else 0)
    bsvDefines += ' -D MUX_TO_SWITCH_PIPE_LENGTHS="vec(' + ', '.join(str(s) for s in tileMapCfg.getMuxToSwitchPipeLengths(tilesPerSwitchPort)[:numLocalSwitchPorts]) + ')"'
    bsvDefines += ' -D MUX_TO_MEM_PIPE_LENGTHS="vec(' + ', '.join(str(s) for s in tileMapCfg.getMuxToMemPipeLengths(tilesPerMemChannel)[:numMemChannels]) + ')"'

    tileToSwitchMuxPipeLengths = [tileMapCfg.getPreMuxPipeLength(tileId, tilesPerSwitchPort) for tileId in range(numTiles)]
    if sum(tileToSwitchMuxPipeLengths) > 0:
        bsvDefines += ' -D TILE_TO_SWITCH_MUX_PIPE_LENGTHS="vec(' + ', '.join(str(s) for s in tileToSwitchMuxPipeLengths) + ')"'
    tileToMemMuxPipeLengths = [tileMapCfg.getPreMuxPipeLength(tileId, tilesPerMemChannel) for tileId in range(numTiles)]
    if sum(tileToMemMuxPipeLengths) > 0:
        bsvDefines += ' -D TILE_TO_MEM_MUX_PIPE_LENGTHS="vec(' + ', '.join(str(s) for s in tileToMemMuxPipeLengths) + ')"'


mainBsvCommand = f"bsc +RTS -K2G -RTS -steps-max-intervals 80000000 {bsvDefines} -D NUM_TILES_DEFINE={cfg['tiles']} -D NUM_DEVICES_DEFINE={cfg['devices']} -D NUM_CORES_PER_TILE_DEFINE={cfg['coresPerTile']} -D NUM_TASKS_PER_TILE_DEFINE={cfg['tasksPerTile']} -D AVG_OUT_EDGES_PER_TASK_DEFINE={cfg['avgOutEdgesPerTask']} -D MAX_OUT_EDGES_PER_TASK_DEFINE={cfg['maxOutEdgesPerTask']} -D AVG_ARGS_PER_TASK_DEFINE={cfg['avgArgsPerTask']} -D MAX_ARGS_PER_TASK_DEFINE={cfg['maxArgsPerTask']} -D L2_CACHE_SIZE_KB={cfg['l2CacheSizeKb']} -D L2_CACHE_BANKS={cfg['l2CacheBanks']} -D NUM_TILES_PER_SWITCH_PORT={cfg['tilesPerSwitchPort']} -D NUM_TILES_PER_MEM_CHANNEL={cfg['tilesPerMemChannel']} -D LOTUS_API_VERSION_DEFINE={apiVersion} {bscOptions} -verilog -g mkMultiTile -u MultiTile.bsv"
bscVerilogFiles = [os.path.join(buildDir, "hdl", "bsv", f"mk{mod}.v") for mod in bsvSynthModules]
bscCommand = env.Command(bscVerilogFiles, allBsvFiles, f"cd {os.path.join(buildDir, 'hdl/bsv')} && rm -f *.bo *.sched && {mainBsvCommand}")

# Postprocess each bsc-generated file
postprocessScript ="scripts/postprocess_bsc_verilog.py"
for srcFile in bscVerilogFiles:
    modName = os.path.basename(str(srcFile)).split("mk")[1].split(".")[0]
    extraFlags = "--keepHierarchy" if modName in bsvKeepHierarchyModules else ""
    extraFlags += " --blackBox" if modName in bsvBlackBoxModules else ""
    dstFile = os.path.join(buildDir, "hdl", os.path.basename(str(srcFile)))
    env.Command(dstFile, [srcFile, postprocessScript], f"python3 {postprocessScript} --removeReset {extraFlags} < $SOURCE > $TARGET")
    hdlFiles.append(dstFile)

# Check that bsc-generated files don't fall out of sync
def checkBscVerilogFiles(*args, **kwargs):
    actualVerilogFiles = [f for f in os.listdir(os.path.join(buildDir, "hdl", "bsv")) if f.startswith("mk") and f.endswith(".v")]
    expectedVerilogFiles = [os.path.basename(f) for f in bscVerilogFiles]
    if set(actualVerilogFiles) != set(expectedVerilogFiles):
        print("ERROR: Mismatched bsc-generated Verilog files")
        print("  Expected:", sorted(expectedVerilogFiles))
        print("  Actual:  ", sorted(actualVerilogFiles))
        for e in expectedVerilogFiles:
            if e not in actualVerilogFiles:
                print(f"Expected: {e} but not found in actual")
        for a in actualVerilogFiles:
            if a not in expectedVerilogFiles:
                print(f"Actual: {e} but not found in expected")
        print("  To fix this, if you updated the design, update bsvSynthModules in SConstruct file")
        env.Exit(-1)
    return ""
env.AddPostAction(bscCommand, checkBscVerilogFiles)

# Import all BSV files, postprocessing them just like the source
bsvLibBase = sp.check_output(["bash", "-c", 'echo $(dirname $(dirname $(which bsc)))/lib']).decode().split("\n")[0]
bsvLibFiles = ["FIFO1.v", "FIFO2.v", "FIFO10.v", "FIFO20.v", "FIFOL1.v", "SizedFIFO.v", "SizedFIFO0.v", "Counter.v", "RevertReg.v"]
def importBsvLibFile(fileName):
    vivadoFile = os.path.join(bsvLibBase, "Verilog.Vivado", fileName)
    genericFile = os.path.join(bsvLibBase, "Verilog", fileName)
    srcFile = vivadoFile if os.path.exists(vivadoFile) else genericFile
    dstFile = os.path.join(buildDir, "hdl", "bsvlib", fileName)
    env.Command(dstFile, [srcFile, postprocessScript], f"python3 {postprocessScript} --noRegReset < $SOURCE > $TARGET")
    return dstFile
hdlFiles += map(importBsvLibFile, bsvLibFiles)

# Independent ASIC preparation branch: consume raw BSC output, never the FPGA
# reset-removing postprocess results. SRAMs are opaque boundaries for logic-area
# synthesis; logical SRAM requirements and model mappings share one manifest.
asicPrepareScript = "scripts/asic/prepare.py"
asicSupportFiles = (Glob("scripts/asic/rtl/*.sv") +
    ["lotus/utils/" + name + ".sv" for name in
     ("CreditFIFO", "NonBlockingPipe", "ShiftRegister", "RegWithReset")] +
    ["lotus/xram/XRegFile.sv"])
asicManifest = os.path.join(buildDir, "asic", "manifest.json")
asicPrepare = env.Command(asicManifest,
    bscVerilogFiles + [asicPrepareScript, "scripts/asic/sram.py"] + asicSupportFiles +
    [os.path.join(bsvLibBase, "Verilog", f) for f in bsvLibFiles],
    f"python3 {asicPrepareScript} --build-dir {buildDir} "
    f"--out {os.path.join(buildDir, 'asic')} --bsc-lib {bsvLibBase}")
Alias("asic-tile", asicPrepare)
Precious(asicPrepare)  # prepare.py reads the previous manifest to preserve SRAM estimates.
AlwaysBuild(asicPrepare)  # inexpensive packaging; recreate any missing generated files

if asicOnly:
    Return()  # Do not construct unrelated simulator/host/FPGA build rules.


# Finally, clean up old files in hdl/ folder. Since this dir is globbed by
# downstream tools, old files (e.g., that were renamed or removed) need to be
# removed from here too!
hdlFileSet = set(os.path.basename(str(file)) for file in hdlFiles)
hdlDir = os.path.join(buildDir, "hdl")
if os.path.exists(hdlDir):
    for f in os.listdir(hdlDir):
        if f not in hdlFileSet and "bsv" not in f and not f.startswith("mk"):
            fp = os.path.join(hdlDir, f)
            print("Removing stray HDL file", fp)
            sp.check_call("rm " + fp, shell=True)

# Synthesis variants - to build FPGA images, we presynthesize some modules (for
# now, the core). This avoids synthesis instability and produces better results
# (e.g., the core somehow has 1420 LUTs when synthesized on its own or on up to
# 4c, but on 8c tiles, it grows to 1600 LUTs).
# NOTE: Used only in fastflow for now, but can be adopted by normal flow as well.
synthModules = ["mkCoreBsv"]
hdlSynthFiles = []
for file in hdlFiles:
    filename = os.path.basename(str(file))
    modName = filename.split(".")[0]
    dst = os.path.join(buildDir, "synth_hdl", filename)
    if modName in synthModules:
        env.Command(dst, hdlFiles, f"vivado -mode batch -source scripts/presynth.tcl -tclArgs {buildDir} {modName}")
    else:
        # Clear black_box annotations, we'll synth mkTile from here (but package hdlFiles)
        env.Substfile(dst, file, SUBST_DICT = {'(* black_box = "true" *)'  : ""})
    hdlSynthFiles.append(dst)

# Build tile DCP from synth sources
tileSynthDCP = os.path.join(buildDir, "fastflow", "synth.dcp")
tileSynthTopMod = "mkTilePair" if cfg["tilePairs"] else "mkTile"
env.Command(tileSynthDCP, hdlSynthFiles, f"vivado -mode batch -source scripts/fastflow_synth.tcl -tclArgs {buildDir} {tileSynthTopMod} {tileSynthDCP} {1000.0/cfg['frequency']:.2f}")

# Used for dependency management of Verilator-built projects, since we don't
# have visibility into Makefiles (using these in the right places ensures that,
# when these deps are externally rebuilt, scons catches the dep and recompiles
# the right things)
# NOTE: Sorting the Glob()s avoids occasional rebuilds due to the order of
# implicit deps changing; debugged with scons --dry-run --debug=explain; see
# https://scons-users.scons.narkive.com/AMlzla0M/dependency-order-changed-question
verilatorDeps = sorted(env.Glob("$VERILATOR_ROOT/bin/verilator_bin") + env.Glob("$VERILATOR_ROOT/include/*") + env.Glob("$VERILATOR_ROOT/verilator/include/*/*"))

# Build verilator host library (*once*; per-benchmark hosts will link it)
# Config must go first; omit vh files (included explicitly)
hostVlDir = os.path.join(buildDir, "host_obj_dir")
hostVlLib = os.path.join(hostVlDir, "Vxrt_top__ALL.a")
hostVlHdr = os.path.join(hostVlDir, "Vxrt_top.h")
vlFlags = "-O3 -j `nproc` --cc --timescale-override 1ps/1ps "
vlFlags += " -Wall -Wno-fatal -Wno-EOFNEWLINE -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-IMPORTSTAR"
vlFlags += " -I%s " % (os.path.join(buildDir, "hdl"))
vlFlags += " --Mdir " + hostVlDir
if GetOption("xunique"):
    vlFlags += " --x-assign unique --x-initial unique"
if GetOption("shh"):
    # Disable innocuous warnings common in bsc-generated code
    vlFlags += " -Wno-PINCONNECTEMPTY -Wno-UNUSED -Wno-BLKSEQ -Wno-STMTDLY -Wno-INITIALDLY -Wno-SYMRSVDWORD"
vlFlags += " --top-module xrt_top "
if trace:
    vlFlags += "  --trace"

# Verilator host needs an auto-generated include file for memory channel initialization
hostVlChannelInc = os.path.join(hostVlDir, "auto_create_mem_channels.cpp.inc")
channelScript = "host/vl_gen_channels.py"

genHostVlChannelInc = f"python3 {channelScript} {getNumMemChannels()} > {hostVlChannelInc}"

env.Command([hostVlLib, hostVlHdr],
        hdlFiles + verilatorDeps + [channelScript],
        "rm -rf %s/* && %s && $VERILATOR_ROOT/bin/verilator %s --build -o %s %s%s" % (hostVlDir, genHostVlChannelInc, vlFlags, os.path.abspath("$TARGET"), " ".join(os.path.abspath(f) for f in hdlFiles), " >/dev/null" if GetOption("shh") else ""))


# Lint target -- no output produced
env.Command("lint",
        hdlFiles + verilatorDeps,
        "verilator --lint-only %s %s" % (vlFlags, " ".join(os.path.abspath(f) for f in hdlFiles)))

def getTilePlaceCmds():
    if isFastflow: # tiles are already placed in DCPs
        return ""

    # Weighted round-robin placement; each SLR has weights based on the amount
    # of free resources for 32-tile configs (largest we can fit for now). Lower
    # weight means more tiles.
    weights = [0.99, 1.0, 0.83]
    loads = [0.0]*3
    nums = [0] * 3
    placeCmds = []
    # Now that we mux/demux multiple tile interfaces, place tiles in groups.
    # Each group goes to one SLR, so mux/demux logic needs little decoupling.
    def lcm(a, b):
        return (a*b) // math.gcd(a, b)
    tilesPerGroup = lcm(cfg["tilesPerSwitchPort"], cfg["tilesPerMemChannel"])
    s = 0
    for n in range(cfg["tiles"]):
        if n % tilesPerGroup == 0:
            s = loads.index(min(loads))
        loads[s] += weights[s]
        nums[s] += 1
        placeCmds.append(f'set_property USER_SLR_ASSIGNMENT SLR{s} [get_cells "level0_i/ulp/lotus_1/inst/lotus_inst/multiTile/tiles_{n}"]')
    return "\n".join([f"# Loads per SLR: {loads}", f"# Tiles per SLR: {nums}"] + placeCmds)

# Build hw_emu/hw kernels
withXrt = "XILINX_XRT" in env["ENV"]
if withXrt and not isBaseline:
    platformDict = {
        "u250" : "xilinx_u250_gen3x16_xdma_4_1_202210_1",
        "u55c" : "xilinx_u55c_gen3x16_xdma_3_202210_1"
    }
    platform = cfg["platform"]
    if platform not in platformDict.keys():
        print("ERROR: Invalid platform %s" % platform)

    vivado = os.popen("which vivado").read().strip()
    vpp = os.popen("which v++").read().strip()

    # In fastflow mode, first produce all tile DCPs (or reuse them)
    allDCPFiles = []
    postinitHookFile = os.path.join(buildDir, "config", "postinit_hook.tcl")
    if isFastflow:
        rapidwright = os.path.abspath(os.path.join(env["RAPIDWRIGHT"], "bin/rapidwright"))
        tileDir = os.path.join(buildDir, "tileDCPs")

        tileGenSrcFile = f"config/fastflow_tilegen_{cfg['tileGen']}.txt"
        tileGenTxt = open(tileGenSrcFile, 'r').read()
        tileGen = []

        def parseRanges(rangesStr):
            r = []
            for group in rangesStr.split(";"):
                if ":" in group:
                    r += range(*[int(x.strip()) for x in group.split(":")])
                else:
                    r += [int(group.strip())]
            return r

        for line in tileGenTxt.split("\n"):
            l = line.strip()
            if l.startswith("#") or "," not in l:
                continue
            comps = [c.strip() for c in l.split(",")]
            assert len(comps) == 5
            tileGen.append({
                "prefix" : comps[0],
                "yindex" : int(comps[1]),
                "stride" : int(comps[2]),
                "derivs" : parseRanges(comps[3]),
                "pblock" : (comps[4])
            })

        tileGenFile = os.path.join(tileDir, "tilegen.txt")
        pblocksFile = os.path.join(tileDir, "pblocks.txt")
        env.Textfile(tileGenFile, tileGenTxt)
        env.Textfile(pblocksFile, [t["pblock"] for t in tileGen])

        perfExplorerOutFile = os.path.join(tileDir, "perf_explorer.log")
        env.Command(perfExplorerOutFile, [pblocksFile, tileGenFile, tileSynthDCP, rapidwright], f"./scripts/fastflow_implement_tiles.py --dcp {os.path.abspath(tileSynthDCP)} --pblocks {pblocksFile} --options config/fastflow_impl_options.txt --workdir {tileDir} --max-parallel 80 | tee {perfExplorerOutFile}")

        baseDCPFiles = [os.path.join(tileDir, f"{t['prefix']}_{t['yindex']}.dcp") for t in tileGen]
        dcpScript = os.path.abspath("scripts/fastflow_pick_best_dcps.py")
        env.Command(baseDCPFiles, [perfExplorerOutFile, dcpScript], f"(cd {tileDir} && python3 {dcpScript} {tileDir} --produceBaseDCPs)")

        allDCPFiles = []
        for t in tileGen:
            # The first call to rapidwright on each base DCP launches a vivado job,
            # and making these concurrent causes errors. So have one of the reloc'd
            # tiles for each base be the "lead", and make all others for the same
            # base depend on the lead
            leadDCPFile = None
            for y in t["derivs"]:
                baseDCP = f"{t['prefix']}_{t['yindex']}.dcp"
                relocDCP = f"{t['prefix']}_{y}.dcp"
                [baseDCPFile, relocDCPFile] = [os.path.join(tileDir, f) for f in [baseDCP, relocDCP]]

                allDCPFiles.append(relocDCPFile)

                if y == t["yindex"]:
                    continue
                yoffset = (t["yindex"] - y) * t["stride"]

                deps = [baseDCPFile, rapidwright]
                if leadDCPFile == None:
                    leadDCPFile = relocDCPFile
                else:
                    deps.append(leadDCPFile)

                env.Command(relocDCPFile, deps, f"(cd {tileDir} && {rapidwright} RelocationTools {baseDCP} {relocDCP} 0 {yoffset})")

        reuseTilesBuildDir = GetOption("reuseTiles")
        if reuseTilesBuildDir is not None:
            print("Reusing tiles from build " + reuseTilesBuildDir)
            allDCPFiles = [os.path.join(reuseTilesBuildDir, "tileDCPs", os.path.basename(file)) for file in allDCPFiles]

        Alias("hw-tiles", allDCPFiles)

        dcpNameToFile = dict((os.path.basename(file).split(".dcp")[0], file) for file in allDCPFiles)

        def producePostInitHookFile(target, source, env):
            addFileCmds = []
            scopeCmds = []
            numDCPs = cfg["tiles"] // 2 if cfg["tilePairs"] else cfg["tiles"]
            tileMap = tileMapCfg.getTileMap()
            assert numDCPs <= len(tileMap)
            for (dcpIdx, dcpName) in list(enumerate(tileMap))[:numDCPs]:
                dcpFile = os.path.abspath(dcpNameToFile[dcpName])
                addFileCmds.append("add_files {" + dcpFile + "}")
                scopeCmds.append("set_property SCOPED_TO_CELLS {level0_i/ulp/lotus_1/inst/lotus_inst/multiTile/tilePairs_" + str(dcpIdx) + "} [get_files {" + dcpFile + "}]")

            finalCmds = []
            finalCmds.append("link_design -part xcu55c-fsvh2892-2L-e -reconfig_partitions level0_i/ulp")
            # NOTE: lock_design -level routing fails on routing; we do placement-level locking
            # TODO: Need to fix critical-path routes to prevent QoR degradation...
            finalCmds.append("lock_design -level placement")

            pif = open(postinitHookFile, "w") # == target, but target a list of a scons obj, so jeep this simple
            pif.write("\n".join(addFileCmds + scopeCmds + finalCmds) + "\n")
            pif.close()

        env.Command(postinitHookFile, allDCPFiles + [tileMapSrcFile], producePostInitHookFile)
    else:
        # not fastflow
        env.Command(postinitHookFile, [], "touch $TARGET")


    # Multi-device configs need aurora
    auroraIpDir = os.path.join(buildDir, "aurora_ip")
    # In practice, must be an U55C for now, we don't have multi-dev U250
    auroraPart = "xcu55c-fsvh2892-2L-e"
    if cfg["devices"] > 1:
        auroraIpScript = "scripts/gen_aurora_ip.tcl"
        env.Command(auroraIpDir, auroraIpScript, "mkdir -p %s; rm -rf %s/*; %s -mode batch -source %s -tclargs %s %s" %
                (auroraIpDir, auroraIpDir, vivado, auroraIpScript, auroraPart, auroraIpDir))

    for mode in ["hw_emu", "hw"]:
        vitisBuildDir = os.path.join(buildDir, "_x." + mode)
        xoFile = os.path.join(buildDir, "lotus.%s.xo" % mode)
        xclbinFile = os.path.join(buildDir, "lotus.%s.xclbin" % mode)

        # Generate config files
        kernelFile = os.path.join(buildDir, "config", "kernel.xml")
        kernelPortDefs = ['<port name="m%02d_axi" mode="master" range="0xFFFFFFFFFFFFFFFF" dataWidth="64" portType="addressable" base="0x0"/>' % t for t in range(getNumMemChannels())]
        kernelArgDefs = ['<arg name="m%02d_base" addressQualifier="1" id="%d" port="m%02d_axi" size="0x8" offset="0x%x" type="int*" hostOffset="0x0" hostSize="0x8"/>' % (t, t+1, t, 16+t*8) for t in range(getNumMemChannels())]
        if cfg["devices"] > 1:
            id = getNumMemChannels() + 1
            for prefix in ("rx", "tx"):
                for d in range(8): # multi-device builds always have 8 ports
                    name = f'{prefix}{d}_axis'
                    kernelPortDefs.append(f'<port name="{name}" mode="read_only" dataWidth="96" portType="stream"/>')
                    kernelArgDefs.append(f'<arg name="{name}" addressQualifier="4" id="{id}" port="{name}" size="0x8" offset="0x0" hostOffset="0x0" hostSize="0x8" type="void*"/>')
                    id = id + 1
        env.Substfile(kernelFile, "config/kernel.xml.in",
                SUBST_DICT = {"@@portDefs" : "\n      ".join(kernelPortDefs), "@@argDefs" : "\n      ".join(kernelArgDefs)})

        # In fastflow, this is a 16000-LUT pblock within CLOCKREGION_X1Y6:X1Y7
        # with some room around for the credit FIFO pipes to land
        tokenSwitchPblock = "{SLICE_X34Y370:SLICE_X53Y469 DSP48E2_X4Y142:DSP48E2_X6Y181 URAM288_X0Y100:URAM288_X0Y123}"

        preplaceHookFile = os.path.join(buildDir, "config", "preplace_hook.tcl")
        preplaceHookBaseFile = os.path.join("config", platform + (f'{cfg["devices"]}d' if cfg["devices"] > 1 else '') + "_preplace_hook.tcl.in")
        env.Substfile(preplaceHookFile, preplaceHookBaseFile,
                SUBST_DICT = {"@@placeCmds" : getTilePlaceCmds(), "@@tokenSwitchPblock" : tokenSwitchPblock})

        vitisCfgFile = os.path.join(buildDir, "config", "lotus.cfg")
        vitisBaseCfgFile = os.path.join("config", platform + (f'{cfg["devices"]}d' if cfg["devices"] > 1 else '') + ".cfg.in")
        memPorts = "HBM[0:7]" if platform == "u55c" else "DDR[0]"

        if isFastflow:
            # dsm: Place HBM ports as specified in tileMap
            hbmPorts = tileMapCfg.getHbmPorts(cfg["tilesPerMemChannel"])
            # dsm: vpl barfs non-deterministically if you try to constrain m00_base... so constrain all others
            # NOTE(dsm): vpl STILL fails non-deterministally for 8-device runs... rerunning a few times gets this to work.
            vitisConnects = ["sp=lotus_1.m%02d_base:%s" % (0, memPorts)] + ["sp=lotus_1.m%02d_base:%s.%d" % (t, memPorts, hbmPorts[t]) for t in range(1,getNumMemChannels())]
        else:
            vitisConnects = ["sp=lotus_1.m%02d_base:%s" % (t, memPorts) for t in range(getNumMemChannels())]

        env.Substfile(vitisCfgFile, vitisBaseCfgFile,
                SUBST_DICT = {
                    "@@memConnects" : "\n".join(vitisConnects),
                    "@@preplaceHook" : preplaceHookFile,
                    "@@postinitHook" : postinitHookFile
                    })
        env.Depends(vitisCfgFile, preplaceHookFile)
        env.Depends(vitisCfgFile, postinitHookFile)

        # Package XO kernels
        env.Command(xoFile, hdlFiles + [vivado, kernelFile] + Glob("scripts/*.tcl"),
                vivado + " -mode batch -source scripts/gen_xo.tcl -tclargs $TARGET lotus %s %s %s"
                    % (mode, platformDict[platform], kernelFile))
        xoInputs = [xoFile]

        reuseLotusXOBuildDir = GetOption("reuseLotusXO")
        if reuseLotusXOBuildDir is not None:
            xoInputs = [os.path.join(reuseLotusXOBuildDir, "lotus.%s.xo" % mode)]

        if cfg["devices"] > 1:
            auroraXoFile = os.path.join(buildDir, "aurora.%s.xo" % mode)
            auroraXoScript = "scripts/gen_aurora_xo.tcl"

            auroraTmpDirs = os.path.join(buildDir, "aurora_%s" % mode)
            auroraTmpDirs += " " + os.path.join(buildDir, "package_aurora_%s" % mode)
            env.Command(auroraXoFile, [auroraIpDir, auroraXoScript, "config/aurora.xdc", Glob("aurora/*")],
                    "rm -rf %s && %s -mode batch -source %s -tclargs $TARGET aurora %s %s"
                        % (auroraTmpDirs, vivado, auroraXoScript, "hw", auroraPart))

            reuseAuroraXOBuildDir = GetOption("reuseAuroraXO")
            if reuseAuroraXOBuildDir is not None:
                xoInputs.append(os.path.join(reuseAuroraXOBuildDir, "aurora.%s.xo" % mode))
            else:
                xoInputs.append(auroraXoFile)

        vppFlags = ""
        if mode == "hw_emu" and trace:
            vppFlags = "-g"
        env.Command(xclbinFile, xoInputs + [vpp, vitisCfgFile], vpp + " %s -O3 -t %s --platform %s --temp_dir %s --save-temps --config %s --kernel_frequency %d -lo $TARGET %s" % (vppFlags, mode, platformDict[platform], vitisBuildDir, vitisCfgFile, cfg["frequency"], " ".join(xoInputs)))
        # hw_emu needs a file telling it what device to assume, because it's not like we told vitis the device 20 times when building this :)
        if mode == "hw_emu":
            emconfigFile = os.path.join(buildDir, "emconfig.json")
            env.Command(emconfigFile, [], "emconfigutil --platform %s --od %s" % (platformDict[platform], buildDir))


# C++ flags for all host binaries, regardless of whether they're Verilator or XRT
hostPlatformFlags = ["-DPLATFORM_" + cfg["platform"], "-DLOG2_MAX_DEVICES=" + str((cfg["devices"]-1).bit_length()), f"-DNUM_MEM_CHANNELS={getNumMemChannels()}", f"-DLOTUS_API_VERSION={apiVersion}"]

# Benchmarks and host binary
SConscript(
    "benchmarks/SConscript",
    exports={
        "env": env,
        "buildDir": buildDir,
        "cfg": cfg,
        "isBaseline": isBaseline,
        "trace": trace,
        "hostPlatformFlags": hostPlatformFlags,
        "hostVlLib": hostVlLib,
        "hostVlDir": hostVlDir,
        "withXrt": withXrt,
    },
)

# Define target aliases, implicit deps, and defaults
# By default, build verilator host binaries, but not xrt targets (esp. hw, which takes forever...)
vl = Alias("vl", Glob(os.path.join(buildDir, "*.vl")))
Alias("hw_emu", Glob(os.path.join(buildDir, "*.hw_emu")) + Glob(os.path.join(buildDir, "*.hw_emu.*")) + Glob(os.path.join(buildDir, "emconfig.json")))
Alias("hw", Glob(os.path.join(buildDir, "*.hw")) + Glob(os.path.join(buildDir, "*.hw.*")))
# This targets builds ONLY the benchmarks. Useful for multi-device runs, where you use the xclbin for a different number of devices.
Alias("hw-bench", Glob(os.path.join(buildDir, "*.hw")))
# This target builds ONLY the FPGA image. Useful for long-running FPGA compiles, e.g., on other machines.
Alias("hw-xclbin", Glob(os.path.join(buildDir, "*.hw.xclbin")))

Default(vl)

# dsm: Instead of defining "xxxBench" aliases for every variant, just use the
# binary names, since the binary now builds all that's needed. For example, you
# can use "ntt256.hw" as a target.
for suffix in ["vl", "hw_emu", "hw", "baseline"]:
    for target in Glob(os.path.join(buildDir, "*." + suffix)):
        alias = os.path.basename(target.rstr())
        Alias(alias, target)
        # Declutter verilator options from alias names
        if "__" in alias:
            (prefix, rest) = alias.split("__")
            (vars, tail) = rest.split(".")
            simpleAlias = f"{prefix}.{tail}"
            Alias(simpleAlias, target)
