# Lotus: one tile, 4096 tasks per tile — logic and SRAM area

The 2026-10-27 Genus run produced **28,362.9114 µm²** of standard-cell logic for one `mkTile`, with **197,099 cells**. Adding **294,944.9148 µm²** of separately modeled FN-CACTI SRAM gives a **combined area estimate of 323,307.8262 µm² (0.3233078262 mm²) per tile**. The SRAM model is uncalibrated; this sum is not a placed tile footprint. The synthesis target was **1 ns**.

| Result | Value |
|---|---:|
| Standard-cell logic area | 28,362.9114 µm² |
| SRAM macro area, uncalibrated | 294,944.9148 µm² |
| Combined area estimate | 323,307.8262 µm² |
| SRAM macros / unique modeled geometries and port sets | 108 / 15 |
| Standard cells | 197,099 |
| Sequential / combinational cells | 55,087 / 142,012 |
| Worst reported setup slack | +11 ps |
| Total negative slack / violating setup paths | 0 ps / 0 |
| Logged Genus wall time | 47 min 41 s (2861.381 s) |
| Maximum configured threads | 32 |

Timing is synthesis-only at RVT TT, 0.7 V, 25 °C, with zero clock uncertainty. SRAM timing arcs, I/O budgets and routed parasitics are absent; these results do not establish full-tile timing closure. Logic area includes XRegFile and other standard-cell storage outside logical XRAM boundaries. FN-CACTI adds the SRAM macro footprints separately, without double-counting XRegFile. External memory adapters, placement whitespace, clock-tree synthesis, routing and inter-tile logic remain excluded. FPGA power-up initialization is disabled; no ASIC startup/reset circuitry was added.

## Configuration

The evaluated unit is **one tile with 4 cores and 4096 tasks per tile**. Its RTL comes from `fast64t4096e`, elaborated in a **64-tile system context**, which determines global widths and parameters. This is not RTL elaborated using `--tiles=1`.

| Setting | Value |
|---|---|
| Synthesis top / evaluated tiles | `mkTile` / 1 |
| Elaboration context / devices | 64 tiles / 1 |
| Cores / tasks per tile | 4 / 4096 |
| L2 cache capacity / banks | 128 KiB / 2 |
| Average / maximum outgoing edges per task | 8 / 63 |
| Average / maximum arguments per task | 4 / 15 |
| Tiles per switch port / memory channel | 4 / 4 |
| Clock / automatic clock gating | 1 ns / off |
| Technology | ASAP7 v28 RVT TT, native 1× Liberty areas |
| Tools | Genus 25.11-s095_1; Hammer 1.2.0 |

[config.json](config.json) records every numeric BSC elaboration define from `build/asic-tile-build.log` and the synthesis settings.

## Logic area breakdown

Areas below sum native Liberty areas for each validated mapped standard cell. `other_tile_logic` covers all remaining tile hierarchy, including performance counters, queues, switches and tile-level glue. The L2 row includes only its standard-cell logic.

| Block | Cells | Area (µm²) | Share |
|---|---:|---:|---:|
| `cores_0` | 28,488 | 3,891.3728 | 13.72% |
| `cores_1` | 28,318 | 3,886.9697 | 13.70% |
| `cores_2` | 28,487 | 3,891.1687 | 13.72% |
| `cores_3` | 28,401 | 3,888.8068 | 13.71% |
| `l2` | 25,754 | 3,973.9831 | 14.01% |
| `other_tile_logic` | 10,086 | 1,608.0719 | 5.67% |
| `taskUnit` | 26,734 | 4,179.9402 | 14.74% |
| `tokenSender` | 20,831 | 3,042.5981 | 10.73% |
| **Total** | **197,099** | **28,362.9114** | **100%** |

## SRAM mapping and combined area

