#!/usr/bin/env python3
"""Hammer Genus entry point for logic-only synthesis with logical SRAMs.

The upstream mapping, reports and output steps are unchanged. The initialization
hook omits physical LEFs and marks only the declared XRAM architectures opaque.
"""
from pathlib import Path

from hammer.vlsi import CLIDriver, HammerTool

from prepare import MEMORIES


def tcl_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace(
        '$', '\\$').replace('[', '\\[').replace(']', '\\]') + '"'


def logic_environment(tool: HammerTool) -> bool:
    mmmc = Path(tool.run_dir) / 'mmmc.tcl'
    tool.write_contents_to_path(tool.generate_mmmc_script(), str(mmmc))
    tool.append('read_mmmc ' + tcl_string(mmmc))
    tool.append('read_hdl -sv [list ' + ' '.join(tcl_string(p) for p in tool.input_files) + ']')
    for memory in sorted(MEMORIES):
        # Genus names Verilog architectures default/<module>.
        tool.append(f'set_db [get_db hdl_architectures *{memory}] .blackbox true')
    tool.append('elaborate ' + tool.top_module)
    tool.append('init_design -top ' + tool.top_module)
    tool.append('set_db root: .auto_ungroup none')
    tool.append('''
foreach lotus_hinst [get_db hinsts] {
    if {[get_db $lotus_hinst .module.logic_abstract]} {
        set_db $lotus_hinst .preserve true
    }
}
''')
    for command in tool.generate_dont_use_commands():
        tool.append(command)
    return True


def logic_inventory(tool: HammerTool) -> bool:
    # get_db insts includes leaf instances at every hierarchy level, exactly once.
    # Export individual cells so Python can reject unmapped cells and audit areas
    # against the same native 1x Liberty files used by the Yosys flow.
    tool.append('''
set lotus_inventory [open lotus_cells.tsv w]
puts $lotus_inventory "instance\tcell\tarea\tblackbox"
foreach lotus_inst [get_db insts] {
    set lotus_cell [get_db $lotus_inst .base_cell.name]
    puts $lotus_inventory "[get_db $lotus_inst .name]\t$lotus_cell\t[get_db $lotus_inst .area]\t[get_db $lotus_inst .is_black_box]"
}
foreach lotus_hinst [get_db hinsts] {
    if {[get_db $lotus_hinst .module.logic_abstract]} {
        puts $lotus_inventory "[get_db $lotus_hinst .name]\t[get_db $lotus_hinst .module.name]\t0\ttrue"
    }
}
close $lotus_inventory
report_timing -max_paths 50 > reports/lotus_timing.rpt
''')
    # Bind the native reports to the exported netlist for --report-only.
    tool.append('set lotus_artifacts [open lotus_artifacts.sha256 w]')
    for path in (tool.mapped_v_path, 'lotus_cells.tsv', 'reports/lotus_timing.rpt'):
        tool.append('puts $lotus_artifacts [lindex [exec sha256sum -- ' + tcl_string(path) + '] 0]')
    tool.append('close $lotus_artifacts')
    return True


class LotusGenusDriver(CLIDriver):
    def get_extra_synthesis_hooks(self):
        return [
            HammerTool.make_replacement_hook('init_environment', logic_environment),
            HammerTool.make_post_insertion_hook('write_outputs', logic_inventory),
        ]


if __name__ == '__main__':
    LotusGenusDriver().main()
