# SRAM mapping assumptions and FN-CACTI estimation

This document defines the model and its limits. [README.md](README.md) contains
run commands; [FLOW.md](FLOW.md) describes the script/data flow. The authoritative
per-run requirements, mappings and results are in `manifest.json`.

## What is extracted, and what is assumed

`prepare.py` traverses raw BSC Verilog from `mkTile`. Each XRAM declaration gets
one `memory_inventory` record with `logical`, `mapping` and `estimation` sections.
`XRegFile` is standard-cell logic, not part of this SRAM inventory.

Logical depth, width, read latency, port modes, masks and hierarchy multiplicity
come from Verilog. Source references are recorded by `sram.logical_memory()`.
The BSV/Minispec references explain the declaration; their hashes do not prove
that a separate build directory was compiled from that exact checkout.

Port modes are defined in [XRAM.bsv](../../lotus/xram/XRAM.bsv):

| Mode | Role used in the model |
|---|---|
| 0 NO_CHANGE, 1 WRITE_FIRST, 2 READ_FIRST | RW |
| 3 WRITE_ONLY | W |
| 4 READ_ONLY | R |

Port B is `2**LOG_RATIOB` wider and correspondingly shallower than A. Capacity
is `NUM_WORDS * DATA_WIDTH`, counted once, not once per port. `CHUNK_SIZE` is the
independently writable width, not a bank count. Declared port capability is
preserved even if some outputs are unused in the current design.

The current policy is [fncacti_policy.json](fncacti_policy.json). It replaces
the former power-of-two-byte allocation with a **MacroCompiler-style candidate
search and DefaultMetric**. This is a Python implementation of that algorithm
for this area flow; it does not invoke Chipyard's Scala/FIRRTL compiler or emit
macro wrappers.

