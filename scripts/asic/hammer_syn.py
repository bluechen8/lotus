#!/usr/bin/env python3
"""Prepare Lotus inputs, invoke Hammer's CLI, and validate per-tile logic area.

Yosys performs legalization, mapping and area accounting. This module supplies
project configuration and SRAM-retention checks, not a synthesis tool plugin.
"""
import argparse
from collections import Counter
import importlib.metadata
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import yaml

from libraries import DEFAULT_PDK, liberty_cells, prepare_libraries, verify_pdk
from prepare import HERE, REPO, MEMORIES, prepare as prepare_rtl
from sram import digest, load_manifest


def synthesis_entry(files):
    """Hammer reads this include file with Yosys read_verilog -sv.

    The installed plugin has no option for preprocessor defines. Keep these
    local to the compilation input instead of adding a tool hook or converter.
    """
    return ('// Direct Yosys SystemVerilog input; no RTL conversion.\n'
            '`define BSV_NO_INITIAL_BLOCKS\n`define SYNTHESIS\n' +
            ''.join('`include '+json.dumps(str(Path(p).resolve()))+'\n' for p in files))


def synthesis_inputs(out, manifest):
    """Bind a report to the raw RTL, prepared RTL, mapping data and constraints."""
    paths = [Path(p) for p in manifest['synthesis_files']]
    config = yaml.safe_load((out/'design.yml').read_text())
    paths += [out/name for name in ('synthesis_input.v', 'design.yml')]
    paths += [Path(item['library']['nldm_liberty_file'])
              for item in config['vlsi.technology.extra_libraries']]
    paths.append(Path(config['synthesis.yosys.latch_map_file']))
    # Bind reports to the backend actually used, including its local patch.
    import hammer.synthesis.yosys as backend
    paths.append(Path(backend.__file__))
    return dict(source_sha256=manifest['source_sha256'],
                files_sha256={str(p): digest(p) for p in paths})


def validate_synthesis_inputs(out, manifest, provenance):
    if provenance.get('synthesis_inputs') != synthesis_inputs(out, manifest):
        raise ValueError('Synthesis inputs changed or lack a recorded fingerprint; rerun hammer_syn.py synthesis')


def summarize(cell_counts, expected, standard_cells, logic_area, log_text, period_ns):
    actual = Counter()
    mapped_cells = 0
    for typ, count in cell_counts.items():
        if typ in MEMORIES:
            actual[typ] += count
        elif typ in standard_cells:
            mapped_cells += count
        elif typ != '$scopeinfo':
            raise ValueError(f'Unmapped hardware: {typ} ({count} cells)')
    if actual != Counter(expected):
        raise ValueError(f'Logical SRAM counts changed: {dict(actual)} vs {dict(expected)}')
    if not math.isfinite(logic_area) or logic_area <= 0:
        raise ValueError('Yosys did not report a positive finite logic area')
    delays = [float(x) for x in re.findall(r'ABC:\s+.*?Delay\s*=\s*([0-9.]+)', log_text)]
    if not delays:
        raise ValueError('No ABC delay reports found; check synthesis completion')
    return dict(logic_area_um2=logic_area, mapped_standard_cells=mapped_cells,
        retained_logical_srams=dict(actual), total_logical_srams=sum(actual.values()),
        sram_area_status='reported separately in manifest.json; excluded from logic area',
        target_period_ns=period_ns, abc_delay_target_ps=period_ns*1000,
        abc_reported_combinational_delays_ps=delays,
        worst_reported_abc_partition_delay_ps=max(delays), timing_closure_verified=False,
        timing_scope='ABC hierarchy partitions only; no full STA, SRAM timing, or routing',
        area_scope='Standard cells outside logical XRAM boundaries; includes XRegFile')


