#!/usr/bin/env python3
"""Compare unscaled FN-CACTI footprints to same-capacity shipped ASAP7 1RW macros."""
import argparse
import csv
import json
from pathlib import Path
import re
import statistics

from fncacti import DEFAULT_SOURCE, execute_model
from libraries import liberty_cells, git
from sram import REPO, digest


def compare(sram_root, out, binary, template):
    out.mkdir(parents=True, exist_ok=True)
    (out/'comparison.csv').unlink(missing_ok=True)
    (out/'comparison.json').write_text(json.dumps(dict(status='running'))+'\n')
    policy = json.loads((REPO/'scripts/asic/fncacti_policy.json').read_text())
    rows, skipped = [], []
    provenance = dict(path=str(sram_root), commit=git(sram_root, 'rev-parse', 'HEAD'),
                      remote=git(sram_root, 'remote', 'get-url', 'origin'))
    if git(sram_root, 'status', '--porcelain'):
        raise ValueError('Reference SRAM checkout is modified')
    for lib in sorted((sram_root/'generated/LIB').glob('srambank_*_6t122.lib')):
        match = re.fullmatch(r'srambank_(\d+)x(\d+)x(\d+)_6t122', lib.stem)
        if match is None:
            raise ValueError(f'Unexpected macro name: {lib}')
        physical_rows, column_mux, width = map(int, match.groups())
        depth = physical_rows*column_mux
        # Exact matching only. Do not use padded macros to judge model accuracy.
        if width < 8 or width % 8:
            skipped.append(dict(name=lib.stem, reason='Width is not a whole number of bytes; excluded to avoid padding the comparison'))
            continue
        area = liberty_cells(lib.read_text())[lib.stem]
        lef = sram_root/'generated/LEF'/f'{lib.stem}.lef'
        dimensions = re.search(r'SIZE\s+([\d.]+)\s+BY\s+([\d.]+)', lef.read_text())
        lef_width, lef_height = map(float, dimensions.groups())
        if abs(lef_width*lef_height-area) > 1e-5:
            raise ValueError(f'Reference Liberty/LEF area mismatch: {lib.stem}')
        macro = dict(depth_words=depth, width_bits=width, uca_banks=1,
                     ports=dict(read_write=1, exclusive_read=0, exclusive_write=0))
        run = execute_model(lib.stem, macro, policy, binary, template, out/'runs')
        record = dict(name=lib.stem, depth_words=depth, width_bits=width,
            published_rows=physical_rows, published_column_mux=column_mux,
            published_area_um2=area, published_dimensions_um=dict(width=lef_width, height=lef_height),
            liberty=dict(path=str(lib), sha256=digest(lib)), lef=dict(path=str(lef), sha256=digest(lef)),
            run=run)
        if run['status'] == 'complete':
            modeled = run['result']['area_um2']
            record.update(fncacti_area_um2=modeled, ratio=modeled/area,
                          error_percent=100*(modeled/area-1))
            print(f'{lib.stem}: released {area:.3f}, FN-CACTI {modeled:.3f} um2; ratio {modeled/area:.3f}', flush=True)
        else:
            print(f"{lib.stem}: FAILED: {run['error']}", flush=True)
        rows.append(record)
        (out/'comparison.json').write_text(json.dumps(dict(reference=provenance, policy=policy,
            comparisons=rows, skipped=skipped, status='running'), indent=2)+'\n')
    if git(sram_root, 'status', '--porcelain') or git(sram_root, 'rev-parse', 'HEAD') != provenance['commit']:
        raise ValueError('Reference checkout changed during comparison')
    valid = [r for r in rows if r['run']['status'] == 'complete']
    summary = dict(status='complete' if len(valid) == len(rows) and rows else 'incomplete',
        reference=provenance, policy=policy, comparisons=rows, skipped=skipped,
        scope='Same depth, word width and 1RW ports, no padding; FN-CACTI chooses internal organization. '
              '14nm FinFET devices / 7nm ASAP7 wires versus released ASAP7 7nm footprints. '
              'No fitted scale factor; does not validate multiport SRAMs.')
    if valid:
        ratios = [r['ratio'] for r in valid]
        summary['statistics'] = dict(matched_macros=len(valid), min_ratio=min(ratios),
            max_ratio=max(ratios), median_ratio=statistics.median(ratios),
            mean_absolute_percentage_error=statistics.mean(abs(r['error_percent']) for r in valid))
    (out/'comparison.json').write_text(json.dumps(summary, indent=2)+'\n')
    with (out/'comparison.csv').open('w') as f:
        writer = csv.DictWriter(f, fieldnames=['name', 'depth_words', 'width_bits',
            'published_area_um2', 'fncacti_area_um2', 'ratio', 'error_percent'])
        writer.writeheader()
        writer.writerows({key:r[key] for key in writer.fieldnames} for r in valid)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sram-root', type=Path, default=Path('/home/ubuntu/asap7_pdk/asap7_sram_0p0'))
    parser.add_argument('--out', type=Path, default=REPO/'build/fncacti/asap7-comparison')
    parser.add_argument('--binary', type=Path, default=DEFAULT_SOURCE/'cacti')
    parser.add_argument('--template', type=Path, default=DEFAULT_SOURCE/'configs/2MB_fin.cfg')
    args = parser.parse_args()
    summary = compare(args.sram_root.resolve(), args.out.resolve(), args.binary.resolve(), args.template.resolve())
    print(json.dumps(summary.get('statistics', {}), indent=2))
    if summary['status'] != 'complete':
        parser.exit(2, 'Comparison incomplete; inspect comparison.json\n')


if __name__ == '__main__':
    main()