The local SRAM inventory contains **25 logical RAM instances**, represented by 16 declarations with hierarchy multiplicities. The existing [allocation policy](../fncacti_policy.json) maps them to **108 macros**, using **15 distinct geometry/port combinations**. Logical capacity is **4,033,664 bits**; allocated capacity is **4,407,296 bits**, including **373,632 padding bits (9.26% of logical capacity)**. Counts and area cover one tile; do not multiply them by the 64-tile elaboration context.

The allocator splits RAMs at independently writable mask and asymmetric-port boundaries. It searches byte-aligned widths of 8–128 bits in 8-bit steps and power-of-two depths of 2–32,768 words, subject to the model's minimum capacity. Each logical RAM uses one repeated geometry, with width slices and depth banks as needed. Selection uses MacroCompiler's DefaultMetric formula, `padding_bits / logical_bits + 0.05 * macro_count`, before FN-CACTI evaluates the selected macros. It does not minimize FN-CACTI area across all possible allocations.

Each FN-CACTI input describes **one macro**: capacity is `depth_words * width_bits / 8` bytes; block size is `width_bits / 8` bytes; bus width is `width_bits`; read/write port counts preserve the logical port roles; UCA bank count is one. FN-CACTI optimizes the internal organization for area. Per-declaration area is `area_per_macro * macros_per_logical_instance * logical_instance_count`; summing those products gives the tile SRAM estimate. [sram_macros.csv](sram_macros.csv) exposes every product, and [sram_result.json](sram_result.json) records logical parameters, normalization, selected geometry, counts, model outputs and provenance. See [FNCACTI.md](../FNCACTI.md) for the modeling assumptions and calibration limitations.

| Block | Genus logic (µm²) | SRAM estimate (µm²) | Combined estimate (µm²) |
|---|---:|---:|---:|
| `cores_0` | 3,891.37284 | 5,296.6200 | 9,187.99284 |
| `cores_1` | 3,886.96968 | 5,296.6200 | 9,183.58968 |
| `cores_2` | 3,891.16872 | 5,296.6200 | 9,187.78872 |
| `cores_3` | 3,888.80676 | 5,296.6200 | 9,185.42676 |
| `l2` | 3,973.98312 | 78,829.2000 | 82,803.18312 |
| `other_tile_logic` | 1,608.07194 | 0 | 1,608.07194 |
| `taskUnit` (including priority queue) | 4,179.94020 | 118,565.2348 | 122,745.17500 |
| `tokenSender` | 3,042.59814 | 76,364.0000 | 79,406.59814 |
| **Total** | **28,362.91140** | **294,944.9148** | **323,307.82620** |

FN-CACTI here uses **14 nm FinFET devices with 7 nm ASAP7 wires**, at 0.7 V and 300 K. These are analytical macro footprints, not characterized ASAP7 SRAMs. The area objective imposes no 1 ns SRAM timing constraint. External address/bank/lane selection, mask enables and bypass/latency/initialization adapters are not generated or charged by this estimate. The combined estimate therefore is not a complete physically implemented tile area.

The SRAM evidence comes from the local `build/hammer-native-1.3ns/manifest.json`, independently elaborated from `build/fast64t4096e`; **only its SRAM inventory and model results are used**, not its Yosys logic area or timing. Its [recorded SCons action](reports/sram_source_build.txt) matches every numeric elaboration define in the Genus configuration, and the stored `mkTile.v` content signature matches the local file. All six SRAM declaration source files match the Genus commit. However, the local raw RTL SHA-256 hashes differ from those recorded by the Berkeley Genus run, and that run's original manifest is not included in the remote commit. An exact comparison against the Genus memory inventory remains unverified; this is a same-configuration SRAM estimate, not a claim of byte-identical inputs.

## Validation and evidence

The original Genus run exited normally, and its recorded `hammer_syn.py --report-only` validation passed input fingerprint, clean PDK, mapped-netlist/inventory/timing hash, Liberty area and logical memory retention checks. Native QoR cell counts and area agree with the validated summary; the first detailed timing path agrees with the reported worst setup slack. These checks validate synthesis accounting and output consistency; no formal equivalence check or physical implementation was performed.

