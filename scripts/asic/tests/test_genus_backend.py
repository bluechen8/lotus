"""Genus accounting and opt-in licensed Hammer integration.

Set LOTUS_GENUS_TEST_CONFIG to a prepared Genus design.yml for the integration
test. It uses real libraries and an independent temporary run directory.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from hammer_syn import genus_stats, summarize, synthesis_inputs, validate_synthesis_inputs
from sram import digest


class GenusReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name)
        self.run = self.out/'obj/syn-rundir'
        (self.run/'reports').mkdir(parents=True)
        (self.run/'reports/lotus_timing.rpt').write_text('No paths found.\n')
        self.mapped = self.run/'smoke.mapped.v'
        self.mapped.write_text('module smoke; BUF g0(); endmodule\n')
        self.lib = self.out/'test.lib'
        self.lib.write_text('library(test) { cell(BUF) { area : 0.5; } }')

    def stats(self, rows):
        (self.run/'lotus_cells.tsv').write_text('instance\tcell\tarea\tblackbox\n' + rows)
        paths = (self.mapped, self.run/'lotus_cells.tsv', self.run/'reports/lotus_timing.rpt')
        if all(p.is_file() for p in paths):
            (self.run/'lotus_artifacts.sha256').write_text(''.join(digest(p)+'\n' for p in paths))
        return genus_stats(self.out, [self.lib], self.mapped)

    def test_counts_parameterized_srams_excludes_their_area_and_has_no_abc_fields(self):
        counts, cells, area = self.stats('g0\tBUF\t0.5\tfalse\n'
            'child/ram\tXRAM2_ADDR_WIDTH8_DATA_WIDTH16\t0\ttrue\n')
        report = summarize(counts, {'XRAM2': 1}, cells, area, '', 1, 'genus')
        self.assertEqual(report['logic_area_um2'], 0.5)
        self.assertEqual(report['total_logical_srams'], 1)
        self.assertFalse(any(k.startswith('abc_') for k in report))
        self.assertFalse(report['timing_closure_verified'])
        with self.assertRaisesRegex(ValueError, 'SRAM counts changed'):
            summarize(counts, {'XRAM2': 2}, cells, area, '', 1, 'genus')

    def test_rejects_unknown_cells_and_fake_srams(self):
        for row in ('g0\tCDN_flop\t0.5\tfalse\n', 'g0\tmissing\t0\ttrue\n',
                    'g0\tXRAM2_bad\t0\tfalse\n', 'g0\tXRAM20\t0\ttrue\n'):
            with self.assertRaisesRegex(ValueError, 'Unmapped hardware'):
                self.stats(row)

    def test_rejects_scaled_or_invalid_areas(self):
        for area in ('8', 'nan', 'inf', '-1'):
            with self.assertRaisesRegex(ValueError, 'area mismatch'):
                self.stats(f'g0\tBUF\t{area}\tfalse\n')

    def test_rejects_duplicate_instances_and_missing_reports(self):
        row = 'g0\tBUF\t0.5\tfalse\n'
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.stats(row + row)
        (self.run/'reports/lotus_timing.rpt').unlink()
        with self.assertRaisesRegex(ValueError, 'No Genus timing report'):
            self.stats(row)

    def test_rejects_changed_outputs_or_missing_fingerprints(self):
        self.stats('g0\tBUF\t0.5\tfalse\n')
        for path in (self.mapped, self.run/'lotus_cells.tsv', self.run/'reports/lotus_timing.rpt'):
            with self.subTest(path=path.name):
                original = path.read_text()
                path.write_text(original+'changed\n')
                with self.assertRaisesRegex(ValueError, 'Genus outputs changed'):
                    genus_stats(self.out, [self.lib], self.mapped)
                path.write_text(original)
        (self.run/'lotus_artifacts.sha256').unlink()
        with self.assertRaisesRegex(ValueError, 'lack recorded hashes'):
            genus_stats(self.out, [self.lib], self.mapped)

    def test_fingerprint_tracks_genus_without_yosys_latch_map(self):
        config = {'vlsi.core.synthesis_tool': 'hammer.synthesis.genus',
                  'vlsi.technology.extra_libraries': [
                      {'library': {'nldm_liberty_file': str(self.lib)}}]}
        (self.out/'design.yml').write_text(yaml.safe_dump(config))
        (self.out/'synthesis_input.v').write_text('module test; endmodule')
        manifest = {'synthesis_files': [], 'source_sha256': {}}
        inputs = synthesis_inputs(self.out, manifest)
        self.assertIn(str(HERE/'genus_driver.py'), inputs['files_sha256'])
        self.assertFalse(any('yosys' in p for p in inputs['files_sha256']))
        self.lib.write_text('changed')
        with self.assertRaisesRegex(ValueError, 'Synthesis inputs changed'):
            validate_synthesis_inputs(self.out, manifest, {'synthesis_inputs': inputs})


@unittest.skipUnless(os.environ.get('LOTUS_GENUS_TEST_CONFIG'),
                     'Set LOTUS_GENUS_TEST_CONFIG for licensed Hammer/Genus integration')
class GenusIntegrationTests(unittest.TestCase):
    def test_mapping_preserves_parameterized_and_unused_memories(self):
        config = yaml.safe_load(Path(os.environ['LOTUS_GENUS_TEST_CONFIG']).read_text())
        self.assertEqual(config['vlsi.core.synthesis_tool'], 'hammer.synthesis.genus')
        with tempfile.TemporaryDirectory(prefix='lotus-genus-') as tmp:
            out = Path(tmp)
            rtl = out/'smoke.sv'
            rtl.write_text('''
module smoke(input CLK, RST_N, en, input [7:0] a,b,
             output reg [7:0] q, qneg, output [7:0] r);
always @(posedge CLK) if (!RST_N) q <= 0; else if (en) q <= a+b;
always @(negedge CLK) if (en) qneg <= a^b;
XRAM1 #(.ADDR_WIDTH(8), .DATA_WIDTH(8)) ram0
  (.clk(CLK), .en(en), .we(en), .addr(a), .din(q), .dout(r));
XRAM1 #(.ADDR_WIDTH(4), .DATA_WIDTH(8)) unused
  (.clk(CLK), .en(en), .we(en), .addr(a[3:0]), .din(q), .dout());
XRAM2 #(.ADDR_WIDTH(8), .DATA_WIDTH(8)) ram2
  (.clk(CLK), .enA(en), .weA(en), .addrA(a), .dinA(q), .doutA(),
   .enB(en), .weB(en), .addrB(b), .dinB(qneg), .doutB());
XRAM2BE #(.ADDR_WIDTH(8), .DATA_WIDTH(16)) rambe
  (.clk(CLK), .enA(en), .weA({en,en}), .addrA(a), .dinA({q,q}), .doutA(),
   .enB(en), .weB({en,en}), .addrB(b), .dinB({qneg,qneg}), .doutB());
endmodule
''')
            config['synthesis.inputs.top_module'] = 'smoke'
            config['synthesis.inputs.input_files'] = [str(rtl), str(HERE/'rtl/memory_blackboxes.sv')]
            config['vlsi.inputs.clocks'] = [{'name': 'CLK', 'path': 'CLK', 'period': '1 ns'}]
            config['synthesis.genus.generate_only'] = False
            design = out/'design.yml'
            design.write_text(yaml.safe_dump(config))
            run = subprocess.run([sys.executable, str(HERE/'genus_driver.py'), '-p', str(design),
                '--obj_dir', str(out/'obj'), '-l', str(out/'hammer.log'), '-o', str(out/'outputs.json'), 'syn'],
                capture_output=True, text=True, timeout=300)
            self.assertEqual(run.returncode, 0, (run.stdout+run.stderr)[-5000:])
            self.assertNotRegex(run.stdout+run.stderr, r'(?m)^\s*(?:Error|Fatal)\s*:')
            libraries = [Path(item['library']['nldm_liberty_file'])
                         for item in config['vlsi.technology.extra_libraries']]
            outputs = json.loads((out/'outputs.json').read_text())
            mapped = Path(outputs['synthesis.outputs.output_files'][0])
            counts, cells, area = genus_stats(out, libraries, mapped)
            summary = summarize(counts, {'XRAM1': 2, 'XRAM2': 1, 'XRAM2BE': 1},
                                cells, area, run.stdout, 1, 'genus')
            self.assertGreater(summary['mapped_standard_cells'], 16)
            rundir = out/'obj/syn-rundir'
            self.assertIn('-period 1000', (rundir/'clock_constraints_fragment.sdc').read_text())
            self.assertNotIn('read_physical', (rundir/'syn.tcl').read_text())
            # A netlist edit must not silently reuse the native cell inventory.
            mapped.write_text(mapped.read_text()+'// changed after synthesis\n')
            with self.assertRaisesRegex(ValueError, 'Genus outputs changed'):
                genus_stats(out, libraries, mapped)


if __name__ == '__main__':
    unittest.main()
