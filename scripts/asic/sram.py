"""Decode Lotus XRAM requirements and choose analytical macro geometries.

The allocator is our Python implementation of a MacroCompiler-style search,
with Lotus port/mask normalization. It emits model inputs, not SRAM hardware.
"""
import hashlib
import json
import copy
import math
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MODES = {0: "NO_CHANGE", 1: "WRITE_FIRST", 2: "READ_FIRST", 3: "WRITE_ONLY", 4: "READ_ONLY"}
SOURCES = {
    "core_dCache_dataArray": ("lotus/core/DCache.ms", "XRAM2BE#"),
    "core_iCache_dataArray": ("lotus/core/ICache.ms", "XRAM2#"),
    "dataArray": ("lotus/l2Cache/L2CacheBank.bsv", "dataArray <- mkXRAM2BE"),
    "tagArray": ("lotus/l2Cache/L2CacheBank.bsv", ") tagArray <-"),
    "statusArray": ("lotus/l2Cache/L2CacheBank.bsv", ") statusArray <-"),
    "argsMemXram_0": ("lotus/taskUnit/TaskUnit.bsv", ") argsMemXram <-"),
    "argsMemXram_1": ("lotus/taskUnit/TaskUnit.bsv", ") argsMemXram <-"),
    "taskInfoMemXram": ("lotus/taskUnit/TaskUnit.bsv", ") taskInfoMemXram <-"),
    "firstArgIdxMem": ("lotus/taskUnit/TaskUnit.bsv", ") firstArgIdxMem <-"),
    "inEdgesArrivedMem": ("lotus/taskUnit/TaskUnit.bsv", ") inEdgesArrivedMem <-"),
    "numInEdgesMinusOneMem": ("lotus/taskUnit/TaskUnit.bsv", ") numInEdgesMinusOneMem <-"),
    "taskIsSkippableMem": ("lotus/taskUnit/TaskUnit.bsv", ") taskIsSkippableMem <-"),
    "l1_bitmap": ("lotus/taskUnit/PrioQueue.bsv", ") bitmap <-"),
    "l2_bitmap": ("lotus/taskUnit/PrioQueue.bsv", ") bitmap <-"),
    "l3_bitmap": ("lotus/taskUnit/PrioQueue.bsv", ") bitmap <-"),
    "edgeTable_edgeTable": ("lotus/tokenSender/TokenSender.bsv", ") edgeTable <-"),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def location(relative, needle):
    path = REPO / relative
    hits = [i for i, line in enumerate(path.read_text().splitlines(), 1) if needle in line]
    if len(hits) != 1:
        raise ValueError(f"Expected one source anchor for {relative}: {needle}; found {hits}")
    return dict(path=relative, line=hits[0], sha256=digest(path))


def logical_memory(ram, build):
    """Interpret one elaborated declaration; no allocation decisions here."""
    if ram['type'] not in {'XRAM1', 'XRAM2', 'XRAM2BE'}:
        raise ValueError(f"Unsupported memory {ram['type']}")
    p = ram['parameters']
    if p.get('LOG_RATIOB', 0) < 0:
        raise ValueError('Only nonnegative LOG_RATIOB is supported')
    ratio = 2 ** p.get('LOG_RATIOB', 0)
    if p['NUM_WORDS'] % ratio:
        raise ValueError('Asymmetric depth is not integral')
    ports = []
    specs = ([('A', p['MODE'], p['NUM_WORDS'], p['DATA_WIDTH'])]
             if ram['type'] == 'XRAM1' else
             [('A', p['MODEA'], p['NUM_WORDS'], p['DATA_WIDTH']),
              ('B', p['MODEB'], p['NUM_WORDS']//ratio, p['DATA_WIDTH']*ratio)])
    for name, mode, depth, width in specs:
        if mode not in MODES:
            raise ValueError(f'Unsupported SRAM mode: {mode}')
        role = 'R' if mode == 4 else 'W' if mode == 3 else 'RW'
        ports.append(dict(name=name, role=role, mode=MODES[mode], depth_words=depth,
            width_bits=width, write_granularity_bits=None if role == 'R' else p.get('CHUNK_SIZE', width)))
    raw = build/'hdl/bsv'/f"{ram['module']}.v"
    hits = [i for i, line in enumerate(raw.read_text().splitlines(), 1)
            if f"{ram['instance']}(" in line]
    if len(hits) != 1:
        raise ValueError(f"Ambiguous elaborated instance location: {ram['instance']}")
    logical = dict(**ram, ports=ports, source=dict(
        declaration=location(*SOURCES[ram['instance']]),
        verilog=dict(path=str(raw), line=hits[0])))
    validate_logical(logical)
    return logical


def validate_logical(logical):
    """Reject inputs for which regular lane/address decomposition is invalid."""
    def positive(value):
        return type(value) is int and value > 0
    if not positive(logical['raw_bits']) or not positive(logical['multiplicity']):
        raise ValueError('Logical capacity and multiplicity must be positive integers')
    ports = logical['ports']
    if not ports or len(ports) > 2:
        raise ValueError('Expected one or two logical SRAM ports')
    for port in ports:
        if port['role'] not in {'R', 'W', 'RW'}:
            raise ValueError(f"Unknown port role: {port['role']}")
        width, depth = port['width_bits'], port['depth_words']
        if not positive(width) or not positive(depth) or width*depth != logical['raw_bits']:
            raise ValueError('Every port must address the same positive logical capacity')
        granule = port['write_granularity_bits']
        if port['role'] == 'R':
            if granule is not None:
                raise ValueError('Read-only ports cannot have a write granularity')
        elif not positive(granule) or width % granule:
            raise ValueError('Write granularity must divide the port width')
    widest = max(p['width_bits'] for p in ports)
    if any(widest % p['width_bits'] for p in ports):
        raise ValueError('Port widths must divide the widest port for regular lane addressing')


def unresolved_record(logical):
    return dict(logical=logical,
        mapping=dict(status='unresolved', reason='Select an explicit allocation/model policy'),
        estimation=dict(status='not_run'))


def validate_sources(manifest):
    build = Path(manifest['source_build'])
    for module, expected in manifest['source_sha256'].items():
        raw = build/'hdl/bsv'/f'{module}.v'
        if digest(raw) != expected:
            raise ValueError(f'Stale manifest: {raw} changed; rerun prepare.py')
    for record in manifest['memory_inventory']:
        validate_logical(record['logical'])
        source = record['logical']['source']['declaration']
        if digest(REPO/source['path']) != source['sha256']:
            raise ValueError(f"Stale declaration: {source['path']} changed; rerun prepare.py")


def load_manifest(path):
    manifest = json.loads(path.read_text())
    if manifest.get('schema_version') != 2:
        raise ValueError('Expected manifest schema 2; rerun prepare.py to consolidate SRAM requirements')
    validate_sources(manifest)
    return manifest


def save_manifest(path, manifest):
    temporary = path.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(manifest, indent=2)+'\n')
    temporary.replace(path)


def validate_policy(policy):
    # This is an analytical candidate library, not a foundry macro catalog.
    required = dict(technology='fncacti_14nm_devices_7nm_asap7_wires',
        allocation='macrocompiler_default', candidate_library='analytical_unmasked',
        objective='minimum_area', voltage_v=0.7, temperature_k=300)
    if not isinstance(policy, dict) or any(policy.get(k) != v for k, v in required.items()):
        raise ValueError(f'Unsupported policy; expected current mapping fields: {required}')
    dimensions = {'candidate_width_bits', 'candidate_depth_words'}
    if set(policy) != set(required) | dimensions:
        raise ValueError('Policy must specify candidate_width_bits and candidate_depth_words, with no unknown fields')
    for key in dimensions:
        values = policy[key]
        if (not isinstance(values, list) or not values
                or any(type(v) is not int or v <= 0 for v in values)
                or len(values) != len(set(values))):
            raise ValueError(f'{key} must be a nonempty list of distinct positive integers')
    if any(w % 8 for w in policy['candidate_width_bits']):
        raise ValueError('FN-CACTI candidate widths must be byte-aligned (at least eight bits)')
    if any(d < 2 or d & (d-1) for d in policy['candidate_depth_words']):
        raise ValueError('Candidate depths must be powers of two, at least two words')


def default_metric(requested_bits, allocated_bits, macro_count):
    """MacroCompiler DefaultMetric for our unmasked candidate macros.

    Capacity waste fraction + 0.05 per macro, per logical instance. The
    upstream 0.001 penalty for an unmasked target on a masked macro is zero
    here: FN-CACTI candidates have no native mask support. Mask/asymmetry
    boundaries are accounted for by the actual slice and bank counts.
    Reference: ucb-bar/barstools, CostMetric.scala, object DefaultMetric.
    """
    return (allocated_bits-requested_bits)/requested_bits + 0.05*macro_count


def allocate(logical, policy):
    """Search repeated geometries with MacroCompiler's default cost formula.

    First normalize Lotus's port-word/mask boundaries. Within each boundary,
    split into candidate-width slices, including a partially used final slice.
    Repeat one chosen geometry in width and depth, never mix macro types.
    This ports the selection algorithm, not the FIRRTL wrapper generator.
    """
    validate_policy(policy)
    validate_logical(logical)
    ports = logical['ports']
    widest = max(p['width_bits'] for p in ports)
    granules = [p['width_bits'] for p in ports]
    granules += [p['write_granularity_bits'] for p in ports if p['role'] != 'R']
    boundary = math.gcd(*granules)
    row_depth = logical['raw_bits'] // widest
    candidates = []
    for width in sorted(policy['candidate_width_bits']):
        slices = (widest//boundary) * ((boundary+width-1)//width)
        for depth in sorted(policy['candidate_depth_words']):
            if depth*width < 64*8:
                continue  # Installed FN-CACTI minimum capacity per UCA bank.
            banks = (row_depth+depth-1)//depth
            count = banks*slices
            allocated = count*depth*width
            candidates.append(dict(depth_words=depth, width_bits=width,
                depth_banks=banks, width_slices=slices, macros_per_instance=count,
                allocated_bits=allocated,
                cost=default_metric(logical['raw_bits'], allocated, count)))
    if not candidates:
        raise ValueError('Candidate library contains no geometry meeting the 64-byte minimum')
    # Explicit tie-breaks make the mapping independent of JSON list ordering.
    chosen = min(candidates, key=lambda c: (c['cost'], c['macros_per_instance'],
                 c['allocated_bits'], c['width_bits'], c['depth_words']))
    width, depth = chosen['width_bits'], chosen['depth_words']
    bit_slices = [dict(lsb=start+offset, msb=start+min(offset+width, boundary)-1)
                  for start in range(0, widest, boundary)
                  for offset in range(0, boundary, width)]
    if sum(s['msb']-s['lsb']+1 for s in bit_slices) * row_depth != logical['raw_bits']:
        raise ValueError('Slice decomposition does not preserve logical capacity')
    counts = {key: sum(p['role'] == role for p in ports)
              for key, role in [('read_write', 'RW'), ('exclusive_read', 'R'), ('exclusive_write', 'W')]}
    geometry = dict(depth_words=depth, width_bits=width, ports=counts, uca_banks=1)
    identity = hashlib.sha256(json.dumps(geometry, sort_keys=True).encode()).hexdigest()[:12]
    macro = dict(id=f'sram_{depth}x{width}_{identity}', **geometry,
        depth_banks=chosen['depth_banks'], width_slices=chosen['width_slices'],
        macros_per_instance=chosen['macros_per_instance'],
        total_macros=chosen['macros_per_instance']*logical['multiplicity'])
    allocated = chosen['allocated_bits']
    return dict(status='mapped', macros=[macro],
        logical_row_depth_words=row_depth, independent_boundary_bits=boundary,
        bit_slices=bit_slices,
        allocated_bits_per_instance=allocated,
        padding_bits_per_instance=allocated-logical['raw_bits'],
        selection=dict(metric='MacroCompiler DefaultMetric (unmasked candidates)',
            cost=chosen['cost'], wasted_fraction=(allocated-logical['raw_bits'])/logical['raw_bits'],
            instance_penalty=0.05*chosen['macros_per_instance'], mask_penalty=0,
            evaluated_candidates=len(candidates),
            tie_break='cost, instance count, allocated bits, width, depth',
            scope='One repeated geometry per logical RAM; Lotus mask/asymmetric-port normalization precedes search'),
        port_addressing=[dict(port=p['name'],
            slices_per_access=(p['width_bits']//boundary)*((boundary+width-1)//width),
            lane_groups=widest//p['width_bits'],
            rule='group = address % lane_groups; row = address // lane_groups; '
                 'wide-word bit = group * port width + port bit; locate in bit_slices; '
                 'macro bit = wide-word bit - slice lsb; '
                 'depth bank = row // macro depth; macro address = row % macro depth') for p in ports],
        decision='Search the explicit analytical width/depth grid. Split on port-word/write-mask boundaries '
                 'and at candidate width; allow partially used final slices. Minimize wasted fraction + 0.05 per macro.',
        external_adapters='Address/lane selection, output muxes, mask enables and any bypass/latency/initialization '
                          'logic are not generated or included in modeled macro area')


def configure(manifest, policy):
    validate_sources(manifest)
    validate_policy(policy)
    changed = manifest.get('sram_model', {}).get('policy') != policy
    for record in manifest['memory_inventory']:
        mapping = allocate(record['logical'], policy)
        if changed or record['mapping'] != mapping:
            record['estimation'] = dict(status='not_run')
        record['mapping'] = mapping
    if changed:
        manifest['sram_model'] = dict(status='configured', policy=copy.deepcopy(policy), runs={})
    else:
        manifest['sram_model'].setdefault('runs', {})
    manifest['sram_model']['technology_note'] = (
        'Uncalibrated 14 nm FinFET devices with 7 nm ASAP7 wires; do not add this area '
        'to ASAP7 standard-cell area as a calibrated 7 nm total.')
    update_totals(manifest)


def unique_macros(manifest):
    macros = {}
    for record in manifest['memory_inventory']:
        if record['mapping']['status'] != 'mapped':
            raise ValueError('Unresolved macro allocation; choose a policy first')
        for macro in record['mapping']['macros']:
            spec = {k: macro[k] for k in ('depth_words', 'width_bits', 'ports', 'uca_banks')}
            if macro['id'] in macros and macros[macro['id']] != spec:
                raise ValueError(f"Conflicting macro identity: {macro['id']}")
            macros[macro['id']] = spec
    return macros


def update_totals(manifest):
    records = manifest['memory_inventory']
    totals = dict(logical_instances=sum(r['logical']['multiplicity'] for r in records),
        logical_bits=sum(r['logical']['raw_bits']*r['logical']['multiplicity'] for r in records))
    if all(r['mapping']['status'] == 'mapped' for r in records):
        totals.update(macro_instances=sum(m['total_macros'] for r in records for m in r['mapping']['macros']),
            allocated_bits=sum(r['mapping']['allocated_bits_per_instance']*r['logical']['multiplicity'] for r in records))
        totals['padding_bits'] = totals['allocated_bits']-totals['logical_bits']
    if records and all(r['estimation']['status'] == 'complete' for r in records):
        totals['uncalibrated_sram_area_um2'] = sum(r['estimation']['area_um2_all_instances'] for r in records)
    manifest['sram_model']['totals'] = totals
