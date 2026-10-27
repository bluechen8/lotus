# Lotus: one tile, 4096 tasks per tile — Genus logic results

The 2026-10-27 Genus run produced **28,362.9114 µm² (0.02836291 mm²)** of standard-cell logic for one `mkTile`, with **197,099 cells**. The synthesis target was **1 ns**. SRAM area is excluded and will be evaluated separately with FNCACTI.

| Result | Value |
|---|---:|
| Standard-cell logic area | 28,362.9114 µm² |
| Standard cells | 197,099 |
| Sequential / combinational cells | 55,087 / 142,012 |
| Worst reported setup slack | +11 ps |
| Total negative slack / violating setup paths | 0 ps / 0 |
| Logged Genus wall time | 47 min 41 s (2861.381 s) |
| Maximum configured threads | 32 |

Timing is synthesis-only at RVT TT, 0.7 V, 25 °C, with zero clock uncertainty. SRAM timing arcs, I/O budgets and routed parasitics are absent; these results do not establish full-tile timing closure. Area includes XRegFile and other standard-cell storage outside logical XRAM boundaries. It excludes SRAM storage and internal adapters, placement whitespace, clock-tree synthesis, routing and inter-tile logic. FPGA power-up initialization is disabled; no ASIC startup/reset circuitry was added.

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

## Validation and evidence

Genus exited normally. A fresh `hammer_syn.py --report-only` passed input fingerprint, clean PDK, mapped-netlist/inventory/timing hash, Liberty area and logical memory retention checks. Native QoR cell counts and area agree with the validated summary; the first detailed timing path agrees with the reported worst setup slack. These checks validate synthesis accounting and output consistency; no formal equivalence check or physical implementation was performed.

The session ran from **2026-10-27 11:03:28 PDT** to **11:51:09 PDT** on `a8`. Wall time uses the Genus start and final license-summary timestamps. The native QoR report was generated earlier, at 2495 elapsed seconds; output export follows it. RTL elaboration and Hammer preparation/validation are outside the reported wall time.

- [result.json](result.json): metrics, breakdown, configuration, validation, commits and artifact SHA-256 hashes.
- [result.csv](result.csv) and [area_breakdown.csv](area_breakdown.csv): tabular results.
- [Native QoR](reports/final_qor.rpt), [hierarchical area](reports/final_area.rpt), and [50-path timing report](reports/lotus_timing.rpt): copies of the completed run's reports.
- Original run: `build/hammer-genus-1ns-final/`; mapped netlist and inventory: `obj/syn-rundir/mkTile.mapped.v` and `lotus_cells.tsv` under that directory.
- Lotus commit: `0cc42debea55d12c90a7c0fe72664a08385dec53`; ASAP7 commit: `e5bd25da72cd297b8c0ec6f77600e0cbaa1124d0`.

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