The session ran from **2026-10-27 11:03:28 PDT** to **11:51:09 PDT** on `a8`. Wall time uses the Genus start and final license-summary timestamps. The native QoR report was generated earlier, at 2495 elapsed seconds; output export follows it. RTL elaboration and Hammer preparation/validation are outside the reported wall time.

- [result.json](result.json): metrics, breakdown, configuration, validation, commits and artifact SHA-256 hashes.
- [result.csv](result.csv) and [area_breakdown.csv](area_breakdown.csv): tabular results.
- [sram_macros.csv](sram_macros.csv): macro dimensions, ports, counts and area products for each logical declaration.
- [sram_result.json](sram_result.json): SRAM inventory and model evidence, with archived input/output paths under `reports/fncacti/`. Every archived file has a SHA-256 recorded in its model run; original execution paths are retained as provenance.
- [Native QoR](reports/final_qor.rpt), [hierarchical area](reports/final_area.rpt), and [50-path timing report](reports/lotus_timing.rpt): copies of the completed run's reports.
- Original run: `build/hammer-genus-1ns-final/`; mapped netlist and inventory: `obj/syn-rundir/mkTile.mapped.v` and `lotus_cells.tsv` under that directory.
- Lotus commit: `0cc42debea55d12c90a7c0fe72664a08385dec53`; ASAP7 commit: `e5bd25da72cd297b8c0ec6f77600e0cbaa1124d0`.

The SRAM attachment was revalidated against current local RTL/declaration fingerprints and the allocation policy. Fresh preparation reconstructed every logical RAM declaration, and a separate hierarchy walk confirmed the per-block assignments and multiplicities. All 15 archived model inputs and outputs passed hash checks, input regeneration and output parsing; rerunning those inputs reproduced every model result. Decimal arithmetic using areas read directly from native outputs confirmed the CSV/JSON area products and totals. The original Genus report files and logic/timing measurements are unchanged. Genus synthesis and its `--report-only` validation were not rerun when adding SRAM area.

The review also ran `python -m unittest discover -s scripts/asic/tests -v`: **38 passed, 2 skipped**. The skipped Hammer/Yosys and licensed Genus integration tests require their respective test configurations; they are not counted as passes.

## Reproduce or revalidate

From the repository root, using the environment described in [the ASIC README](../README.md#genus-on-the-berkeley-host):

```bash
export PATH="$PWD/ext/bsc-2024.01-rockylinux-9.3/bin:$PATH"
PYTHONPATH="$PWD/ext/python" python ext/python/bin/scons \
  --cfg=fast --tiles=64 --tasksPerTile=4096 \
  MINISPEC="$PWD/ext/minispec" asic-tile

export CDS_LIC_FILE=5280@license-srv.eecs.berkeley.edu
python scripts/asic/hammer_syn.py --tool genus \
  --build-dir build/fast64t4096e --out build/hammer-genus-1ns-final \
  --pdk-root ext/asap7 --bsc-lib ext/bsc-2024.01-rockylinux-9.3/lib \
  --genus /ecad/tools/cadence/DDI/DDI251/GENUS251/bin/genus \
  --genus-version 251 --clock-period-ns 1 --max-threads 32
```

To validate the existing run without rerunning synthesis:

```bash
python scripts/asic/hammer_syn.py --out build/hammer-genus-1ns-final --report-only
```

With FN-CACTI installed as described in [FNCACTI.md](../FNCACTI.md), evaluate SRAMs from the same run's manifest:

```bash
python scripts/asic/fncacti.py \
  --manifest build/hammer-genus-1ns-final/manifest.json
```

The attached estimate used `--manifest build/hammer-native-1.3ns/manifest.json` on this host. To rerun one archived macro directly, use the matching FN-CACTI binary and pass its archived `input.cfg` with `-infile`; binary and input hashes are recorded in `sram_result.json`. A changed policy, source inventory or model binary requires recomputing the attachment and aggregate areas.