References checked on 2026-10-25:
[MacroCompiler.scala](https://github.com/ucb-bar/barstools/blob/master/src/main/scala/barstools/macros/MacroCompiler.scala)
(`calculateBitPairs`, `compile`, candidate selection) and
[CostMetric.scala](https://github.com/ucb-bar/barstools/blob/master/src/main/scala/barstools/macros/CostMetric.scala)
(`DefaultMetric`). The upstream algorithm repeats one chosen library macro in
width and depth and ranks candidates by capacity waste and instance count.
Mixing heterogeneous macro types within one logical RAM is not part of this search.

## Candidate library, assumptions and limits

| Assumption | Current behavior and consequence |
|---|---|
| Candidate library | Analytical unmasked macros, not a foundry catalog: widths **8 through 128 bits in steps of 8**, depths **2 through 32,768 words in powers of two**, with each logical RAM's exact port roles. Both lists are explicit in the policy. |
| Minimum size | Reject candidate geometries smaller than **64 bytes**. At least two words and one byte per word. |
| Width | No power-of-two width restriction. For example, 69 useful bits may use a 72-bit word; 18 useful bits may use 24. Non-byte widths are excluded because this flow supplies whole-byte blocks to FN-CACTI. |
| Depth | Search every listed depth, including depth banking and depth padding. No aspect-ratio or timing filter. The present tile happens to select no additional depth banks. |
| Logical boundaries | Model each declared array independently. No merging, sharing, time multiplexing or replication to emulate extra ports. |
| Masks/asymmetry | First split at port-word and independent-write boundaries, then slice each resulting region to the candidate width. Partial final slices are allowed. This is Lotus-specific normalization before the MacroCompiler-style search. |
| Native masks | Candidates have no native bit/byte write masks. Independent writes use separate macros and duplicate periphery. Masks are not approximated as free native support. |
| Repeated geometry | One macro geometry per logical declaration, repeated across width and depth. Different slices can use different numbers of useful bits in that same geometry. No heterogeneous 64+8 mapping. |
| Instance counts | Multiply by hierarchy multiplicity within one tile exactly once. Architectural banks are already in the inventory. |
| Selection objective | Minimize **wasted fraction + 0.05 per instantiated macro**. This is not FN-CACTI area minimization over candidates. |
| FN-CACTI objective | After selection, independently search each chosen macro's internal organization for minimum modeled area under the configured deviation bounds. Policy `objective` refers to this internal model objective. |
| UCA banks | Exactly one per macro invocation. FN-CACTI's internal mats/subarrays are not extra logical instances. |
| Timing | No 1 ns SRAM constraint. RTL read latency and read-first/write-first semantics are recorded, not implemented by a port count. |
| Tags and ECC | Every array is RAM, with no automatic tags or ECC. Lotus tag/status arrays already exist as separate declarations. |
| Technology | Uncalibrated 14 nm FinFET devices, 7 nm ASAP7 wires, 0.7 V, 300 K, no negative-capacitance mode. Preserve the template's low-swing wires and aggressive interconnect projection. |
| External logic | Bank/lane selection, output muxes, bypass, latency and initialization logic are not generated or included in macro area. |

The old power-of-two-byte rule was conservative, not a required SRAM property.
The installed parser accepts byte-aligned widths such as 24 and 72 bits, and
those selected configurations have now been run successfully. Success checks
configuration echoes, finite results and footprint consistency; it does not
prove physical compiler availability or multiport model accuracy.

The grid limits are local design-space assumptions, not values taken from a
published SRAM compiler catalog. Whole-byte widths match this flow's FN-CACTI
block-size interface; the 128-bit maximum and power-of-two depths up to 32,768
words bound the search. The shipped ASAP7 catalog is used for a separate sanity
comparison, not to define this analytical candidate library.

This is a bounded analytical library. A candidate passing dimensional checks
has not necessarily been characterized: only selected candidates are run through
FN-CACTI. If a selected model fails, estimation fails without silently selecting
another mapping. Candidate lists can be edited to constrain the design space.

## Allocation algorithm and metric

In `sram.allocate()`, compute:

```text
boundary_bits = GCD(all port widths, all writable-port granularities)
row_depth     = logical_capacity_bits / widest_port_bits

For each candidate width W and depth D:
  slices = (widest_port_bits / boundary_bits) * ceil(boundary_bits / W)
  banks = ceil(row_depth / D)
  count = slices * banks
  allocated_bits = count * D * W
  cost = (allocated_bits - logical_capacity_bits) / logical_capacity_bits
         + 0.05 * count
```

Select the lowest-cost candidate. Ties are resolved by instance count,
allocated bits, width, then depth, so policy list ordering does not change the
result. `mapping.selection` records cost, its components, candidate count and
tie-breaking; `sram_model.policy` records the entire candidate grid.

The formula is upstream `DefaultMetric` for unmasked candidate macros; its
0.001 penalty for an unmasked target using a masked library macro is zero here.
Our GCD normalization extends the selection to Lotus's asymmetric ports and
multiple independent write boundaries. This is not a port of all upstream
masked-library compatibility cases. Compatible port roles are preserved rather
than searched or converted. The cost counts macros for **one logical instance**;
hierarchy multiplicity is applied afterwards to accounting.

For a 4096x69 unmasked RAM, one 4096x72 macro costs `3/69 + 0.05`, while nine
4096x8 macros cost `3/69 + 0.45`. A single 4096x128 macro costs `59/69 + 0.05`.
The 72-bit candidate wins. Even when padding decreases, the metric does not
guarantee the lowest physical area because it does not price macro periphery.

The manifest lists inclusive `(lsb, msb)` ranges in `mapping.bit_slices` within
a widest-port word. Each range uses low-order bits of one macro word. This
represents partial final slices explicitly; there is no misleading single
"useful bits per word" value when slices differ.

For a port access:

```text
lane_groups = widest_port_bits / this_port_bits
group = address % lane_groups
row = address // lane_groups
wide_word_bit = group * this_port_bits + bit_in_port_word
slice = entry of bit_slices containing wide_word_bit
macro_bit = wide_word_bit - slice.lsb
depth_bank = row // macro_depth
macro_address = row % macro_depth
```

Examples from `fast64t4096e`, per logical instance:

| Logical RAM | Selected allocation |
|---|---|
| L2 data: 8192x64, 2RW, byte writes | Eight 8192x8 2RW macros; no padding. |
| I-cache: 1024x32 R / 512x64 W | Two 512x32 1R1W macros; A selects one slice, B writes both. |
| L2 tags: 1024x18 W / 256x72 R | Four 256x24 1R1W macros, each using 18 bits per word. |
| Task information: 4096x69, 1RW | One 4096x72 macro; three unused bits per word. |
| Edge table: 16384x72, 1R1W | One 16384x72 macro; no padding. |
| Smallest bitmap: 128x1 W / 8x16 RW | Sixteen 64x8 macros, each using 8x1 bits; the narrow-lane/minimum-size cost remains. |

Architectural banks come from the elaborated hierarchy, including
[L2Cache.bsv](../../lotus/l2Cache/L2Cache.bsv),
[TaskUnit.bsv](../../lotus/taskUnit/TaskUnit.bsv), and per-core
[DCache.ms](../../lotus/core/DCache.ms)/[ICache.ms](../../lotus/core/ICache.ms).
They are not multiplied again by the model's bank setting.

## Macro attributes to model inputs

`fncacti.generate_config()` creates one config per unique depth/width/port
combination. Repeated instances share the same run.

| Macro attribute | FN-CACTI setting |
|---|---|
| Depth D, width W bits | `-size D*W/8` bytes |
| Width W bits | `-block size W/8` bytes, `-bus width W` bits |
| Port roles | `-read-write port`, `-exclusive read port`, `-exclusive write port` |
| One macro | `-uca bank 1`, `-cache model - "UCA"` |
| Explicit RAM array | `-memory type "ram"`, `-associativity 1`, `-Add ECC - "false"` |
| Area objective | `-optimize - "NONE"`, weights `0:0:0:0:100` |
| Search constraints | Relative deviation limits `100000:100000:100000:100000:100000`; no forced internal organization |

`NONE` disables the ED/ED² objective, not the organization search. The installed
`Ucache.cc` selects the lowest weighted normalized cost among accepted
organizations. Only area has a nonzero weight here; the broad relative deviation
bounds still apply.

The runner invokes `cacti -infile <input.cfg>`, checks the echoed configuration,
finite positive results, and footprint consistency (`height * width = area`).
FN-CACTI can print an error and exit zero, so exit status alone is insufficient.
Configs, binary/template/output hashes, commands, logs, physical dimensions and
internal organization are retained under `sram_model.runs` and `fncacti/`.
Missing executables, malformed output and failed runs prevent a complete total.

```text
macro_area_um2 = reported_area_mm2 * 1,000,000
logical_instance_area = sum(macro_area_um2 * macros_per_instance)
declaration_area = logical_instance_area * logical_multiplicity
tile_sram_area = sum(declaration_area)
```

For L2 data, one 8192×8 macro reports 4608.65 µm². Eight macros per bank and two
logical bank instances give `4608.65 * 8 * 2 = 73,738.40 µm²/tile`.
The tile count (64 in this elaboration) is not another multiplier for a per-tile
report. Failed entries do not silently contribute zero to an otherwise complete
total. Cached results require matching config, executable and output hashes.

## Validated mapping snapshot

The following is the recorded mapping comparison from 2026-10-25, originally
using `/home/ubuntu/lotus/build/fast64t4096e/hdl/bsv`. It is a reference snapshot,
not a claim that every subsequently prepared manifest has run FN-CACTI:

| Per-tile quantity | Former power-of-two-byte mapping | Current candidate search |
|---|---:|---:|
| Logical instances | 25 | 25 |
| Logical bits | 4,033,664 | 4,033,664 |
| Macro instances / unique configurations | 108 / 15 | 108 / 15 |
| Allocated bits | 5,570,560 | 4,407,296 |
| Padding bits | 1,536,896 | 373,632 |
| Padding above logical capacity | 38.10% | 9.26% |
| Uncalibrated SRAM area (µm²) | 362,606.8288 | 294,944.9148 |

Modeled area decreases **18.7%**. The changes are 128 -> 72 bits for edge/task
records and 32 -> 24 bits for tag slices. Most remaining padding is one-bit
arrays modeled with eight-bit macro words. No technology calibration changed.
The current candidate-search totals are also present in the existing
`build/hammer-2ns/manifest.json`. The former comparison directory is no longer
present. A fresh `build/hammer-native-1ns/manifest.json` starts with unresolved
mappings; run the README's FN-CACTI command to populate it. For any particular
build, its own manifest and referenced logs are authoritative.

`fncacti_compare.py` checks native Liberty area against LEF width x height,
then compares **21 exact unpadded 1RW shapes** from the shipped ASAP7 catalog:
widths 16, 32, 40, 48, 64, 72 and 80; depths 256, 512 and 1024. The remaining
15 catalog entries have non-byte widths and are excluded to avoid changing
their capacity for this comparison. Names encode `depth = ROWS * column_mux`.

The recorded expanded check had **9.9% mean absolute percentage error**, with raw areas
**0.7% to 29.3% below** shipped footprints. For the newly used 72-bit width:

| Shape | Released area (µm²) | FN-CACTI area (µm²) | Error |
|---|---:|---:|---:|
| 256x72 | 830.477 | 727.649 | -12.4% |
| 512x72 | 1382.400 | 1366.730 | -1.1% |
| 1024x72 | 2622.067 | 2577.450 | -1.7% |

This is a scale sanity check, not calibration: internal organizations differ,
and only 1RW macros were compared. It does not validate dual-port penalties,
narrow-slice padding, delay or energy. The lower aggregate error than the former
nine-shape check reflects an expanded comparison set, not a changed model.
No correction factor is fitted and no calibrated total combines these areas
with the separate ASAP7 logic estimate. The original generated comparison
directory is no longer present. Rerunning `fncacti_compare.py` writes fresh
reference hashes, commit, configs and results under
`build/fncacti/asap7-comparison/`; the table above remains a historical result.

## Tool provenance

FN-CACTI upstream: [marg-tools/FN-CACTI](https://github.com/marg-tools/FN-CACTI/tree/f37debd04a5b1ac15470b8fdb6d32115e727e7b2), commit
`f37debd04a5b1ac15470b8fdb6d32115e727e7b2`. Files under `ext/fncacti/upstream/`
are downloaded source artifacts, not a Git checkout. The local `fncacti.patch`
matches that commit's Git blob `9903726b6cb148cc0981c19dd147cbf8c29f4c18`.
The supplied `pcacti.tar` was patched
with zero fuzz under `ext/fncacti/work/pcacti_xml`, then built with
`make -j2 CXX=g++ CC=gcc` to use native 64-bit compilation. No model-source edits
were made beyond the upstream patch. The binary is that directory's `cacti`.

The currently installed binary has SHA-256
`afa57cf24af0db0be1bc5f17b437f63c89028b0e778aab0e5f1acaae72e7ef95`, matching
the recorded model runs in `build/hammer-2ns/manifest.json`. The earlier build
and example-smoke logs under `build/fncacti/` are no longer present; they are
not required runtime inputs. Each new run records its own binary, template,
config and output hashes.

For a new installation, follow the pinned upstream README's PCACTI download
and FN-CACTI patch/config setup in a separate work directory. The upstream
setup script removes/recreates its work directories. The user-supplied archive
here is an uncompressed `pcacti.tar`, rather than the script's expected
`pcacti.tgz`; extract it accordingly and apply the upstream patch, then build
with `make -j2 CXX=g++ CC=gcc`. These scripts do not download or build FN-CACTI
automatically. Supply its resulting executable and `configs/2MB_fin.cfg` using
`--binary` and `--template` if installed elsewhere. The example cache's
capacity/bank settings are not Lotus mapping decisions.
The documented baseline uses 14 nm devices and 7 nm wires. Setting the device
node to 7 nm alone would not establish an ASAP7-calibrated SRAM model.