def report_results(out):
    out = Path(out).resolve()
    # Invalidate a previous success before checking a new/failed run.
    (out/'hammer_summary.json').unlink(missing_ok=True)
    config = yaml.safe_load((out/'design.yml').read_text())
    outputs = json.loads((out/'syn-output.json').read_text())
    mapped = Path(outputs['synthesis.outputs.output_files'][0])
    if not mapped.is_file():
        raise ValueError('Hammer did not produce a mapped netlist')
    manifest = load_manifest(out/'manifest.json')
    provenance = json.loads((out/'pdk_provenance.json').read_text())
    validate_synthesis_inputs(out, manifest, provenance)
    libraries = [Path(p) for p in provenance['libraries']]
    q = lambda p: json.dumps(str(p))
    # Reintroduce the logical blackbox declarations omitted by write_verilog.
    # Check and flatten for accurate per-tile counts without a huge netlist JSON.
    script = f'read_verilog -sv {q(out/"rtl/memory_blackboxes.sv")}\nread_verilog {q(mapped)}\n'
    script += ''.join(f'read_liberty -lib -ignore_miss_func {q(p)}\n' for p in libraries)
    script += 'hierarchy -check -top mkTile\nflatten\ncheck -assert\n'
    lib_args = ' '.join(f'-liberty {q(p)}' for p in libraries)
    script += f'tee -o {q(out/"mapped_stats.json")} stat -json -top mkTile {lib_args}\n'
    (out/'validate.ys').write_text(script)
    with (out/'validate.log').open('w') as log:
        subprocess.run([config['synthesis.yosys.yosys_bin'], '-Q', '-T', '-s', str(out/'validate.ys')],
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    stats = json.loads((out/'mapped_stats.json').read_text())
    expected = Counter()
    for ram in manifest['memory_inventory']:
        expected[ram['logical']['type']] += ram['logical']['multiplicity']
    tile_stats = stats['modules']['\\mkTile']
    standard_cells = {name for p in libraries for name in liberty_cells(p.read_text())}
    report = summarize(tile_stats['num_cells_by_type'], expected,
        standard_cells, tile_stats['area'], (out/'synthesis-console.log').read_text(),
        float(config['vlsi.inputs.clocks'][0]['period'].removesuffix(' ns')))
    import hammer.synthesis.yosys as backend
    report.update(hammer_version=importlib.metadata.version('hammer-vlsi'),
        hammer_backend=dict(path=backend.__file__, sha256=digest(Path(backend.__file__))),
        logic_area_source='Yosys stat -json with all selected Liberty files',
        source_build=manifest['source_build'], standard_cell_corner='ASAP7 v28 RVT TT 0.7V 25C',
        abc_boundary_assumptions='No driver cell, explicit capacitive load, or SRAM timing arcs',
        limitations=['SRAM storage and internal initialization, banking, masks, bypass and latency adapters excluded',
            'FPGA power-up initialization disabled; no added ASIC startup/reset circuitry',
            'No placement/utilization, clock tree, routing, or inter-tile area',
            'SRAM estimates are separate in manifest.json; no combined total area claimed'])
    repositories = provenance['repositories']
    if verify_pdk(Path(repositories['asap7sc7p5t_28']['path']).parent) != repositories:
        raise ValueError('PDK repository changed during this run')
    (out/'hammer_summary.json').write_text(json.dumps(report, indent=2)+'\n')
    return report


def prepare(args):
    out = args.out.resolve()
    pdk_root = args.pdk_root.resolve()
    if out == pdk_root or pdk_root in out.parents:
        raise ValueError('Output must be outside the upstream PDK directory')
    spec = importlib.util.find_spec('hammer')
    if spec is None:
        raise SystemExit('Install hammer-vlsi[asap7] in the active Python environment')
    hammer_dir = Path(next(iter(spec.submodule_search_locations)))
    from hammer.synthesis.yosys import YosysSynth
    if not hasattr(YosysSynth, 'liberty_args'):
        raise SystemExit('Use the pinned Hammer checkout with hammer-yosys.patch; see scripts/asic/README.md')
    manifest = prepare_rtl(args.build_dir.resolve(), out, args.bsc_lib.resolve())
    (out/'hammer_summary.json').unlink(missing_ok=True)
    (out/'syn-output.json').unlink(missing_ok=True)
    libraries = prepare_libraries(pdk_root, out)
    (out/'synthesis_input.v').write_text(synthesis_entry(manifest['synthesis_files']))
    standard = [{'library': {'name':p.stem, 'nldm_liberty_file':str(p),
        'corner': {'nmos':'typical','pmos':'typical','temperature':'25 C'},
        'supplies': {'VDD':'0.7 V','GND':'0 V'}, 'provides':[{'lib_type':'stdcell','vt':'RVT'}]}} for p in libraries]
    # Reuse Hammer's technology latch map. Ordinary dfflibmap legalizes flops.
    latch_map = hammer_dir/'technology/asap7/latch_map.v'
    config = {'vlsi.core.technology':'hammer.technology.nop', 'vlsi.core.node':7,
        'vlsi.inputs.supplies':{'VDD':'0.7 V','GND':'0 V'},
        'vlsi.technology.extra_libraries':standard,
        'vlsi.core.synthesis_tool':'hammer.synthesis.yosys',
        'vlsi.inputs.clocks':[{'name':'CLK','path':'CLK','period':f'{args.clock_period_ns:g} ns','uncertainty':'0 ns'}],
        'vlsi.inputs.mmmc_corners':[{'name':'RVT_TT','type':'extra','voltage':'0.7 V','temp':'25 C'}],
        'synthesis.inputs.top_module':'mkTile',
        'synthesis.inputs.input_files':[str(out/'synthesis_input.v')], 'synthesis.yosys.yosys_bin':args.yosys,
        'synthesis.yosys.latch_map_file':str(latch_map), 'openroad.extra_env_vars':[]}
    (out/'design.yml').write_text(yaml.safe_dump(config, sort_keys=False))
    provenance = json.loads((out/'pdk_provenance.json').read_text())
    provenance['synthesis_inputs'] = synthesis_inputs(out, manifest)
    (out/'pdk_provenance.json').write_text(json.dumps(provenance, indent=2)+'\n')
    # Hammer's Yosys backend uses .mapped.sdc for ABC's driver/load constraints.
    # Emit clock intent separately; this does not run full STA.
    (out/'clock.sdc').write_text('# Native ASAP7 units: ps. Clock intent; no STA run.\n'
        f'create_clock -name CLK -period {args.clock_period_ns*1000:g} [get_ports CLK]\n')
    command = ['hammer-vlsi','-p',str(out/'design.yml'),'--obj_dir',str(out/'obj'),
        '-l',str(out/'syn-hammer.log'),'-o',str(out/'syn-output.json'),'syn']
    lines = ['#!/usr/bin/env bash','set -euo pipefail',
        'rm -f '+shlex.join([str(out/'hammer_summary.json'), str(out/'syn-output.json'),
                             str(out/'obj/syn-rundir/mkTile.mapped.v')]),
        shlex.join(command)+' 2>&1 | tee '+shlex.quote(str(out/'synthesis-console.log')),
        shlex.join([sys.executable,str(HERE/'hammer_syn.py'),'--out',str(out),'--report-only'])]
    (out/'run_hammer.sh').write_text('\n'.join(lines)+'\n')
    print(f'Generated logic-only Hammer YAML and unified manifest in {out}', flush=True)
    print('Run in the active Hammer environment: bash '+str(out/'run_hammer.sh'), flush=True)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument('--build-dir', type=Path, default=REPO/'build/fast64t4096e',
                        help='Build directory containing raw hdl/bsv Verilog')
    parser.add_argument('--out', type=Path, default=REPO/'build/hammer-native-1ns',
                        help='Prepared RTL, manifest and Hammer output directory')
    parser.add_argument('--pdk-root', type=Path, default=DEFAULT_PDK,
                        help='Parent of the clean asap7sc7p5t_28 checkout')
    parser.add_argument('--bsc-lib', type=Path, default=Path('/home/ubuntu/tools/bsc-2024.01-ubuntu-24.04/lib'),
                        help='BSC library directory containing Verilog/')
    parser.add_argument('--yosys', default='/home/ubuntu/yosys-062/yosys',
                        help='Yosys 0.62 executable with matching ABC installation')
    parser.add_argument('--clock-period-ns', type=float, default=1.0,
                        help='ABC mapping target; not a full-STA constraint set')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--prepare-only', action='store_true', help='Write inputs without running synthesis')
    mode.add_argument('--report-only', action='store_true', help='Validate and report an existing mapped netlist')
    args = parser.parse_args()
    if args.report_only:
        print(json.dumps(report_results(args.out), indent=2))
        return
    if not math.isfinite(args.clock_period_ns) or args.clock_period_ns <= 0:
        parser.error('Clock period must be finite and positive')
    out = prepare(args)
    if not args.prepare_only:
        env = dict(os.environ)
        env['PATH'] = str(Path(sys.executable).parent)+os.pathsep+env.get('PATH','')
        subprocess.run(['bash',str(out/'run_hammer.sh')], env=env, check=True)


if __name__ == '__main__':
    main()
