#!/usr/bin/env python3
"""Allocate SRAMs in the manifest, generate FN-CACTI configs, and record model runs."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import time

from sram import (REPO, configure, digest, load_manifest, save_manifest,
                  unique_macros, update_totals)

DEFAULT_SOURCE = REPO/'ext/fncacti/work/pcacti_xml'


def generate_config(template, macro, policy):
    """One config models one physical lane macro, never its instance count."""
    if macro['uca_banks'] != 1:
        raise ValueError('Each FN-CACTI run must model one UCA bank')
    if (type(macro['width_bits']) is not int or macro['width_bits'] < 8
            or macro['width_bits'] % 8):
        raise ValueError('FN-CACTI macro widths must be positive whole bytes; do not truncate bits')
    replacements = {
        '-transistor type': '-transistor type - "finfet"',
        '-technology node': '-technology node 0.014',
        '-wire technology node': '-wire technology node 0.007',
        '-operating voltage': f"-operating voltage {policy['voltage_v']:g}",
        '-DVS(V):': f"-DVS(V): {policy['voltage_v']:g}",
        '-temperature': f"-temperature {policy['temperature_k']}",
        '-size': f"-size {macro['depth_words']*macro['width_bits']//8}",
        '-block size': f"-block size {macro['width_bits']//8}",
        '-associativity': '-associativity 1',
        '-ncfet': '-ncfet - "false"',
        '-read-write port': f"-read-write port {macro['ports']['read_write']}",
        '-exclusive read port': f"-exclusive read port {macro['ports']['exclusive_read']}",
        '-exclusive write port': f"-exclusive write port {macro['ports']['exclusive_write']}",
        '-single ended read ports': '-single ended read ports 0',
        '-search port': '-search port 0',
        '-cache model': '-cache model - "UCA"',
        '-uca bank': '-uca bank 1',
        '-nuca bank count': '-nuca bank count 0',
        '-bus width': f"-bus width {macro['width_bits']}",
        '-memory type': '-memory type "ram"',
        '-access mode': '-access mode - "normal"',
        '-optimize': '-optimize - "NONE"',
        '-design objective': '-design objective (weight delay, dynamic power, leakage power, cycle time, area) 0:0:0:0:100',
        '-deviate': '-deviate (delay, dynamic power, leakage power, cycle time, area) 100000:100000:100000:100000:100000',
        '-interconnects': '-interconnects - "ASAP7"',
        '-Add ECC': '-Add ECC - "false"',
        '-Print input parameters': '-Print input parameters - "false"',
        '-Force cache config': '-Force cache config - "false"',
    }
    found = {key: 0 for key in replacements}
    lines = []
    for line in template.splitlines():
        stripped = line.strip()
        for key, replacement in replacements.items():
            if stripped == key or stripped.startswith(key+' '):
                found[key] += 1
                line = replacement
                break
        lines.append(line)
    invalid = {key: count for key, count in found.items() if count != 1}
    if invalid:
        raise ValueError(f'Template must contain each model setting once: {invalid}')
    return '# Generated from manifest macro geometry; uncalibrated 14nm device / 7nm wire model.\n'+'\n'.join(lines)+'\n'


def parse_result(text, macro):
    if re.search(r'^\s*ERROR\s*:', text, re.M | re.I):
        raise ValueError('FN-CACTI reported an error even if its exit code was zero')
    if re.search(r'\b(?:nan|inf|infinity)\b', text, re.I):
        raise ValueError('FN-CACTI returned non-finite values')
    def line(label):
        matches = re.findall(r'^\s*'+re.escape(label)+r'\s*:\s*(.*?)\s*$', text, re.M)
        if len(matches) != 1:
            raise ValueError(f'Expected one output line for {label}; got {len(matches)}')
        return matches[0]
    def number(label):
        values = [v.strip() for v in line(label).split(';') if v.strip()]
        if len(values) != 1:
            raise ValueError(f'Expected one voltage point for {label}')
        value = float(values[0])
        if not math.isfinite(value) or value <= 0:
            raise ValueError(f'Invalid {label}: {value}')
        return value
    for label, expected in {
        'Total cache size (bytes)': macro['depth_words']*macro['width_bits']//8,
        'Number of banks': 1, 'Associativity': 1,
        'Block size (bytes)': macro['width_bits']//8,
        'Read/write Ports': macro['ports']['read_write'],
        'Read ports': macro['ports']['exclusive_read'],
        'Write ports': macro['ports']['exclusive_write'], 'Technology size (nm)': 14,
    }.items():
        echoed = line(label)
        value = 1 if label == 'Associativity' and echoed == 'direct mapped' else int(echoed)
        if value != expected:
            raise ValueError(f'Model echoed wrong {label}: {line(label)} vs {expected}')
    dimensions = line('Cache height x width (mm)').rstrip('; ').split(' x ')
    if len(dimensions) != 2:
        raise ValueError('Expected a single physical height/width pair')
    height, width = map(float, dimensions)
    area = number('Cache area (mm2)')
    if not all(math.isfinite(x) and x > 0 for x in (height, width)):
        raise ValueError('Invalid physical dimensions')
    if not math.isclose(height*width, area, rel_tol=1e-4):
        raise ValueError('Reported footprint disagrees with height times width')
    return dict(area_um2=area*1e6, physical_dimensions_um=dict(height=height*1000, width=width*1000),
        access_time_ns=number('Access time (ns)'), cycle_time_ns=number('Cycle time (ns)'),
        organization={key: number(label) for key, label in {
            'Ndwl': 'Best Ndwl', 'Ndbl': 'Best Ndbl', 'Nspd': 'Best Nspd',
            'Ndcm': 'Best Ndcm', 'Ndsam1': 'Best Ndsam L1', 'Ndsam2': 'Best Ndsam L2'}.items()})


def estimate_memories(manifest):
    runs = manifest['sram_model']['runs']
    for record in manifest['memory_inventory']:
        macros = record['mapping']['macros']
        if not all(runs.get(m['id'], {}).get('status') == 'complete' for m in macros):
            record['estimation'] = dict(status='not_complete', macro_ids=[m['id'] for m in macros])
            continue
        per_instance = sum(runs[m['id']]['result']['area_um2']*m['macros_per_instance'] for m in macros)
        record['estimation'] = dict(status='complete', macro_ids=[m['id'] for m in macros],
            area_um2_per_instance=per_instance,
            area_um2_all_instances=per_instance*record['logical']['multiplicity'],
            physical_dimensions='See sram_model.runs[macro_id].result.physical_dimensions_um',
            scope='Uncalibrated macro footprint only; external adapters excluded')
    update_totals(manifest)


def execute_model(macro_id, macro, policy, binary, template_path, root,
                  previous=None, prepare_only=False, timeout=60):
    template = template_path.read_text()
    binary_sha = digest(binary)
    template_sha = digest(template_path)
    config = generate_config(template, macro, policy)
    config_sha = hashlib.sha256(config.encode()).hexdigest()
    signature = hashlib.sha256((binary_sha+config_sha).encode()).hexdigest()[:16]
    directory = root/macro_id/signature
    directory.mkdir(parents=True, exist_ok=True)
    config_path = directory/'input.cfg'
    config_path.write_text(config)
    command = [str(binary), '-infile', str(config_path)]
    run = dict(status='prepared', macro=macro, config=str(config_path), config_sha256=config_sha,
        binary=str(binary), binary_sha256=binary_sha, template=str(template_path), template_sha256=template_sha,
        command=command, cwd=str(directory), stdout=str(directory/'stdout.log'), stderr=str(directory/'stderr.log'))
    old = previous or {}
    if (old.get('status') == 'complete' and old.get('binary_sha256') == binary_sha
            and old.get('config_sha256') == config_sha
            and all(isinstance(old.get(stream), str) and Path(old[stream]).is_file()
                    and digest(Path(old[stream])) == old.get(stream+'_sha256')
                    for stream in ('stdout', 'stderr'))):
        # Reparse the checked output; do not trust an edited cached result.
        run = dict(old, result=parse_result(Path(old['stdout']).read_text(), macro), reused=True)
    elif not prepare_only:
        start = time.monotonic()
        run['started_utc'] = datetime.now(timezone.utc).isoformat()
        try:
            with Path(run['stdout']).open('w') as stdout, Path(run['stderr']).open('w') as stderr:
                completed = subprocess.run(command, cwd=directory, stdout=stdout, stderr=stderr, timeout=timeout)
            run['exit_code'] = completed.returncode
            if completed.returncode != 0:
                raise ValueError(f'FN-CACTI exited {completed.returncode}')
            run['result'] = parse_result(Path(run['stdout']).read_text(), macro)
            run['status'] = 'complete'
        except (ValueError, subprocess.TimeoutExpired, OSError) as error:
            run.update(status='failed', error=str(error))
        run['elapsed_seconds'] = time.monotonic()-start
        for stream in ('stdout', 'stderr'):
            if Path(run[stream]).is_file():
                run[stream+'_sha256'] = digest(Path(run[stream]))
    (directory/'run.json').write_text(json.dumps(run, indent=2)+'\n')
    return run


def run_models(path, policy, binary, template_path, prepare_only=False, timeout=60):
    manifest = load_manifest(path)
    configure(manifest, policy)
    macros = unique_macros(manifest)
    binary = binary.resolve()
    template_path = template_path.resolve()
    previous = manifest['sram_model'].get('runs', {})
    manifest['sram_model']['runs'] = {}
    manifest['sram_model']['status'] = 'preparing' if prepare_only else 'running'
    # Never retain previous aggregate success while a new configuration runs.
    for record in manifest['memory_inventory']:
        record['estimation'] = dict(status='not_run')
    update_totals(manifest)
    save_manifest(path, manifest)
    failures = []
    for macro_id, macro in macros.items():
        try:
            run = execute_model(macro_id, macro, policy, binary, template_path, path.parent/'fncacti',
                                previous.get(macro_id), prepare_only, timeout)
        except (ValueError, OSError) as error:
            # Missing/corrupt input files and malformed cached output must also
            # invalidate the aggregate, not leave a run indefinitely 'running'.
            run = dict(status='failed', macro=macro, error=str(error))
        manifest['sram_model']['runs'][macro_id] = run
        if run['status'] == 'failed':
            failures.append(macro_id)
        estimate_memories(manifest)
        save_manifest(path, manifest)
        print(f"{macro_id}: {run['status']}", flush=True)
    manifest['sram_model']['status'] = ('failed' if failures else
        'complete_uncalibrated' if all(r['status'] == 'complete' for r in manifest['sram_model']['runs'].values()) else 'prepared')
    estimate_memories(manifest)
    save_manifest(path, manifest)
    print(json.dumps(manifest['sram_model']['totals'], indent=2))
    if failures:
        raise ValueError(f'No complete SRAM total: FN-CACTI failed for {failures}; inspect manifest run records')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--policy', type=Path, help='Explicit mapping/technology policy JSON; otherwise reuse the recorded policy')
    parser.add_argument('--binary', type=Path, default=DEFAULT_SOURCE/'cacti')
    parser.add_argument('--template', type=Path, default=DEFAULT_SOURCE/'configs/2MB_fin.cfg')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--timeout', type=float, default=60)
    args = parser.parse_args()
    path = args.manifest.resolve()
    try:
        policy = json.loads(args.policy.read_text()) if args.policy else load_manifest(path)['sram_model'].get('policy')
        if policy is None:
            raise ValueError('No allocation/technology policy selected; pass --policy explicitly')
        if not math.isfinite(args.timeout) or args.timeout <= 0:
            raise ValueError('Timeout must be finite and positive')
        run_models(path, policy, args.binary, args.template, args.prepare_only, args.timeout)
    except (ValueError, OSError) as error:
        parser.exit(2, f'FN-CACTI flow failed: {error}\n')


if __name__ == '__main__':
    main()
