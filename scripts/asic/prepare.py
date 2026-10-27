#!/usr/bin/env python3
"""Prepare one tile for logic-area synthesis with opaque logical SRAMs."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
from sram import logical_memory, unresolved_record, update_totals, save_manifest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SUPPORT = {name: REPO / "lotus/utils" / (name + ".sv")
           for name in ("CreditFIFO", "NonBlockingPipe", "ShiftRegister", "RegWithReset")}
SUPPORT["XRegFile"] = REPO / "lotus/xram/XRegFile.sv"
MEMORIES = {"XRAM1", "XRAM2", "XRAM2BE"}
LIBS = {"FIFO1", "FIFO2", "FIFO10", "FIFO20", "FIFOL1", "SizedFIFO", "SizedFIFO0", "Counter", "RevertReg"}
INSTANCE = re.compile(r"^  (\w+)\s+(?:#\((.*?)\)\s*)?(\w+)\(", re.M | re.S)

def clean(text):
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)

def guard_simulation(text):
    # Make simulation-only regions explicit to the synthesis preprocessor,
    # independently of support for synthesis translate directives.
    return re.sub(r"(//\s*synopsys translate_off)(.*?)(//\s*synopsys translate_on)",
        r"\1\n`ifndef SYNTHESIS\2\n`endif\n\3", text, flags=re.S)

def instances(text):
    return list(INSTANCE.finditer(clean(text)))

def integer(value):
    value = value.strip()
    if value.isdigit():
        return int(value)
    m = re.fullmatch(r"\d+'([dhb])([0-9a-fA-F]+)", value)
    if not m:
        raise ValueError(f"Unsupported numeric parameter: {value}")
    return int(m[2], {"d":10,"h":16,"b":2}[m[1]])

def prepare(build, out, bsc_lib):
    raw = build / "hdl/bsv"
    previous = None
    if out.exists() and any(out.iterdir()) and not (out / "manifest.json").is_file():
        raise ValueError(f"Refusing to overwrite unrecognized directory {out}")
    if (out / "manifest.json").is_file():
        previous = json.loads((out / "manifest.json").read_text())
        if "files" in previous or (out / "macro_allocation.json").exists():
            raise ValueError(f"{out} contains a retired ASIC flow; choose a fresh output directory")
    modules = {}
    def visit(name):
        if name in modules:
            return
        text = (raw / (name + ".v")).read_text()
        if "Postprocessed initial values" in text or "wire RST_N =" in text:
            raise ValueError(f"{name}: expected raw reset-preserving BSC output")
        if not re.search(r"input\s+RST_N\s*;", text):
            raise ValueError(f"{name}: missing reset port")
        modules[name] = text
        for m in instances(text):
            if m[1].startswith("mk"):
                visit(m[1])
            elif m[1] not in SUPPORT.keys() | MEMORIES | LIBS:
                raise ValueError(f"Unsupported leaf {m[1]} in {name}; add an explicit ASIC implementation")
    visit("mkTile")
    counts = Counter()
    def count(name, n):
        counts[name] += n
        for m in instances(modules[name]):
            if m[1] in modules:
                count(m[1], n)
    count("mkTile", 1)
    inventory = []
    lib_names = set()
    support_names = set()
    for name, text in modules.items():
        for m in instances(text):
            if m[1] in LIBS:
                lib_names.add(m[1])
            if m[1] in SUPPORT:
                support_names.add(m[1])
            # XRegFile remains synthesizable standard-cell RTL, not SRAM inventory.
            if m[1] in MEMORIES:
                params = {k:integer(v) for k,v in re.findall(
                    r"\.(ADDR_WIDTH|DATA_WIDTH|NUM_WORDS|READ_LATENCY|LOG_RATIOB|CHUNK_SIZE|MODEA|MODEB|MODE)\(([^()]*)\)", m[2])}
                params.setdefault("NUM_WORDS", 2**params["ADDR_WIDTH"])
                inventory.append(dict(module=name, instance=m[3], type=m[1],
                    multiplicity=counts[name], parameters=params,
                    raw_bits=params["NUM_WORDS"]*params["DATA_WIDTH"]))
    out.mkdir(parents=True, exist_ok=True)
    rtl = out / "rtl"
    rtl.mkdir(exist_ok=True)
    written = []
    rtl_changed = False
    def write(name, text):
        nonlocal rtl_changed
        dest=rtl/name
        rtl_changed |= not dest.exists() or dest.read_text() != text
        dest.write_text(text)
        written.append(dest)
    for name, text in modules.items():
        text = re.sub(r"\(\*.*?\*\)", "", text, flags=re.S)
        # Preserve original interfaces; XRAMs remain opaque area boundaries.
        def adapt(m):
            if m[1] in MEMORIES:
                return "  (* keep *) " + m[0].lstrip()
            return m[0]
        text = INSTANCE.sub(adapt, text)
        write(name+".v", guard_simulation(text))
    for name in sorted(lib_names):
        # Generic unmodified BSC library, not Verilog.Vivado or postprocessed copies.
        text = (bsc_lib / "Verilog" / (name+".v")).read_text()
        text = re.sub(r"\(\*.*?\*\)", "", text, flags=re.S)
        write(name+".v", guard_simulation(text))
    for name in sorted(support_names):
        # Original Lotus RTL; initialization/diagnostic guards live in source.
        text = re.sub(r"\(\*.*?\*\)", "", SUPPORT[name].read_text(), flags=re.S)
        write(name+".sv", text)
    write("memory_blackboxes.sv", (HERE/"rtl/memory_blackboxes.sv").read_text())
    # Remove the retired generated replacement when refreshing an old package.
    (rtl/"support.sv").unlink(missing_ok=True)
    rtl_changed |= bool(previous and previous.get("synthesis_files") != [str(p) for p in written])
    records = [unresolved_record(logical_memory(ram, build)) for ram in inventory]
    manifest=dict(schema_version=2,
        source_build=str(build), memory_inventory=records,
        source_sha256={n:hashlib.sha256(t.encode()).hexdigest() for n,t in modules.items()},
        synthesis_files=[str(p) for p in written],
        sram_model=dict(status="unconfigured", policy=None, runs={}))
    # Repackaging identical RTL must not discard an agreed mapping or model run.
    if (previous and previous.get("schema_version") == 2
            and previous["source_sha256"] == manifest["source_sha256"]
            and [r["logical"] for r in previous["memory_inventory"]] == [r["logical"] for r in records]):
        manifest["memory_inventory"] = previous["memory_inventory"]
        manifest["sram_model"] = previous["sram_model"]
    update_totals(manifest)
    if rtl_changed or not previous or previous["source_sha256"] != manifest["source_sha256"]:
        (out/"hammer_summary.json").unlink(missing_ok=True)
    save_manifest(out/"manifest.json", manifest)
    return manifest

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--build-dir", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--bsc-lib", type=Path, required=True)
    a=p.parse_args()
    try:
        m=prepare(a.build_dir.resolve(),a.out.resolve(),a.bsc_lib.resolve())
    except (ValueError,FileNotFoundError) as e:
        p.exit(2, f"ASIC preparation failed: {e}\n")
    print(f"Prepared mkTile for logic-area synthesis: {a.out}; "
          f"{m['sram_model']['totals']['logical_instances']} logical SRAM blackboxes")

if __name__=="__main__":
    main()
