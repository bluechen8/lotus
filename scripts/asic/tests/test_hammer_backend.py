"""Opt-in end-to-end Hammer mapping and sequential equivalence regression.

Set LOTUS_HAMMER_TEST_CONFIG to a prepared design.yml to supply real libraries
and the Yosys executable. The test uses an independent temporary output folder.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


CONFIG = os.environ.get('LOTUS_HAMMER_TEST_CONFIG')
RTL = '''module smoke(input CLK, RST_N, en, input [7:0] a,b,
                     output reg [7:0] q_reset_first, q_enable_first,
                     output reg [7:0] q_negative);
always @(posedge CLK)
  if (!RST_N) q_reset_first <= 0;
  else if (en) q_reset_first <= a + b;
always @(posedge CLK)
  if (en) begin
    if (!RST_N) q_enable_first <= 0;
    else q_enable_first <= a ^ b;
  end
always @(negedge CLK)
  if (en) q_negative <= (a & b) | (a + b);
endmodule
'''


@unittest.skipUnless(CONFIG, 'Set LOTUS_HAMMER_TEST_CONFIG for the Hammer integration regression')
class HammerBackendTests(unittest.TestCase):
    def test_multilib_mapping_preserves_reset_enable_and_clock_polarity(self):
        config = yaml.safe_load(Path(CONFIG).read_text())
        libraries = [Path(item['library']['nldm_liberty_file'])
                     for item in config['vlsi.technology.extra_libraries']]
        self.assertGreater(len(libraries), 1, 'Regression requires split libraries')
        with tempfile.TemporaryDirectory(prefix='lotus-hammer-') as tmp:
            out = Path(tmp)
            rtl = out/'smoke.sv'
            rtl.write_text(RTL)
            config['synthesis.inputs.top_module'] = 'smoke'
            config['synthesis.inputs.input_files'] = [str(rtl)]
            config['synthesis.yosys.generate_only'] = False
            design = out/'design.yml'
            design.write_text(yaml.safe_dump(config))
            run = subprocess.run(['hammer-vlsi', '-p', str(design), '--obj_dir', str(out/'obj'),
                                  '-l', str(out/'hammer.log'), '-o', str(out/'output.json'), 'syn'],
                                 capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 0, (run.stdout+run.stderr)[-6000:])
            mapped = Path(json.loads((out/'output.json').read_text())['synthesis.outputs.output_files'][0])
            script = (out/'obj/syn-rundir/syn.tcl').read_text()
            self.assertNotIn('dfflibmap -map-only', script)
            # Each mapping/report command must see the complete library set.
            for command in ('dfflibmap ', 'abc -D ', 'stat -top smoke '):
                lines = script.replace('\\\n', ' ').splitlines()
                matching = [line for line in lines if command in line and not line.startswith('puts ')]
                self.assertEqual(len(matching), 1)
                self.assertEqual(matching[0].count('-liberty '), len(libraries))
            q = lambda p: json.dumps(str(p))
            proof = f'read_verilog -sv {q(rtl)}\nprep -top smoke\nrename smoke gold\ndesign -stash gold\n'
            proof += ''.join(f'read_liberty -ignore_miss_func {q(p)}\n' for p in libraries)
            proof += f'read_verilog {q(mapped)}\nprep -top smoke -flatten\nrename smoke gate\ndesign -stash gate\n'
            proof += ('design -copy-from gold -as gold gold\ndesign -copy-from gate -as gate gate\n'
                      'equiv_make gold gate equiv\nhierarchy -top equiv\nequiv_simple\n'
                      'equiv_induct -seq 4\nequiv_status -assert\n')
            (out/'proof.ys').write_text(proof)
            run = subprocess.run([config['synthesis.yosys.yosys_bin'], '-Q', '-T', '-s', str(out/'proof.ys')],
                                 capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 0, (run.stdout+run.stderr)[-6000:])
            self.assertIn('Equivalence successfully proven!', run.stdout)


if __name__ == '__main__':
    unittest.main()
