"""Area accounting must reject lost logical SRAMs and unmapped hardware."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import yaml
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hammer_syn import summarize, synthesis_entry, synthesis_inputs, validate_synthesis_inputs

YOSYS = shutil.which('yosys') or '/home/ubuntu/yosys-062/yosys'


class HammerReportTests(unittest.TestCase):
    def setUp(self):
        self.counts = {'XRAM2': 2, 'BUF': 10}

    def report(self, log='ABC: Area = 0.1 Delay = 995.4 ps'):
        return summarize(self.counts, {'XRAM2': 2}, {'BUF'}, 1.0, log, 1.0)

    def test_only_standard_cells_contribute_area(self):
        r = self.report()
        self.assertAlmostEqual(r['logic_area_um2'], 1.0)
        self.assertEqual(r['total_logical_srams'], 2)
        self.assertFalse(r['timing_closure_verified'])
        self.assertEqual(r['abc_delay_target_ps'], 1000)
        self.assertNotIn('total_cell_area_um2', r)
        self.assertNotIn('sram_macro_area_um2', r)

    def test_rejects_lost_sram(self):
        self.counts['XRAM2'] = 1
        with self.assertRaisesRegex(ValueError, 'SRAM counts changed'):
            self.report()

    def test_rejects_unmapped_hardware(self):
        self.counts['$and'] = 1
        with self.assertRaisesRegex(ValueError, 'Unmapped hardware'):
            self.report()

    def test_rejects_missing_timing_report(self):
        with self.assertRaisesRegex(ValueError, 'No ABC delay reports'):
            self.report(log='')

    def test_rejects_invalid_yosys_area(self):
        for area in (0, -1, float('nan'), float('inf')):
            with self.assertRaisesRegex(ValueError, 'positive finite logic area'):
                summarize(self.counts, {'XRAM2': 2}, {'BUF'}, area,
                          'ABC: Delay = 10 ps', 1.0)

    def test_changed_rtl_or_constraints_cannot_reuse_logic_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            for name in ('source.v', 'synthesis_input.v', 'first.lib', 'second.lib', 'latch_map.v'):
                (out/name).write_text('original')
            config = {'vlsi.technology.extra_libraries':[
                {'library':{'nldm_liberty_file':str(out/name)}} for name in ('first.lib','second.lib')],
                'synthesis.yosys.latch_map_file':str(out/'latch_map.v')}
            (out/'design.yml').write_text(yaml.safe_dump(config))
            manifest = dict(source_sha256={'mkTile': 'raw-source-hash'},
                            synthesis_files=[str(out/'source.v')])
            provenance = dict(synthesis_inputs=synthesis_inputs(out, manifest))
            validate_synthesis_inputs(out, manifest, provenance)
            for name in ('source.v', 'first.lib', 'second.lib', 'latch_map.v'):
                (out/name).write_text('changed')
                with self.assertRaisesRegex(ValueError, 'Synthesis inputs changed'):
                    validate_synthesis_inputs(out, manifest, provenance)
                (out/name).write_text('original')
            config['vlsi.inputs.clocks'] = [{'name':'CLK','period':'2 ns'}]
            (out/'design.yml').write_text(yaml.safe_dump(config))
            with self.assertRaisesRegex(ValueError, 'Synthesis inputs changed'):
                validate_synthesis_inputs(out, manifest, provenance)

    @unittest.skipUnless(Path(YOSYS).is_file(), 'Yosys is required for the direct-input integration check')
    def test_direct_input_preserves_defines_and_blackboxes(self):
        with tempfile.TemporaryDirectory(prefix='asic input ') as tmp:
            out = Path(tmp)
            definitions = out/'definitions.sv'
            definitions.write_text('''`define WORD_BITS 8
(* blackbox *) module XRAM(input [`WORD_BITS-1:0] d, output [`WORD_BITS-1:0] q);
endmodule
''')
            top = out/'top.sv'
            top.write_text('''module top(input clk, input [`WORD_BITS-1:0] d,
output reg [`WORD_BITS-1:0] q, output [`WORD_BITS-1:0] z);
`ifndef SYNTHESIS
  simulation_only_syntax_must_not_be_parsed !
`endif
`ifndef BSV_NO_INITIAL_BLOCKS
  initial q = 8'hff;
`endif
always @(posedge clk) q <= d;
(* keep *) XRAM ram(.d(q), .q(z));
endmodule
''')
            entry = out/'synthesis_input.v'
            entry.write_text(synthesis_entry([definitions, top]))
            script = out/'test.ys'
            script.write_text(f'read_verilog -sv {json.dumps(str(entry))}\n'
                              'hierarchy -check -top top\nproc\ncheck -assert\n'
                              f'write_json {json.dumps(str(out/"result.json"))}\n')
            result = subprocess.run([YOSYS, '-Q', '-T', '-s', str(script)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            modules = json.loads((out/'result.json').read_text())['modules']
            self.assertEqual(modules['top']['cells']['ram']['type'], 'XRAM')
            self.assertEqual(len(modules['top']['ports']['q']['bits']), 8)
            self.assertTrue(int(modules['XRAM']['attributes']['blackbox'], 2))
            self.assertFalse(any('init' in n['attributes'] for n in modules['top']['netnames'].values()))



if __name__ == '__main__':
    unittest.main()
