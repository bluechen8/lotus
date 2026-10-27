#!/usr/bin/env python3
"""Estimate the mapped four-bank ExTensor LLB using the shared ASIC SRAM flow.

Reads config.json, allocates physical macros, and writes result.json/result.csv.
No TeAAL checkout, Accelergy installation or Lotus RTL manifest is required.
"""
import argparse
import csv
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
FLOW = ROOT.parent
MODEL = 'four_banks_mapped_2rw'
sys.path.insert(0, str(FLOW))
from fncacti import DEFAULT_SOURCE, execute_model
from sram import allocate, digest


def evaluate(args):
    config = json.loads(args.config.read_text())
    policy = json.loads(args.policy.read_text())
    memory = config['logical_memory']
    fields = {'depth_words', 'width_bits', 'multiplicity', 'port_roles'}
    if set(memory) != fields:
        raise ValueError(f'logical_memory must contain exactly {sorted(fields)}')
    if memory['port_roles'] != ['RW', 'RW']:
        raise ValueError('The selected ExTensor model requires two RW ports per bank')
    depth, width, count = (memory[k] for k in ('depth_words', 'width_bits', 'multiplicity'))
    logical = dict(raw_bits=depth*width, multiplicity=count, ports=[
        dict(name=str(i), role='RW', width_bits=width, depth_words=depth,
             write_granularity_bits=width) for i in range(2)])
    mapping = allocate(logical, policy)
    macro = mapping['macros'][0]
    instances = macro['total_macros']
    # Model one physical macro; all instance counts belong to the allocation.
    geometry = {key: macro[key] for key in ('depth_words', 'width_bits', 'ports', 'uca_banks')}
    args.out.mkdir(parents=True, exist_ok=True)
    result = dict(name=MODEL, status='running', configuration=config, policy=policy,
        source_hashes={str(p): digest(p) for p in (
            Path(__file__).resolve(), args.config, args.policy, FLOW/'fncacti.py', FLOW/'sram.py')},
        logical=logical, mapping=mapping, macro_count=instances,
        logical_MiB=logical['raw_bits']*count/8/2**20,
        allocated_MiB=macro['depth_words']*macro['width_bits']*instances/8/2**20,
        note='Uncalibrated macro footprints; crossbars, controllers, external routing and timing closure excluded.')
    report = args.out/'result.json'
    report.write_text(json.dumps(result, indent=2)+'\n')
    (args.out/'result.csv').unlink(missing_ok=True)
    cached = sorted((args.out/'fncacti'/MODEL).glob('*/run.json'),
                    key=lambda p: p.stat().st_mtime, reverse=True)
    try:
        previous = json.loads(cached[0].read_text()) if cached and not args.fresh else None
        run = execute_model(MODEL, geometry, policy, args.binary, args.template,
                            args.out/'fncacti', previous=previous, timeout=args.timeout)
    except (ValueError, OSError) as error:
        result.update(status='failed', error=str(error))
        report.write_text(json.dumps(result, indent=2)+'\n')
        raise
    result['run'] = run
    complete = run['status'] == 'complete'
    result['status'] = 'complete_uncalibrated' if complete else 'failed'
    if complete:
        result['area_mm2'] = run['result']['area_um2']*instances/1e6
        result['area_mm2_per_bank'] = result['area_mm2']/count
    report.write_text(json.dumps(result, indent=2)+'\n')
    measured = run.get('result', {})
    with (args.out/'result.csv').open('w', newline='') as stream:
        writer = csv.writer(stream, lineterminator='\n')
        writer.writerow(['model', 'status', 'macro_depth', 'macro_width_bits', 'macro_count',
                         'logical_MiB', 'allocated_MiB', 'total_area_mm2', 'area_mm2_per_bank',
                         'macro_access_ns', 'macro_cycle_ns'])
        writer.writerow([MODEL, result['status'], macro['depth_words'], macro['width_bits'],
                         instances, result['logical_MiB'], result['allocated_MiB'],
                         result.get('area_mm2'), result.get('area_mm2_per_bank'),
                         measured.get('access_time_ns'), measured.get('cycle_time_ns')])
    print(json.dumps({k: result[k] for k in ('name', 'status', 'macro_count', 'allocated_MiB', 'area_mm2') if k in result}
                     | {'reused': run.get('reused', False), 'error': run.get('error')}))
    return 0 if complete else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT/'config.json')
    parser.add_argument('--policy', type=Path, default=FLOW/'fncacti_policy.json')
    parser.add_argument('--out', type=Path, default=ROOT, help='Reports and model runs; defaults to this directory')
    parser.add_argument('--binary', type=Path, default=DEFAULT_SOURCE/'cacti')
    parser.add_argument('--template', type=Path, default=DEFAULT_SOURCE/'configs/2MB_fin.cfg')
    parser.add_argument('--fresh', action='store_true', help='Execute the model even when a valid cached run exists')
    parser.add_argument('--timeout', type=float, default=60)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('--timeout must be finite and positive')
    for key in ('config', 'policy', 'out', 'binary', 'template'):
        setattr(args, key, getattr(args, key).resolve())
    try:
        return evaluate(args)
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(2, f'ExTensor LLB estimation failed: {error}\n')


if __name__ == '__main__':
    sys.exit(main())
