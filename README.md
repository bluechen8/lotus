# Lotus

## Overview

Lotus is a parallel architecture to accelerate RTL simulation. Lotus consists of a multicore system specialized to run small dataflow tasks, and a compiler that translates our C++ DSL to simulation binaries. The current implementation of Lotus targets FPGAs, and runs on one or multiple FPGAs. A paper describing Lotus is available at https://people.csail.mit.edu/sanchez/papers/2026.lotus.isca.pdf .

## Repository Structure

* `lotus`: All Bluespec/Minispec/Verilog files for Lotus hardware
* `aurora`: Verilog code that implements cross-FPGA communication for Lotus hardware
* `benchmarks : C++ DSL compiler and benchmarks that targets Lotus architecture
* `host`: Host code running on CPU that communicates with Lotus running on the FPGA (or simulated Lotus in Verilator)
* `config`: Templated Vitis configuration files
* `scripts`: Scripts using to build lotus, and to collect static and runtime results
* `misc`: Miscellanea, e.g., LLVM patch to add Lotus calling convention, sample Vagrantfile, etc.

## Setup

**Natively:** On a recent Linux distribution (e.g., Ubuntu 22.04 or 24.04), install the following external dependencies:

- The bluespec compiler (tested on 2024.01 an earlier): https://github.com/B-Lang-org/bsc/releases
- Vivado, Vitis, and XRT (tested on 2022.1-2023.2, and XRT versions 2.14 and 2.15). These are needed only if building FPGA images; they are not needed for simulation.
- System packages, e.g., with Ubuntu, `sudo apt install git build-essential python3 python3-pip scons cmake openjdk-17-jdk pkg-config uuid-dev device-tree-compiler libboost-dev libboost-regex-dev libboost-system-dev ninja-build lld autoconf automake autotools-dev curl python3-tomli libmpc-dev libmpfr-dev libgmp-dev gawk bison flex texinfo gperf libtool patchutils bc zlib1g-dev libexpat-dev libglib2.0-dev libslirp-dev libncurses-dev python3-networkx python3-pydot python3-sortedcontainers`

Then, run `scons`.

Lotus has several other dependencies (e.g., a RISC-V toolchain, spike, verilator, etc.). On first run, `scons` will automatically download and build these dependencies, under `ext/`. You can optionally point `scons` to already-installed dependencies.


**On a virtual machine:** We provide automated VM configuration with Vagrant. Install Vagrant (e.g., `sudo apt install vagrant`), then copy the sample Vagrantfile:

```bash
$ cp misc/Vagrantfile.sample Vagrantfile
```

Customize the memory and cpu settings of the Vagrantfile in the
`config.vm.provider` block that is relevant to you. We recommend using at least
16 cores and 32GB of memory, and 64GB if building FPGA images.

Then, run:
```bash
$ vagrant up
$ vagrant ssh
vagrant@sim:$ cd lotus
```

## Build and run

We use a scons-based build system that produces all artifacts, including FPGA images and simulation binaries.

There are three flows:

1. hw: Execution on the FPGA
2. vl: Simulation using Verilator.
3. hw_emu: Simulation using Vivado/Vitis HW emulation

The vl/hw/hw_emu targets build all benchmarks and FPGA image, e.g., scons -j16 hw

Since building the FPGA image is time-consuming, the hw-bench and hw-xclbin targets build the benchmarks and FPGA image only.

You can also build a specific benchmark binary, e.g., scons -j16 ntt64.hw

The build system takes **configuration parameters** that control the configuration of both Lotus and the benchmarks. There are a number of preset configurations; for example, "serial" is a 1-core 1-tile configuration, and "base" is a configuration meant to reasonably fill one FPGA. The --cfg flag controls this preset configuration. Additional flags control the value of each parameter. For example:

scons --platform=u55c hw-xclbin --devices=8 --tiles=32 --coresPerTile=8 --tasksPerTile=2048 --frequency=225

Builds an FPGA image targeting the U55C FPGA, with an 8-FPGA configuration (i.e., with the inter-FPGA aurora communication shim), 32 tiles per FPGA, 8 cores per tile, 2048 tasks per tile, and a target frequency of 225MHz.

Build artifacts are created under build/, in a subfolder whose name is determined by the configuration specified. For example, the above command will produce build/serial8d32t8c2048eu55c225MHz/lotus.hw.xclbin


All Lotus flows first compile each benchmark (using the Lotus DSL or verilator compiler) targeting a specific Lotus configuration (e.g., a given number of tiles and devices). This produces RISC-V code that will run on Lotus. The flows differ from then on:

1. hw: Each benchmark target produces a binary that initializes and controls the FPGA(s), loading the Lotus code and task configuration, and starts execution on the FPGAs.

For example, scons -j16 --tiles=2 ntt64.hw produces the binary build/serial2t/ntt64__1u_nc.hw. Assuming an xclbin exists under serial2t, you can then run the simulation using:

./build/serial2t/ntt64__1u_nc.hw ./build/serial2t/lotus.hw.xclbin 01:00.1

where 01:00.1 is the ID of the FPGA.

Note that the hw binary is **self-contained** (except for the xclbin): it includes the Lotus code for the NTT benchmark, as well as the task configuration. You can move/copy these binaries around.

2. vl: Each benchmark target produces a binary that simulates Lotus running the benchmark. To do this, Lotus itself is compiled using Verilator.

For example, scons -j16 --tiles=2 ntt64.vl produces the binary build/serial2t/ntt64__1u_nc.vl. Unlike hw, there is no xclbin generation here, everything is produced in one command and bundled in one binary. Run with:

./build/serial2t/ntt64__1u_nc.vl

Note you can control the configuration of both the platform and benchmark. For example:

scons --devices=1  --tiles=16 --coresPerTile=1 --tasksPerTile=2048 --l2CacheSizeKb=512 --nttSize=512 ntt512.vl

produces build/serial1d16t1c2048e512KBl2/ntt512__1u_nc.vl

3. hw_emu: This flow is similar to vl, but substantially slower. We've used it in the past to catch some synthesis bugs that don't show up in Verilator (mainly around undefined values). This also exercises XRT host code. However, expect to use this sparingly.


#### Understanding benchmark names
General structure is `<benchmark>__<unrollFactor>u__(n|y)c.(vl|hw|hw_emu)`. The temporal unrolling factor and coarsening are controlled with the --unrollFactor and --enableCoarsening build flags.

We provide four Lotus DSL benchmarks: ntt, systolic, cores, and coresWithCaches. See the Lotus paper for benchamrk details and descriptions. ntt and systolic have Retimed and Virtualized variants that manually perform temporal unrolling and coarsening (used to compare with the compiler-produced versions).

#### Single- and multi-FPGA builds

Single-FPGA builds should be easily portable to any Alveo-based platform: we've tested U55C and U250, and other FPGAs should require small changes, e.g., adding a new platform (see SConstruct and config/)

However, multi-FPGA runs are completely tied to the testbed we have at MIT: 8 Alveo U55C FPGAs, spread across 2 machines (stg3 and stg4), and connected in an all-to-all fashion. The Aurora shim, routing tables, etc. are all tied to this testbed. Adapting this to run on other multi-FPGA environments is possible, but expect more elbow grease.


## Running experiments with experiments.py

As described above, running something on Lotus has two components:
1. Specifying the design to be simulated
2. Specifying the Lotus config that'll simulate the design

To ease usage, `scripts/experiments.py` automates much of this process: it generates benchmark binaries, Lotus config binaries, runs them together, and then collects the results. An example experiment can look like this, defined in `scripts/resultsCommon.py`:

```
def demoExperiment(exps):
    # target specifies whether
    # - vl => Lotus will run on Verilator to simulate benchmark
    # - hw => Lotus will run on real FPGA to simulate benchmark
    for target in ["vl", "hw"]:
        lotusConfig = Build({
            "devices"      : 1, # Number of FPGAs
            "tiles"        : 16, # Number of tiles per FPGA
            "coresPerTile" : 1,
            "tasksPerTile" : 2048,
            "l2CacheSizeKb": 512, # Per Tile
        })

        benchmarks = []
        benchmarks.append(Benchmark.from_str(f"ntt128__1u_nc.{target}"))

        configsToRun = [Configuration(lotusConfig, bench) for bench in benchmarks]

        # genericCallback gets called after every simulation finishes to collect results
        exps.append(Experiment(f"demo-exp-{target}", configsToRun, genericCallback))

def getAllExperiments():
    exps = []
    demoExperiment(exps)
```

To see all experiments registered you can run:
```
python ./scripts/experiments.py --describe
```

Running the `demo-exp-vl` that we defined earlier can be done like this:
```
$ python ./scripts/experiments.py --experiments demo-exp-vl --buildName demoExperiment
```

## License

Lotus is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.

Additionally, if you use this software in your research, we request that you reference the Lotus ISCA 2026 paper ("Lotus: A Multi-FPGA Task Dataflow Architecture for Cycle-Level Simulation", Elsabbagh et al.) as the source of this software in any publications that use it.

