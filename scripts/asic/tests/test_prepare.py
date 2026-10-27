"""Check area-only preparation, hierarchy counting, and provenance rejection."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sram import load_manifest, configure, save_manifest
from prepare import SUPPORT, prepare

YOSYS = shutil.which('yosys') or '/home/ubuntu/yosys-062/yosys'


class PrepareTests(unittest.TestCase):
    def test_area_only_artifacts_and_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            raw = root/'build/hdl/bsv'
            raw.mkdir(parents=True)
            (raw/'mkTile.v').write_text('''module mkTile(CLK, RST_N);
  input CLK;
  input RST_N;
  mkCore core0(.CLK(CLK), .RST_N(RST_N));
  mkCore core1(.CLK(CLK), .RST_N(RST_N));
endmodule
''')
            source = raw/'mkCore.v'
            source.write_text('''module mkCore(CLK, RST_N);
  input CLK;
  input RST_N;
  XRAM2 #(.ADDR_WIDTH(10), .DATA_WIDTH(32), .MODEA(4), .MODEB(3),
          .LOG_RATIOB(1), .READ_LATENCY(1)) core_iCache_dataArray(.clk(CLK));
  XRegFile #(.ADDR_WIDTH(5), .DATA_WIDTH(32)) regs(.clk(CLK), .rstn(RST_N));
  RegWithReset #(.WIDTH(32)) state(.clk(CLK));
endmodule
''')
            out = root/'out'
            manifest = prepare(root/'build', out, root/'unused_bsc_lib')
            self.assertEqual(set(manifest), {'source_build', 'source_sha256',
                                            'memory_inventory', 'synthesis_files', 'schema_version', 'sram_model'})
            self.assertEqual(len(manifest['memory_inventory']), 1)
            ram = manifest['memory_inventory'][0]['logical']
            self.assertEqual(ram['multiplicity'], 2)
            self.assertEqual(ram['raw_bits'], 32768)
            rtl = (out/'rtl/mkCore.v').read_text()
            self.assertIn('(* keep *) XRAM2', rtl)
            self.assertIn('state(.clk(CLK))', rtl)
            self.assertNotIn('.rst_n(', rtl)
            self.assertIn('XRegFile', rtl)
            self.assertNotIn('ASIC_MEM_RST_N', rtl)
            self.assertFalse((out/'rtl/mkTileAsic.v').exists())
            self.assertFalse((out/'filelist.f').exists())
            self.assertFalse((out/'rtl/support.sv').exists())
            self.assertTrue((out/'rtl/XRegFile.sv').is_file())
            self.assertTrue((out/'rtl/RegWithReset.sv').is_file())
            self.assertFalse((out/'rtl/CreditFIFO.sv').exists())
            requirements = load_manifest(out/'manifest.json')
            ports = requirements['memory_inventory'][0]['logical']['ports']
            self.assertEqual([(p['role'], p['depth_words'], p['width_bits']) for p in ports],
                             [('R', 1024, 32), ('W', 512, 64)])
            self.assertEqual(requirements['sram_model']['totals']['logical_bits'], 65536)
            policy = json.loads((Path(__file__).resolve().parents[1]/'fncacti_policy.json').read_text())
            configure(requirements, policy)
            save_manifest(out/'manifest.json', requirements)
            # Refreshing an old package removes the duplicate module definitions
            # and invalidates its logic report, without discarding SRAM estimates.
            requirements['synthesis_files'].append(str(out/'rtl/support.sv'))
            (out/'rtl/support.sv').write_text('// retired replacement')
            (out/'hammer_summary.json').write_text('{}')
            save_manifest(out/'manifest.json', requirements)
            refreshed = prepare(root/'build', out, root/'unused_bsc_lib')
            self.assertFalse((out/'rtl/support.sv').exists())
            self.assertFalse((out/'hammer_summary.json').exists())
            self.assertEqual(refreshed['memory_inventory'], requirements['memory_inventory'])
            self.assertEqual(refreshed['sram_model'], requirements['sram_model'])
            # Refuse estimates against a source that no longer matches preparation.
            source.write_text(source.read_text()+'\n// new elaboration\n')
            with self.assertRaisesRegex(ValueError, 'Stale manifest'):
                load_manifest(out/'manifest.json')
            refreshed = prepare(root/'build', out, root/'unused_bsc_lib')
            self.assertEqual(refreshed['sram_model']['status'], 'unconfigured')
            self.assertEqual(refreshed['memory_inventory'][0]['mapping']['status'], 'unresolved')

    def test_does_not_mix_retired_and_current_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out/'manifest.json').write_text(json.dumps({'files': []}))
            with self.assertRaisesRegex(ValueError, 'retired ASIC flow'):
                prepare(out/'build', out, out/'lib')


@unittest.skipUnless(Path(YOSYS).is_file(), 'Yosys is required for RTL policy checks')
class OriginalRTLTests(unittest.TestCase):
    def run_yosys(self, out, script):
        path = out/'check.ys'
        path.write_text(script)
        result = subprocess.run([YOSYS, '-Q', '-T', '-s', str(path)],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

    def test_initialization_is_disabled_only_when_requested(self):
        # SYNTHESIS alone (as in FPGA synthesis) must retain power-up values.
        for name, source in SUPPORT.items():
            for disable_init in (False, True):
                with self.subTest(module=name, disable_init=disable_init), tempfile.TemporaryDirectory() as tmp:
                    out = Path(tmp)
                    defines = '-D SYNTHESIS' + (' -D BSV_NO_INITIAL_BLOCKS' if disable_init else '')
                    self.run_yosys(out, f'read_verilog -sv {defines} {json.dumps(str(source))}\n'
                                   f'hierarchy -check -top {name}\nproc\n'
                                   f'write_json {json.dumps(str(out/"rtl.json"))}\n')
                    module = json.loads((out/'rtl.json').read_text())['modules'][name]
                    initialized = (any('init' in n['attributes'] for n in module['netnames'].values())
                                   or any(c['type'].startswith('$meminit') for c in module['cells'].values()))
                    self.assertEqual(initialized, not disable_init)
                    self.assertNotIn('rst_n', module['ports'])

    def test_xregfile_reset_gates_writes_without_clearing_storage(self):
        # Write 53, assert reset while attempting to write 166, then prove the
        # stored value remains 53 on all five read ports, for both polarities.
        for positive in (False, True):
            with self.subTest(positive_reset=positive), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp)
                defines = '-D SYNTHESIS -D BSV_NO_INITIAL_BLOCKS'
                if positive:
                    defines += ' -D BSV_POSITIVE_RESET'
                reads = ' '.join(f'-set rdAddr{i} 0 -prove rdData{i} 53' for i in range(1, 6))
                self.run_yosys(out,
                    f'read_verilog -sv {defines} {json.dumps(str(SUPPORT["XRegFile"]))}\n'
                    'hierarchy -check -top XRegFile\nproc\nmemory_map\nopt\n'
                    f'sat -seq 3 -set wrEn 1 -set wrAddr 0 {reads} '
                    f'-set-at 1 rstn {int(not positive)} -set-at 1 wrData 53 '
                    f'-set-at 2 rstn {int(positive)} -set-at 2 wrData 166 '
                    '-prove-skip 2 -verify\n')

    def test_regwithreset_keeps_functional_reset_priority(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            self.run_yosys(out,
                'read_verilog -sv -D SYNTHESIS -D BSV_NO_INITIAL_BLOCKS '
                f'{json.dumps(str(SUPPORT["RegWithReset"]))}\n'
                'hierarchy -check -top RegWithReset\nproc\nopt\n'
                'sat -seq 3 -set wrData 1 -set-at 1 reset 1 -set-at 1 wrEn 1 '
                '-set-at 2 reset 0 -set-at 2 wrEn 0 -prove data 0 -prove-skip 1 -verify\n')


if __name__ == '__main__':
    unittest.main()
