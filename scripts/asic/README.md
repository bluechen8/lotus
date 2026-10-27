# Lotus ASIC area estimation

This folder prepares one `mkTile` for standard-cell synthesis and separately
estimates its SRAM area. It is an area-evaluation flow, not a physical-design
or functional-simulation flow.

| Document | Read it for |
|---|---|
| **README.md** | Environment setup, patched Hammer installation, commands and outputs |
| **[FLOW.md](FLOW.md)** | What each file does, what we add beyond upstream tools, and which implementation choices need review |
| **[FNCACTI.md](FNCACTI.md)** | Logical-RAM-to-macro mapping, model parameters, area accounting and accuracy limits |
| **[One tile, 4096 tasks: area results](lotus_1tile_4096tasks/README.md)** | Validated 1 ns Genus logic results plus an uncalibrated FN-CACTI SRAM estimate, macro mapping and native reports |

## Set up Hammer and the tool environment

The Yosys instructions below describe the original `lotus` environment. For
the current Berkeley host and Genus, use [the Genus setup](#genus-on-the-berkeley-host).
The installation commands are for a new environment/checkout.
Run these examples from the Lotus repository root.

### 1. Install the Python package and CLI

```bash
# Only if the lotus environment does not already exist:
conda create -n lotus python=3.12 pip

conda activate lotus
python -m pip install 'hammer-vlsi==1.2.0' scons
```

The package supplies Hammer's CLI and Python dependencies. The synthesis flow
uses explicit library paths with `hammer.technology.nop`, so the GDS-processing
extras used by the full ASAP7 physical-design plugin are not required.

### 2. Pin and patch the upstream checkout

```bash
LOTUS_REPO="$PWD"
mkdir -p "$HOME/tools"
git clone https://github.com/ucb-bar/hammer.git "$HOME/tools/hammer"
git -C "$HOME/tools/hammer" switch -c lotus-asap7 1.2.0
git -C "$HOME/tools/hammer" apply --check "$LOTUS_REPO/scripts/asic/hammer-yosys.patch"
git -C "$HOME/tools/hammer" apply "$LOTUS_REPO/scripts/asic/hammer-yosys.patch"
conda env config vars set -n lotus PYTHONPATH="$HOME/tools/hammer"
conda deactivate
conda activate lotus
```

The pinned base is Hammer **1.2.0**, commit
`7dfbb0b581048dc61523d35aebda924a78eb0428`. Do not apply this patch to an
arbitrary newer checkout. For an already configured checkout, skip clone,
branch creation and patch application; verify it instead:

```bash
git -C "$HOME/tools/hammer" rev-parse HEAD
git -C "$HOME/tools/hammer" apply --reverse --check "$PWD/scripts/asic/hammer-yosys.patch"
python -c 'import hammer.synthesis.yosys as y; print(y.__file__); assert hasattr(y.YosysSynth, "liberty_args")'
hammer-vlsi --help
```

The Python path must be under `$HOME/tools/hammer`. Conda selects that checkout
for both the CLI and Python scripts; the installed package remains unchanged.
The modifications are visible with `git -C "$HOME/tools/hammer" diff`.

[hammer-yosys.patch](hammer-yosys.patch) makes the existing backend pass all
selected libraries to `dfflibmap`, ABC and `stat`, use normal flip-flop
legalization, and fail structural checks. It also handles an absent latch map,
selects one explicit corner, and orders libraries deterministically. There is
no Lotus Yosys plugin or Python tool hook. See [the patch review](FLOW.md#hammer-backend-patch).

### 3. Check the non-Python dependencies

| Dependency | Validated host location / requirement |
|---|---|
| Yosys **0.62**, including its ABC executable | `$HOME/yosys-062/yosys`; repeated `-liberty` support is required |
| Bluespec **2024.01** | `$HOME/tools/bsc-2024.01-ubuntu-24.04/bin/bsc`, with generic libraries in the sibling `lib/Verilog/` |
| Minispec | SCons builds `ext/minispec` if no `MINISPEC` path is supplied |
| ASAP7 **v28 RVT TT** standard cells | `$HOME/asap7_pdk/asap7sc7p5t_28`, clean upstream checkout; validated commit `e5bd25da72cd297b8c0ec6f77600e0cbaa1124d0` |
| Native libarchive | `libarchive.so.13`, used only to unpack the upstream `.lib.7z` files |
| FN-CACTI, for SRAM estimation | `ext/fncacti/work/pcacti_xml/cacti` and `configs/2MB_fin.cfg`; [model setup/provenance](FNCACTI.md#tool-provenance) |

For a new standard-cell installation:

```bash
mkdir -p "$HOME/asap7_pdk"
git clone https://github.com/The-OpenROAD-Project/asap7sc7p5t_28.git "$HOME/asap7_pdk/asap7sc7p5t_28"
git -C "$HOME/asap7_pdk/asap7sc7p5t_28" checkout e5bd25da72cd297b8c0ec6f77600e0cbaa1124d0
```

The synthesis scripts use these host paths as defaults. Override `--yosys`,
`--pdk-root` (the parent of `asap7sc7p5t_28`) or `--bsc-lib` for other installs.
FN-CACTI accepts `--binary` and `--template`. The optional SRAM comparison also
requires `$HOME/asap7_pdk/asap7_sram_0p0`; override it with `--sram-root`.

### Genus on the Berkeley host

Environment inspected on 2026-10-27:

| Dependency | Location / result |
|---|---|
| Python / Hammer 1.2.0 | `/scratch/boru/miniforge3/bin/python`; installed `hammer.synthesis.genus` backend |
| Genus 25.11-s095_1 | `/ecad/tools/cadence/DDI/DDI251/GENUS251/bin/genus`; license checkout verified |
| Cadence license | `5280@license-srv.eecs.berkeley.edu`, from the existing Chipyard `vlsi/env.yml` |
| ASAP7 v28 RVT TT | `ext/asap7/asap7sc7p5t_28`, commit `e5bd25da72cd297b8c0ec6f77600e0cbaa1124d0` |
| Bluespec 2024.01 | `ext/bsc-2024.01-rockylinux-9.3/{bin,lib}` |
| Minispec / SCons | `ext/minispec/msc`; workspace-local SCons in `ext/python` |

Genus needs Hammer 1.2.0, a Cadence license and `sha256sum` (GNU coreutils),
but not Yosys or `hammer-yosys.patch`. The `ext/` dependencies below are ignored
build inputs; pass their paths explicitly because the original
`/home/ubuntu/...` defaults do not exist on this host.

To reproduce this local dependency setup, download and extract the
[Bluespec Rocky Linux 9.3 release](https://github.com/B-Lang-org/bsc/releases/tag/2024.01)
under `ext/`, clone the standard-cell repository above into
`ext/asap7/asap7sc7p5t_28`, and clone
`https://github.com/minispec-hdl/minispec` into `ext/minispec`.
Install SCons with `python -m pip install --target ext/python scons`.
On this host, Minispec's optional `-static` link flags need to be replaced by
`-pthread` in its local `SConstruct` because static system libraries are absent.
Build with `PYTHONPATH="$PWD/ext/python" python ext/python/bin/scons -C ext/minispec -j8`.

From the repository root:

```bash
export PATH="$PWD/ext/bsc-2024.01-rockylinux-9.3/bin:$PATH"
PYTHONPATH="$PWD/ext/python" python ext/python/bin/scons \
  --cfg=fast --tiles=64 --tasksPerTile=4096 \
  MINISPEC="$PWD/ext/minispec" asic-tile

export CDS_LIC_FILE=5280@license-srv.eecs.berkeley.edu
python scripts/asic/hammer_syn.py --tool genus \
  --build-dir build/fast64t4096e --out build/hammer-genus-1ns \
  --pdk-root ext/asap7 --bsc-lib ext/bsc-2024.01-rockylinux-9.3/lib \
  --genus /ecad/tools/cadence/DDI/DDI251/GENUS251/bin/genus \
  --genus-version 251 --clock-period-ns 1 --max-threads 8
```

The flow follows the Hammer driver/hook structure of the
[Chipyard ASAP7 tutorial](https://chipyard.readthedocs.io/en/latest/vlsi/asap7-tutorial/),
using the existing v28 Liberty files for logic-only synthesis. Setup and hold
both use RVT TT; automatic clock gating is disabled. See
[Genus hooks](FLOW.md#genus-hooks) for the initialization and validation details.

`--prepare-only` writes the inputs and `run_hammer.sh`; `--report-only` validates
existing outputs for either backend. `--cds-lic-file` overrides `CDS_LIC_FILE`.
The backends have separate default output directories. Genus timing reports
are under `obj/syn-rundir/reports/`. Report validation checks input fingerprints
and hashes of the exported netlist, cell inventory and timing report; older
Genus runs without these hashes require synthesis to be rerun. SRAM area is
excluded. SRAM timing arcs, I/O budgets and routed parasitics are absent, so
the reports do not establish full-tile timing closure.

The full `fast64t4096e` validation on 2026-10-27 completed with **197,099
standard cells and 28,362.9114 µm² logic area**, retaining all **25 logical
SRAMs** (8 XRAM2BE, 16 XRAM2, 1 XRAM1). The native report's worst setup path
had +11 ps slack at 1 ns, subject to the timing limitations above. Results are
in `build/hammer-genus-1ns/hammer_summary.json`; the mapped netlist, SDC, SDF
and native reports are under its `obj/syn-rundir/` directory.

## Run the flow

### 1. Elaborate and prepare the tile

```bash
conda activate lotus
export PATH="$HOME/tools/bsc-2024.01-ubuntu-24.04/bin:$PATH"
scons --cfg=fast --tiles=64 --tasksPerTile=4096 asic-tile
```

This produces raw BSC Verilog in `build/fast64t4096e/hdl/bsv/` and a prepared
package in `build/fast64t4096e/asic/`. It does **not** run Hammer or FN-CACTI.
When `asic-tile` is the only target, bootstrap skips Spike, RISC-V/LLVM software
toolchains, Verilator and FPGA tools, and does not save `.path_vars.py`.
The reports below are for one tile, not the entire 64-tile system.

### 2. Synthesize standard-cell logic

```bash
python scripts/asic/hammer_syn.py \
  --build-dir build/fast64t4096e \
  --out build/hammer-native-1ns \
  --clock-period-ns 1
```

`hammer_syn.py` prepares that output directory, writes YAML, invokes the normal
`hammer-vlsi ... syn` CLI, and validates the mapped result. The five Liberty
files stay separate. Yosys reads SystemVerilog directly; `synthesis_input.v`
only defines synthesis macros and includes the ordered sources. Hammer's
upstream latch map is referenced directly; no `sv2v`, generated sequential map,
or merged Liberty file is needed.

Support modules come from the original Lotus RTL. The synthesis entry defines
`BSV_NO_INITIAL_BLOCKS` to exclude FPGA power-up initialization and `SYNTHESIS`
to exclude simulation diagnostics. Original functional resets and write gating
remain; no replacement `support.sv` or extra reset circuitry is generated.
Additional ASIC startup circuitry is outside this area estimate. FPGA builds
retain initialization unless they explicitly set `BSV_NO_INITIAL_BLOCKS`.

Use `--prepare-only` to inspect the generated inputs before running
`bash build/hammer-native-1ns/run_hammer.sh` in the same environment.
Use `--report-only --out build/hammer-native-1ns` to recheck an existing result;
changed source, library, constraint or backend fingerprints require synthesis
to be rerun.

### 3. Map and estimate SRAMs

```bash
python scripts/asic/fncacti.py \
  --manifest build/hammer-native-1ns/manifest.json \
  --policy scripts/asic/fncacti_policy.json
```

This selects analytical macro geometries/counts, invokes FN-CACTI once per
unique shape/port combination, and updates the same manifest. It does not
insert macros into the synthesized netlist. `--prepare-only` records mappings
and configs without executing the model (the binary must still exist for
hashing). Later runs can omit `--policy` to reuse the recorded policy.

For the optional comparison against shipped ASAP7 single-port macro footprints:

```bash
python scripts/asic/fncacti_compare.py
```

### ExTensor LLB SRAM

The standalone [ExTensor LLB configuration](extensor_llb/config.json) specifies
four independent banks, each 15,360 words x 4096 bits with two RW ports, for
30 MiB total. It follows the intended `shared_SRAM` bank geometry, using exactly
four instances rather than the upstream inclusive `[0..nbanks]` range. Writes
cover the whole word; no independent byte masks are assumed.

Run from the repository root (no TeAAL checkout, Accelergy installation, RTL
elaboration or Hammer run is required):

```bash
python scripts/asic/extensor_llb/evaluate.py
# Force fresh executions instead of validated cache reuse:
python scripts/asic/extensor_llb/evaluate.py --fresh
```

The driver imports the existing `sram.allocate()` and `fncacti.execute_model()`;
it does not duplicate the allocator or physical model. All defaults resolve
relative to the driver/repository, so invocation also works from another cwd.
`--config`, `--policy`, `--binary`, `--template`, `--out` and `--timeout`
allow explicit overrides. Reports default to
`scripts/asic/extensor_llb/`; `--out` redirects both reports and model runs.

| Model | Allocation | Total SRAM area |
|---|---|---:|
| `four_banks_mapped_2rw` | 32 slices per bank, each 16,384x128 2RW; 128 macros, 32 MiB allocated | 17.363584 mm2 |

The mapped estimate includes 2 MiB of depth padding. Selection uses the existing
candidate-grid capacity-waste/instance-count metric; FN-CACTI then minimizes
area within each selected macro. One invocation models one UCA bank, and the
driver multiplies its area by physical instance count exactly once.

Review [result.json](extensor_llb/result.json),
[result.csv](extensor_llb/result.csv) and
`extensor_llb/fncacti/four_banks_mapped_2rw/<signature>/{input.cfg,stdout.log,stderr.log,run.json}`.
The JSON records the configuration, source hashes, allocation and execution
provenance. Only the selected mapped model is maintained in this folder.

These are uncalibrated 14 nm FinFET / 7 nm ASAP7-wire macro footprints at 0.7 V,
300 K. Crossbars, controllers, external routing and timing closure are excluded.
The mapped macro's access/cycle times are 0.930081/0.798595 ns.
The run does not enforce the upstream latency attribute.

## Outputs and interpretation

Paths below are relative to the selected output directory unless stated otherwise.

| Output | Purpose |
|---|---|
| `manifest.json` | Source hashes, synthesis inputs, logical SRAM inventory, selected macro mappings and model results |
| `rtl/`, `synthesis_input.v` | Prepared design and include entry file |
| `design.yml`, `run_hammer.sh` | Reviewable Hammer configuration and CLI invocation |
| `derived_libraries/`, `pdk_provenance.json` | Unmodified extracted libraries, area-unit checks, PDK and synthesis/backend fingerprints |
| `obj/syn-rundir/syn.tcl` | Actual Yosys or Genus commands generated by Hammer |
| `obj/syn-rundir/mkTile.mapped.v` | Standard-cell netlist with logical SRAM blackboxes |
| `hammer_summary.json` | Validated logic area and SRAM counts for the selected backend |
| `mapped_stats.json`, `validate.log` | Yosys area and structural checks |
| `obj/syn-rundir/lotus_cells.tsv`, `obj/syn-rundir/lotus_artifacts.sha256` | Genus cell/logic-abstract inventory and output hashes |
| `obj/syn-rundir/reports/lotus_timing.rpt` | Genus timing report |
| `fncacti/<macro-id>/<signature>/` | Model config, invocation, logs and result hashes |
| Repository `build/fncacti/asap7-comparison/` | Optional comparison JSON/CSV and model runs |

`XRAM1`, `XRAM2` and `XRAM2BE` are excluded from logic area. `XRegFile`, ordinary
registers and FIFOs are included. SRAM macro adapters and physical implementation
overhead are not generated or counted. The clock target guides ABC mapping;
these reports do not establish full-chip STA or SRAM timing closure.

FN-CACTI uses uncalibrated **14 nm FinFET devices with 7 nm ASAP7 wires**. Its
SRAM estimate stays separate from ASAP7 standard-cell area. A newly synthesized
manifest has no SRAM estimate until step 3 runs. Check the status in each
manifest rather than assuming that a historical result applies to a new build.

## Validate changes

```bash
python -m unittest discover -s scripts/asic/tests -p 'test_*.py' -v

# Also exercise the real Hammer CLI with the prepared libraries:
LOTUS_HAMMER_TEST_CONFIG="$PWD/build/hammer-native-1ns/design.yml" \
  python -m unittest discover -s scripts/asic/tests -p 'test_*.py' -v

# Licensed Genus integration, independent of Yosys:
LOTUS_GENUS_TEST_CONFIG="$PWD/build/hammer-genus-1ns/design.yml" \
  python -m unittest discover -s scripts/asic/tests -p 'test_genus_backend.py' -v
```

The Yosys integration test synthesizes a small design and proves its mapped
reset/enable priorities and both clock polarities equivalent to its RTL. It
does not prove whole-tile equivalence or ASIC startup correctness. Separate RTL
checks verify initialization is preserved by default and disabled when requested,
functional reset priority, and register-file write gating without reset clearing.
The other tests cover extraction, source freshness, SRAM allocation, model
input/output handling, area reporting and failed-result rejection.
The Genus integration test maps both clock polarities and checks all three
XRAM interfaces, parameterized variants, unused-memory retention, native area
units and clock conversion. It is not a functional equivalence proof.
