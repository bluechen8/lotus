"""Check allocation, model inputs, accounting, and failed-result rejection."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sram import allocate, default_metric
from fncacti import generate_config, parse_result, estimate_memories, run_models, execute_model

HERE = Path(__file__).resolve().parents[1]
POLICY = json.loads((HERE/'fncacti_policy.json').read_text())


def memory(depth, width, roles=('RW', 'RW'), ratio=1, chunk=None, count=1):
    ports = []
    for index, role in enumerate(roles):
        scale = ratio if index == 1 else 1
        ports.append(dict(name='AB'[index], role=role, width_bits=width*scale,
            depth_words=depth//scale, write_granularity_bits=None if role == 'R' else chunk or width*scale))
    return dict(raw_bits=depth*width, multiplicity=count, ports=ports)


class AllocationTests(unittest.TestCase):
    def test_asymmetric_ports_conserve_storage_and_roles(self):
        m = allocate(memory(1024, 32, ('R', 'W'), ratio=2, count=4), POLICY)
        macro = m['macros'][0]
        self.assertEqual((macro['depth_words'], macro['width_bits'], macro['width_slices']), (512, 32, 2))
        self.assertEqual(macro['total_macros'], 8)
        self.assertEqual(macro['ports'], dict(read_write=0, exclusive_read=1, exclusive_write=1))
        self.assertEqual(m['padding_bits_per_instance'], 0)
        self.assertEqual([p['lane_groups'] for p in m['port_addressing']], [2, 1])

    def test_masks_preserve_independent_write_lanes(self):
        m = allocate(memory(8192, 64, chunk=8, count=2), POLICY)
        macro = m['macros'][0]
        self.assertEqual((macro['depth_words'], macro['width_bits'], macro['macros_per_instance']), (8192, 8, 8))
        self.assertEqual(macro['total_macros'], 16)
        self.assertEqual(m['allocated_bits_per_instance'], 8192*64)

    def test_tiny_asymmetric_bitmap_reports_padding(self):
        m = allocate(memory(128, 1, ('W', 'RW'), ratio=16), POLICY)
        macro = m['macros'][0]
        self.assertEqual((macro['depth_words'], macro['width_bits'], macro['macros_per_instance']), (64, 8, 16))
        self.assertEqual(m['padding_bits_per_instance'], 8192-128)
        self.assertEqual(macro['ports'], dict(read_write=1, exclusive_read=0, exclusive_write=1))

    def test_candidate_library_can_force_depth_and_width_splitting(self):
        p = dict(POLICY, candidate_depth_words=[2048], candidate_width_bits=[32])
        macro = allocate(memory(8192, 64, count=2), p)['macros'][0]
        self.assertEqual((macro['depth_banks'], macro['width_slices'], macro['total_macros']), (4, 2, 16))

    def test_unsupported_technology_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported policy'):
            allocate(memory(1024, 32), dict(POLICY, technology='asap7_calibrated'))

    def test_invalid_limits_and_port_geometry_rejected(self):
        for widths in (None, [], [0], [True], [18], [8, 8]):
            with self.assertRaises(ValueError):
                allocate(memory(1024, 32), dict(POLICY, candidate_width_bits=widths))
        for depths in (None, [], [1], [3], [True]):
            with self.assertRaises(ValueError):
                allocate(memory(1024, 32), dict(POLICY, candidate_depth_words=depths))
        with self.assertRaisesRegex(ValueError, '64-byte minimum'):
            allocate(memory(1024, 32), dict(POLICY, candidate_depth_words=[2], candidate_width_bits=[8]))
        with self.assertRaisesRegex(ValueError, 'granularity'):
            allocate(memory(1024, 32, chunk=3), POLICY)
        with self.assertRaisesRegex(ValueError, 'same positive logical capacity'):
            allocate(memory(1025, 32, ratio=2), POLICY)

    def test_address_mapping_preserves_every_logical_bit(self):
        # Asymmetric ports, byte masks, and depth banking together. Compare
        # physical locations of all bits accessible through either port.
        logical = memory(512, 16, ratio=2, chunk=8)
        mapped = allocate(logical, dict(POLICY, candidate_depth_words=[64]))
        macro = mapped['macros'][0]
        locations = []
        for port, addressing in zip(logical['ports'], mapped['port_addressing']):
            bits = []
            for address in range(port['depth_words']):
                group = address % addressing['lane_groups']
                row = address // addressing['lane_groups']
                for bit in range(port['width_bits']):
                    wide_bit = group*port['width_bits'] + bit
                    lane, piece = next((i,s) for i,s in enumerate(mapped['bit_slices'])
                                       if s['lsb'] <= wide_bit <= s['msb'])
                    bits.append((row//macro['depth_words'], lane, row % macro['depth_words'],
                                 wide_bit-piece['lsb']))
            self.assertEqual(len(bits), len(set(bits)))
            locations.append(bits)
        self.assertEqual(locations[0], locations[1])

    def test_69_and_72_bit_records_use_72_bit_macros(self):
        for width in (69, 72):
            mapped = allocate(memory(4096, width, roles=('RW',)), POLICY)
            macro = mapped['macros'][0]
            self.assertEqual((macro['width_bits'], macro['depth_words'], macro['macros_per_instance']),
                             (72, 4096, 1))
            self.assertEqual(mapped['padding_bits_per_instance'], 4096*(72-width))

    def test_partial_final_slice_and_one_repeated_geometry(self):
        p = dict(POLICY, candidate_width_bits=[32, 64], candidate_depth_words=[4096])
        mapped = allocate(memory(4096, 69, roles=('RW',)), p)
        self.assertEqual(len(mapped['macros']), 1)
        self.assertEqual(mapped['macros'][0]['width_bits'], 32)
        self.assertEqual(mapped['bit_slices'], [dict(lsb=0, msb=31), dict(lsb=32, msb=63), dict(lsb=64, msb=68)])

    def test_metric_matches_upstream_examples_and_prefers_fewer_macros(self):
        # One 72-wide macro vs nine 8-wide macros have the same capacity.
        self.assertAlmostEqual(default_metric(69*4096, 72*4096, 1), 3/69+0.05)
        self.assertAlmostEqual(default_metric(69*4096, 72*4096, 9), 3/69+0.45)
        mapped = allocate(memory(4096, 69), dict(POLICY, candidate_width_bits=[8, 72]))
        self.assertEqual(mapped['macros'][0]['width_bits'], 72)
        self.assertAlmostEqual(mapped['selection']['cost'], 3/69+0.05)

    def test_depth_search_can_trade_padding_for_instance_count(self):
        # Five 64-deep macros waste less than one 512-deep macro, and win.
        mapped = allocate(memory(257, 8), dict(POLICY,
                          candidate_width_bits=[8], candidate_depth_words=[64, 512]))
        self.assertEqual(mapped['macros'][0]['depth_banks'], 5)
        self.assertEqual(mapped['macros'][0]['depth_words'], 64)

    def test_ties_are_independent_of_candidate_order(self):
        logical = memory(128, 1, ('W', 'RW'), ratio=16)
        reverse = dict(POLICY, candidate_width_bits=POLICY['candidate_width_bits'][::-1],
                       candidate_depth_words=POLICY['candidate_depth_words'][::-1])
        self.assertEqual(allocate(logical, POLICY), allocate(logical, reverse))

    def test_partial_slices_do_not_cross_write_mask_or_port_boundaries(self):
        logical = memory(256, 36, ratio=2, chunk=18)
        mapped = allocate(logical, dict(POLICY, candidate_width_bits=[8]))
        for piece in mapped['bit_slices']:
            self.assertEqual(piece['lsb']//18, piece['msb']//18)
            self.assertLessEqual(piece['msb']-piece['lsb']+1, 8)
        self.assertEqual([p['slices_per_access'] for p in mapped['port_addressing']], [6, 12])

    def test_counts_multiplied_once_and_no_partial_total(self):
        logical = memory(1024, 32, count=4)
        mapping = allocate(logical, POLICY)
        key = mapping['macros'][0]['id']
        m = dict(memory_inventory=[dict(logical=logical, mapping=mapping)],
                 sram_model=dict(runs={key:dict(status='complete', result=dict(area_um2=10))}))
        estimate_memories(m)
        self.assertEqual(m['memory_inventory'][0]['estimation']['area_um2_all_instances'], 40)
        self.assertEqual(m['sram_model']['totals']['uncalibrated_sram_area_um2'], 40)
        m['sram_model']['runs'][key]['status'] = 'failed'
        estimate_memories(m)
        self.assertNotIn('uncalibrated_sram_area_um2', m['sram_model']['totals'])


class ModelIOTests(unittest.TestCase):
    def setUp(self):
        self.macro = dict(depth_words=1024, width_bits=8, uca_banks=1,
            ports=dict(read_write=0, exclusive_read=1, exclusive_write=1))
        self.output = '''Cache Parameters:
    Total cache size (bytes): 1024
    Number of banks: 1
    Associativity: direct mapped
    Block size (bytes): 1
    Read/write Ports: 0
    Read ports: 1
    Write ports: 1
    Technology size (nm): 14
    Access time (ns): 1.2;
    Cycle time (ns): 0.3;
    Cache height x width (mm): 0.1 x 0.2;
    Cache area (mm2): 0.02;
    Best Ndwl : 2;
    Best Ndbl : 2;
    Best Nspd : 1;
    Best Ndcm : 1;
    Best Ndsam L1 : 1;
    Best Ndsam L2 : 1;
'''

    def test_units_and_organization(self):
        r = parse_result(self.output, self.macro)
        self.assertEqual(r['area_um2'], 20000)
        self.assertEqual(r['physical_dimensions_um'], dict(height=100, width=200))
        self.assertEqual(r['organization']['Ndwl'], 2)

    def test_reject_wrong_configuration_and_invalid_area(self):
        for bad in [self.output.replace('Read ports: 1', 'Read ports: 0'),
                    self.output+'ERROR: no cache organizations met optimization criteria\n',
                    self.output.replace('0.02;', 'nan;'),
                    self.output.replace('0.02;', '0.04;'),
                    self.output.replace('0.02;', '0.02; 0.02;')]:
            with self.assertRaises(ValueError):
                parse_result(bad, self.macro)

    def test_generator_fails_on_missing_template_settings(self):
        with self.assertRaisesRegex(ValueError, 'Template must contain'):
            generate_config('-size 1024\n', self.macro, POLICY)

    def test_generator_rejects_non_byte_width_instead_of_truncating(self):
        with self.assertRaisesRegex(ValueError, 'whole bytes'):
            generate_config('', dict(self.macro, width_bits=69), POLICY)

    def test_incomplete_cache_metadata_is_not_reused(self):
        with tempfile.TemporaryDirectory() as tmp, patch('fncacti.generate_config', return_value='config'):
            root = Path(tmp)
            binary, template = root/'cacti', root/'template.cfg'
            binary.write_text('unused executable')
            template.write_text('unused template')
            run = execute_model('macro', self.macro, POLICY, binary, template, root, prepare_only=True)
            run['status'] = 'complete'
            del run['stdout']
            fresh = execute_model('macro', self.macro, POLICY, binary, template, root,
                                  previous=run, prepare_only=True)
            self.assertEqual(fresh['status'], 'prepared')
            self.assertNotIn('result', fresh)

    def test_missing_binary_marks_manifest_failed_without_total(self):
        logical = memory(1024, 8)
        manifest = dict(memory_inventory=[dict(logical=logical, mapping=allocate(logical, POLICY),
                                               estimation=dict(status='not_run'))],
                        sram_model=dict(runs={}))
        with tempfile.TemporaryDirectory() as tmp, patch('fncacti.load_manifest', return_value=manifest), \
                patch('fncacti.configure'):
            path = Path(tmp)/'manifest.json'
            template = Path(tmp)/'input.cfg'
            template.write_text('unused')
            with self.assertRaisesRegex(ValueError, 'No complete SRAM total'):
                run_models(path, POLICY, Path(tmp)/'missing-cacti', template)
            saved = json.loads(path.read_text())
            self.assertEqual(saved['sram_model']['status'], 'failed')
            self.assertNotIn('uncalibrated_sram_area_um2', saved['sram_model']['totals'])


if __name__ == '__main__':
    unittest.main()
