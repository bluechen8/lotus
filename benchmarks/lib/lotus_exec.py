#!python

# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

from pprint import pprint
import re
import os, sys
import math
import networkx as nx
# import matplotlib.pyplot as plt
import subprocess
from collections import OrderedDict, defaultdict
from sortedcontainers import SortedSet
from enum import Enum
from FunctionArgExtractor import parse_functions_with_arg_macros
import shlex
from pathlib import Path
import time
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Tuple, Optional
import uuid
from contextlib import contextmanager
from operator import attrgetter
from copy import deepcopy
from datetime import date

from dataclasses import dataclass
from itertools import combinations


def stats_int(nums):
    from statistics import mean, median, stdev
    if len(nums) == 0:
        return {"min": None, "max": None, "mean": None, "median": None, "std_dev": None}
    return {
        "min": min(nums),
        "max": max(nums),
        "mean": mean(nums),
        "median": median(nums),
        "std_dev": stdev(nums) if len(nums) > 1 else 0.0
    }

def dag_ranks_longest_path(G):
    assert nx.is_directed_acyclic_graph(G)
    rank = {}
    for v in nx.topological_sort(G):
        preds = list(G.predecessors(v))
        rank[v] = 0 if not preds else 1 + max(rank[p] for p in preds)

    return rank
    #inv_rank = defaultdict(list)
    #for v, r in rank.items():
    #    inv_rank[r].append(v)
    #return dict(inv_rank)

class Timer:
    def __init__(self):
        self.start_time = None
        self.title = None

    def start(self, title):
        self.title = title
        self.start_time = time.perf_counter()

    def stop(self):
        end_time = time.perf_counter()
        seconds = end_time - self.start_time
        print(f"TIMER: `{self.title}` took {seconds:.6f} seconds", flush=True)
        self.title = None
        self.start_time = None
class AccumTimer:
    def __init__(self, title):
        self.title = title
        self.start_time = None
        self.seconds   = 0

    def start(self):
        self.start_time = time.perf_counter()

    def stop(self):
        end_time = time.perf_counter()
        seconds = end_time - self.start_time
        self.seconds += seconds
    def print(self):
        print(f"TIMER: `{self.title}` took {self.seconds:.6f} seconds", flush=True)

def timed(func):
    def wrapper(*args, **kwargs):
        timer = Timer()
        timer.start(func.__name__)
        result = func(*args, **kwargs)
        timer.stop()
        return result
    return wrapper

class LotusGraph:
    def __init__(self):
        self.nodes_ = {} # {idx: node}
        self.edges_flat = [] # [edges,...]
        self.in_edges_  = {} # {cons_idx:[edges,...]}
        self.out_edges_ = {} # {prod_idx:[edges,...]}
        self.meta       = {}

    def add_node(self, idx, node):
        assert idx not in self.nodes_
        self.nodes_[idx] = node
    def add_edge(self, prod_idx, cons_idx, edge):
        assert prod_idx in self.nodes_
        assert cons_idx in self.nodes_
        self.edges_flat.append(edge)
        if prod_idx not in self.out_edges_:
            self.out_edges_[prod_idx] = []
        self.out_edges_[prod_idx].append(edge)
        if cons_idx not in self.in_edges_:
            self.in_edges_[cons_idx] = []
        self.in_edges_[cons_idx].append(edge)
    def remove_edges(self, removed):
        if not isinstance(removed, (set, list, tuple, frozenset)):
            removed = {removed}
        elif not isinstance(removed, (set, frozenset)):
            removed = set(removed)

        self.edges_flat = [e for e in self.edges_flat if e not in removed]
        for k, lst in self.out_edges_.items():
            if lst: self.out_edges_[k] = [e for e in lst if e not in removed]
        for k, lst in self.in_edges_.items():
            if lst: self.in_edges_[k] = [e for e in lst if e not in removed]

    def nodes(self):
        return self.nodes_.values()

    def edges(self):
        return self.edges_flat
    def out_edges(self, idx):
        if isinstance(idx, LotusTask):
            idx = idx.idx
        if idx not in self.out_edges_:
            self.out_edges_[idx] = []
        return self.out_edges_[idx]
    def out_degree(self, idx):
        return len(self.out_edges(idx))
    def in_edges(self, idx):
        if isinstance(idx, LotusTask):
            idx = idx.idx
        if idx not in self.in_edges_:
            self.in_edges_[idx] = []
        return self.in_edges_[idx]
    def in_degree(self, idx):
        return len(self.in_edges(idx))
    def has_edge(self, prod, cons, cycle_delta):
        if type(prod) is LotusTask:
            prod = prod.idx
        if type(cons) is LotusTask:
            cons = cons.idx
        assert type(prod) is int
        assert type(cons) is int
        for e in self.out_edges(prod):
            if (e.consumer.idx == cons) and (e.cycle_delta == cycle_delta):
                return True
        return False
    def get_node(self, idx):
        assert isinstance(idx, int)
        assert idx in self.nodes_
        return self.nodes_[idx]


def partition_id_conv(dest_tile, config):
    if type(dest_tile) is tuple:
        device_id, local_tile_id = dest_tile
        return (device_id * config["TILES_PER_DEVICE"]) + local_tile_id
    elif type(dest_tile) is int:
        device_id     = dest_tile // config["TILES_PER_DEVICE"]
        local_tile_id = dest_tile % config["TILES_PER_DEVICE"]
        return (device_id, local_tile_id)
    else:
        assert False


def dest_tile_conv(dest_tile, config):
    def _tile_bits(tpd: int) -> int:
        # Always at least 1 bit, even if tpd == 1
        return max(1, (tpd - 1).bit_length())
    tpd = int(config["TILES_PER_DEVICE"])
    tile_bits = _tile_bits(tpd)
    mask = (1 << tile_bits) - 1

    if isinstance(dest_tile, tuple):
        device_id, local_tile_id = dest_tile
        assert 0 <= local_tile_id < tpd, "local_tile_id out of range for TILES_PER_DEVICE"
        # Pack: device_id in upper bits, local_tile_id in lower bits
        return (device_id << tile_bits) | local_tile_id

    elif isinstance(dest_tile, int):
        device_id     = dest_tile >> tile_bits
        local_tile_id = dest_tile & mask
        assert local_tile_id < tpd, "decoded local_tile_id is invalid for TILES_PER_DEVICE"
        return (device_id, local_tile_id)

    else:
        raise TypeError("dest_tile must be an int or a (device_id, local_tile_id) tuple")

class TaskStruct:
    def __init__(self, task):
        self.task = task
        self.vars = []
        self.prod_to_vars = defaultdict(set)
        self.struct_pointers = []
        self.type_name = None
        self.instance_name = None
        self.layout = None
        self.size  = None
        self.align = None

    def est_bytes(self):
        b = 0
        b += len(self.struct_pointers)*4
        for v in self.vars:
            if v.is_mem:
                b += 4
            else:
                b += v.size
        return b
    def update(self, vars, prod_to_vars):
        for v in vars:
            if v not in self.vars:
                v.overflows = True
                self.vars.append(v)
        for prod, vars in prod_to_vars.items():
            self.prod_to_vars[prod] = self.prod_to_vars[prod].union(vars)

        self.vars.sort(key=lambda v: v.idx)
        for _, vars in prod_to_vars.items():
            vars.sort(key=lambda v: v.idx)

    def get_vars_for(self, task):
        if task not in self.prod_to_vars:
            return []
        else:
            return self.prod_to_vars[task]

    def get_pointer_index(self, sp):
        assert sp in self.struct_pointers
        return self.struct_pointers.index(sp)

    def get_layout_ref(self, ls, var, needsCast):
        if isinstance(var, LotusVar):
            var = var.get_physical()
        if var not in self.layout:
            return None
        i = self.layout.index(var)
        if not needsCast:
            return f"({ls}->var_{i})"
        else:
            return f"static_cast<{self.type_name}*>({ls})->var_{i}"

    def sig(self):
        s = ["TaskStruct"]
        s.append(len(self.struct_pointers))
        for v in self.vars:
            s.append(v.sig())
        return tuple(s)

    def to_str(self):
        assert self.type_name is not None
        s = []
        bs = 0
        for i, l in enumerate(self.layout):
            if isinstance(l, TaskStruct):
                #s.append(f"    {l.type_name} *var_{i};")
                # We can't get a signature of structs without needing a signature first
                # Thus, grouping has to assume unknown structs
                s.append(f"    void *var_{i}; // {bs} + 4")
                bs += 4
            elif isinstance(l, LotusVar):
                if l.is_mem:
                    s.append(f"    {l.typee}* var_{i}; // {bs} + 4")
                    bs += 4
                else:
                    s.append(f"    {l.typee} var_{i}; // {bs} + {l.size}")
                    bs += l.size
            elif isinstance(l, int):
                s.append(f"    std::array<uint8_t, {l}> padding_{i}; // {bs} + {l}")
                bs += l
            else:
                assert False

        s = "\n".join(s)
        s = s + "\n"

        s = f"struct {self.type_name}" + " {\n" + s

        s = s + "};\n"

        return s

class LotusTask:
    class ARG_DIR(Enum):
        IN  = 1
        OUT = 2
        INOUT = 3
    class ARG_ACCESS(Enum):
        FULL = 1
        PARTIAL = 2
        PARTIAL_UNTRACKED = 3
    def __init__(self, idx, fn, part_hint, coarse_hint):
        self.idx = idx
        self.fn  = fn
        self.part_hint   = part_hint
        self.coarse_hint = coarse_hint
        self.wrapper_fn = None # Name of the wrapper task
        self.args    = [] # User-written function args in order
        self.register_alloc = None # Input registers
        self.struct_alloc   = None # Input mem
        self.output_table   = None # Output regs
        self.output_mem     = None # Output mem
        self.recipes        = None # Recipes
        self.mappedTo       = None # Mapping
        self.task_id        = None # Priority
        self.edgeRecipeStart = None # Edge recipe location
        self.group_id        = None # Tasks in same group share wrapper
        self.num_instrs      = None # Number of static instructions
        self.setsHeartbeats = False
        self.unroll_version  = None
        self.label = None
    def useful_name(self):
        #return f"{self.fn}@{self.unroll_version} (ph={self.part_hint}, ch={self.coarse_hint}, idx={self.idx})"
        return f"{self.fn}@{self.unroll_version}"
    def __str__(self):
        args  = [(d.name, a.name, v.idx) for (d, a, v) in self.args]
        return f"LotusTask(idx={self.idx}, mappedTo={self.mappedTo}, fn={self.fn}, args={args})"
    def __repr__(self):
        s = "LotusTask: {\n"
        s += f"    idx             : {self.idx}\n"
        s += f"    fn              : {self.fn}\n"
        s += f"    wrapper_fn      : {self.wrapper_fn}\n"
        s += f"    args            : {self.args}\n"
        s += f"    register_alloc  : {self.register_alloc}\n"
        s += f"    struct_alloc    : {self.struct_alloc}\n"
        s += f"    output_table    : {self.output_table}\n"
        s += f"    output_mem      : {self.output_mem}\n"
        s += f"    recipes         : {self.recipes}\n"
        s += f"    mappedTo        : {self.mappedTo}\n"
        s += f"    task_id         : {self.task_id}\n"
        s += f"    edgeRecipeStart : {self.edgeRecipeStart}\n"
        s += f"    setsHeartbeats  : {self.setsHeartbeats}\n"
        s += "}\n"
        return s

    def has_unroll_var(self):
        for _, _, var in self.args:
            if var.is_unroll_var:
                return True
        return False

    def get_var_arg_idx(self, v):
        for i in range(len(self.args)):
            _, _, var = self.args[i]
            if var == v:
                return i
        return None
    def get_var_arg_idx_dir(self, v, d):
        for i in range(len(self.args)):
            di, _, var = self.args[i]
            if (d == di) and (var == v):
                return i
        return None

    def get_props_in_args(self, targetVar):
        for dir, acc, var in self.args:
            if var == targetVar:
                return (dir, acc)
        return None
    def get_in_var_comp(self, var):
        return self.register_alloc.get_var_comp(var)

    def consumed_bytes(self):
        bytes = 0
        for dir, _, var in self.args:
            if dir == LotusTask.ARG_DIR.OUT:
                continue
            bytes += var.size
        return bytes
        pass

    def sig(self):
        s = ["LotusTask"]
        s.append(self.fn)
        s.append(self.setsHeartbeats)

        if True:
            assert self.register_alloc
            s.append(self.register_alloc.sig("INPUT"))

        if True:
            assert self.output_table
            s.append(self.output_table.sig("OUTPUT"))

        if self.struct_alloc:
            s.append(self.struct_alloc.sig())

        if self.output_mem is not None:
            so = ["output_mem"]
            for ts, vars in self.output_mem.items():
                sv = []
                sv.append(self.struct_alloc.get_pointer_index(ts))
                sv.append(ts.sig())
                for v in vars:
                    sv.append(v.sig())
                so.append(tuple(sv))
            s.append(tuple(so))
        return tuple(s)

    def assert_args_inputs(self):
        for i, (dir, acc, var) in enumerate(self.args):
            inRegs = len(self.get_in_var_comp(var))
            inStruct = False
            if self.struct_alloc:
                inStruct = var in self.struct_alloc.vars
            if inRegs or inStruct:
                continue
            assert acc == LotusTask.ARG_ACCESS.FULL
            assert (dir == LotusTask.ARG_DIR.OUT) or (var.writer is None)

    def assign_group_ids(G):
        function_to_tasks = defaultdict(list)
        tasks = list(G.nodes())
        tasks.sort(key=lambda t: t.idx)
        for task in tasks:
            function_to_tasks[task.sig()].append(task)
        task_groups = list(function_to_tasks.items())
        task_groups.sort(key=lambda sig_grb: (sig_grb[0], sig_grb[1][0].idx))
        task_groups = [grb for _, grb in task_groups]
        for i, tasks in enumerate(task_groups):
            for t in tasks:
                t.group_id = i
        G.meta["num_groups"] = len(task_groups)

    def get_groups(G):
        groups = []
        for _ in range(G.meta["num_groups"]):
            groups.append([])

        tasks = list(G.nodes())
        tasks.sort(key=lambda t: t.idx)
        for task in tasks:
            groups[task.group_id].append(task)
        return groups

class LotusVar:
    def __init__(self, idx, typee, init_val, cycle_delta):
        self.idx          = idx
        self.typee        = typee
        self.is_mem       = False
        self.is_untracked = False
        self.init_val     = init_val
        self.size         = None
        self.align        = None
        self.cycle_delta  = cycle_delta
        self.writer       = None
        self.readers      = []
        self.overflows    = False
        self.physical_var = None # If this is set, then self is virtual, has a physical
        self.virtual_vars = None # If this is set, then self is physical, has virtuals
        self.unroll_version = None
        self.can_coarsen = False
        self.is_unroll_var = False # SHOULD BE INITIALIZED BY THE COMPILER EQUAL TO UNROLL FACTOR
    def get_physical(self):
        if self.physical_var is not None:
            return self.physical_var
        return self
    def get_virtuals(self):
        if self.virtual_vars is not None:
            return self.virtual_vars
        return [self]
    def bytes(self):
        return self.size
    def __repr__(self):
        return self.__str__()
    def __str__(self):
        if self.writer:
            writer  = self.writer.idx
        else:
            writer = "None"
        readers = [t.idx for t in self.readers]
        return f"LotusVar(idx={self.idx}, type={self.typee}, is_mem={self.is_mem}, init_val=..., cycle_delta={self.cycle_delta}, writer={writer}, readers={readers})"

    def sig(self):
        return ("LotusVar", self.typee)
    def is_same_cycle(self, G):
        if self.writer is None:
            return False
        if not self.readers:
            return False
        for e in G.out_edges(self.writer):
            if e.consumer in self.readers:
                # Vars can either be cc or sc, so one instance
                # is enough to figure it out
                return e.cycle_delta == 0
        return False


class LotusEdge:
    def __init__(self, producer, consumer, cycle_delta, typee):
        self.producer = producer
        self.consumer = consumer
        self.cycle_delta = cycle_delta
        self.typee = typee
        self.vars = []
        self.output_ids = None
        self.saved_sig = None

    def sig(self):
        if self.saved_sig is None:
            k = []
            for v in e.vars:
                i = e.producer.get_var_arg_idx(v)
                assert i is not None
                k.append(i)
            k.sort()
            self.saved_sig = tuple(k)
        return self.saved_sig

    def __str__(self):
        vs = [v.idx for v in self.vars]
        return f"LotusEdge(producer={self.producer.idx}, consumer={self.consumer.idx}, cycle_delta={self.cycle_delta}, type={self.typee}, vars={vs})"

    def add_var(self, var):
        self.vars.append(var)

    def can_coarsen(self):
        cc = set()
        for v in self.vars:
            cc.add(v.can_coarsen)
        if len(cc) == 1:
            return list(cc)[0]
        elif len(cc) == 0:
            return False
        else:
            return cc



class RegisterAllocation:
    def __init__(self, task, regs, fors, other=None):
        self.task = task
        self.regs = regs
        self.fors = fors
        self.other = other
    def get_regs_for(self, task):
        regs = []
        for i in range(len(self.fors)):
            if isinstance(self.fors[i], list) and task in self.fors[i]:
                regs.append((i, self.regs[i]))
            elif self.fors[i] == task:
                regs.append((i, self.regs[i]))
        return regs
    def get_var_comp(self, var):
        var = var.get_physical()
        comps = []
        for (idx, partials) in enumerate(self.regs):
            for partial in partials:
                (i, v, acc, regByte, startByte, endByte, useBytes) = partial
                if v == var:
                    comps.append((idx, partial))
        return comps
    def sig(self, dir):
        regs = [f"RegisterAllocation({dir})"]
        if dir == "INPUT":
            for a in self.task.args:
                if a[0] != LotusTask.ARG_DIR.IN:
                    continue
                var = a[2]
                # (1) same input order index for consumer (current)
                if True:
                    comp = self.task.get_in_var_comp(var)
                    comp = [rid for rid, _ in comp]
                    regs.append(tuple(comp))
                ## (2) same output order index for producer (current)
                #if var.writer is not None:
                #    comp = var.writer.get_in_var_comp(var)
                #    comp = [rid for rid, _ in comp]
                #    regs.append(tuple(comp))
                #else:
                #    regs.append((None,))
        elif dir == "OUTPUT":
            for a in self.task.args:
                if a[0] != LotusTask.ARG_DIR.OUT:
                    continue
                var = a[2]
                # (1) same output order index for producer (current)
                if True:
                    # Need to make sure that every reader has the same index
                    comp = self.task.output_table.get_var_comp(var)
                    comp = [rid for rid, _ in comp]
                    regs.append(tuple(comp))
                ## (2) same input order index for consumer
                #if len(var.readers):
                #    for cons_task in var.readers:
                #        # Need to make sure that every reader has the same index
                #        comp = cons_task.get_in_var_comp(var)
                #        comp = [rid for rid, _ in comp]
                #        regs.append(tuple(comp))
                #else:
                #    regs.append((None,))
        else:
            assert False
        for r in self.regs:
            reg = []
            for _, v, _, reg_byte, startByte, endByte, _ in r:
                reg.append((v.typee, reg_byte, startByte, endByte))
            regs.append(tuple(reg))
        return tuple(regs)

class Recipe:
    def __init__(self, dst_task, cycle_delta, hasMemDataDep, first_arg, arg0, arg1):
        self.dst_task    = dst_task
        self.cycle_delta = cycle_delta
        self.first_arg    = first_arg
        self.hasMemDataDep = hasMemDataDep
        self.arg0        = arg0
        self.arg1        = arg1
    def __str__(self):
        dt = self.dst_task
        cd = self.cycle_delta
        hm = self.hasMemDataDep
        fa = self.first_arg
        a0 = self.arg0
        a1 = self.arg1
        return f"Recipe(dst_task={dt}, cycle_delta={cd}, hasMemDataDep={hm}, first_arg={fa}, arg0={a0}, arg1={a1})"
    def __repr__(self):
        return self.__str__()

class TileStruct:
    def __init__(self, tile_id):
        self.tile_id = tile_id
        self.name    = f"tile_struct_{self.tile_id}"
        self.vars    = []
    def add_var(self, var):
        self.vars.append(var)
    def get_reference(self, var):
        assert var in self.vars, f"var_not_found: {var} -- vars: {self.vars}"
        idx = self.vars.index(var)
        return f"{self.name}.var_{idx}"

@timed
def get_type_sizes(name, types, config, additionalStr=""):
    if not types:
        return {}

    out_path = Path(config["OUT_PATH"])
    include_path = config["TASKS_INCLUDE"]
    sizes_path  = out_path / f"{name}.cpp"
    elf_path    = out_path / f"{name}.out"

    # Toolchain + simulator
    riscv_path = "$RISCV_TOOLCHAIN/bin/riscv32-unknown-elf-gcc"
    sim_tool   = "$SPIKE/bin/spike --isa=rv32ima_zicntr_zihpm $SPIKE/riscv32-unknown-elf/bin/pk"

    type_list = list(types)
    lines = []
    lines.append("// Auto-generated. DO NOT EDIT.")
    lines.append("#include <cstdio>")
    lines.append("#include <cstddef>")
    lines.append("#include <array>")
    lines.append(f"#include \"{include_path}\"")
    lines.append("")
    lines.append("// Additional Str BEGIN")
    lines.append(additionalStr)
    lines.append("// Additional Str END")
    lines.append("")
    lines.append("int main() {")
    lines.append(f'    std::printf("ASTART\\n");')
    for t in type_list:
        label = t.replace('\\', '\\\\').replace('"', r'\"')
        lines.append(f'    std::printf("%s %zu %zu\\n", "{label}", (size_t)sizeof({t}), (size_t)alignof({t}));')
    lines.append(f'    std::printf("AEND\\n");')
    lines.append("    return 0;")
    lines.append("}")
    source = "\n".join(lines)

    sizes_path.write_text(source)

    compile_cmd = []
    compile_cmd.append(riscv_path)
    compile_cmd.append("-std=c++20")
    if config["DEFINES"]:
        compile_cmd.append(config["DEFINES"])

    compile_cmd.append("-static")
    compile_cmd.append(str(sizes_path))
    compile_cmd.append("-o")
    compile_cmd.append(str(elf_path))

    try:
        subprocess.run(" ".join(compile_cmd), shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        msg = (f"RISC-V compile failed (exit {e.returncode}).\n"
               f"Cmd: {' '.join(shlex.quote(x) for x in compile_cmd)}\n"
               f"stderr:\n{e.stderr.decode(errors='ignore')}\n"
               f"Generated source at: {sizes_path}")
        raise RuntimeError(msg) from e

    try:
        run = subprocess.run(sim_tool + " " + str(elf_path), shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        msg = (f"Simulation run failed (exit {e.returncode}).\n"
               f"Cmd: {' '.join(shlex.quote(x) for x in run_cmd)}\n"
               f"stderr:\n{e.stderr.decode(errors='ignore')}")
        raise RuntimeError(msg) from e

    result = {}
    out_text = run.stdout.decode(errors="replace")
    lines = out_text.splitlines()
    lines = [l.strip() for l in lines]
    lines = lines[lines.index("ASTART")+1:lines.index("AEND")]
    for i, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue
        try:
            after_split = line.rsplit(" ", 2)
            assert len(after_split) == 3, f"Should have 3 elements, {after_split}"
            typee  = after_split[0]
            size   = int(after_split[1])
            align  = int(after_split[2])
        except Exception:
            raise RuntimeError(f"Unexpected output format on line {i+1!r}: {line!r}\nFull output:\n{out_text}")
        result[typee] = (size, align)

    missing = [t for t in type_list if t not in result]
    if missing:
        raise RuntimeError(f"Did not receive sizes for: {missing}\nSimulator output:\n{out_text}")

    return result

def get_task_instrs(name, taskNames, config):
    if not taskNames:
        return {}

    header_filenames = []
    header_filenames.append(config["TASKS_INCLUDE"])
    for f in config["GENERATED_FILES_TO_INCLUDE"]:
        header_filenames.append(f)


    out_path = Path(config["OUT_PATH"])
    obj_path = out_path / f"{name}.o"

    cpp_file = out_path / f"{name}_instrs.cpp"
    with open(str(cpp_file), "w") as f:
        f.write("// Auto-generated file to count task instructions.\n\n")
        for h in header_filenames:
            f.write(f'#include "{h}"\n')

    riscv_base = os.path.join(os.environ["RISCV_TOOLCHAIN"], "bin")

    # Compile
    if True:
        # Toolchain + simulator
        riscv_path = f"{riscv_base}/riscv32-unknown-elf-g++"

        compile_cmd = []
        compile_cmd.append(riscv_path)
        compile_cmd.append("-std=c++20")
        if config["DEFINES"]:
            compile_cmd.append(config["DEFINES"])

        compile_cmd.append("-static")
        compile_cmd.append("-O3")
        compile_cmd.append("-fkeep-inline-functions")
        compile_cmd.append("-fkeep-static-functions")

        compile_cmd.append(f"-I{out_path}")
        #compile_cmd.append("-x")
        #compile_cmd.append("c++")
        compile_cmd.append("-c")
        compile_cmd.append(str(cpp_file))
        compile_cmd.append("-o")
        compile_cmd.append(str(obj_path))

        print(" ".join(compile_cmd))

        try:
            subprocess.run(compile_cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as e:
            msg = (f"RISC-V compile failed (exit {e.returncode}).\n"
                f"Cmd: {' '.join(shlex.quote(x) for x in compile_cmd)}\n"
                f"stderr:\n{e.stderr.decode(errors='ignore')}\n"
                f"Generated source at: {obj_path}")
            raise RuntimeError(msg) from e

    # NM
    symbols = []
    if True:
        nm = f"{riscv_base}/riscv32-unknown-elf-nm"
        proc = subprocess.run(
            [nm, "-S", "--demangle", obj_path],
            check=True, text=True, capture_output=True
        )
        for line in proc.stdout.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            addr_hex, size_hex, sym_type = parts[:3]
            name = " ".join(parts[3:])  # demangled symbol name
            if "lambda" in name:
                continue
            try:
                addr = int(addr_hex, 16)
                size = int(size_hex, 16)
            except ValueError:
                continue
            symbols.append({
                "addr": addr,
                "size": size,
                "type": sym_type,
                "name": name,
            })

    taskName_to_size = {}
    for taskName in taskNames:
        matches = []
        for s in symbols:
            if taskName in s["name"]:
                matches.append(s)
        if len(matches) > 1:
            exact_match = None
            for m in matches:
                name = m["name"].split("(", 1)[0]
                if name == taskName:
                    assert exact_match is None
                    exact_match = m
            if exact_match is not None:
                matches = [exact_match]
        assert len(matches) == 1
        taskName_to_size[taskName] = matches[0]["size"] / 4

    return taskName_to_size


def systolic_coarsened_families(config):
    def get_systolic_size(benchName):
        # systolic(\d)+__(\d)+u_yc
        import re
        m = re.match(r"systolic(\d+)__(\d+)u_yc", benchName)
        assert m is not None
        return int(m.group(1))

    systolic_size = get_systolic_size(config["BENCH_NAME"])
    #U = config["UNROLL_FACTOR"]
    U = 4 # Makes 4x4 macs
    def mac_name(i, j):
        return f"mac[{i}, {j}]"

    families = []

    mac_family = []
    for big_i in range(0, systolic_size, U):
        for big_j in range(0, systolic_size, U):
            curr = []
            for i in range(big_i, big_i+U):
                for j in range(big_j, big_j+U):
                    curr.append(mac_name(i, j))
            mac_family.append(curr)

    a_feeder_family = []
    for big_i in range(0, systolic_size, U):
        curr = []
        for i in range(big_i, big_i+U):
            curr.append(f"a_feedInputs[{i}]")
        a_feeder_family.append(curr)

    b_feeder_family = []
    for big_i in range(0, systolic_size, U):
        curr = []
        for i in range(big_i, big_i+U):
            curr.append(f"b_feedInputs[{i}]")
        b_feeder_family.append(curr)

    families.append(mac_family)
    families.append(a_feeder_family)
    families.append(b_feeder_family)
    return families


def build_ntt_graph(width, include_feed=False):
    num_stages = width.bit_length() - 1  # log2(width)

    G = nx.DiGraph()
    producer = {}  # (stage, idx) -> producing task label

    # feedInputs produce pipeRegs[0][2n] and pipeRegs[0][2n+1]
    for n in range(width // 2):
        label = f"feedInputs[{n}]"
        if include_feed:
            G.add_node(label)
        producer[(0, 2 * n)] = label
        producer[(0, 2 * n + 1)] = label

    # ntt2 tasks
    stride = width // 2
    for stage in range(num_stages):
        for n in range(width // 2):
            if n % stride < (stride // 2):
                out0 = 2 * n
                out1 = 2 * n + stride
            else:
                out0 = 2 * n + 1 - stride
                out1 = 2 * n + 1

            label = f"ntt2[{stage}, {n}]"
            G.add_node(label)

            # reads pipeRegs[stage][2n] and pipeRegs[stage][2n+1]
            for rd in [(stage, 2 * n), (stage, 2 * n + 1)]:
                src = producer.get(rd)
                if src is not None and (include_feed or not src.startswith("feedInputs")):
                    G.add_edge(src, label)

            # writes pipeRegs[stage+1][out0] and pipeRegs[stage+1][out1]
            producer[(stage + 1, out0)] = label
            producer[(stage + 1, out1)] = label
        stride = stride // 2

    return G


def ntt_coarsened_families(config):
    def split_graph_based_on_hops(G, hops):
        # Starting from the root nodes of G, find all nodes accessible
        # through `hops` edges. G_root = roots + everything within hops.
        # G_rest = the rest.
        roots = [n for n in G.nodes if G.in_degree(n) == 0]
        in_root = set(roots)
        frontier = set(roots)
        for _ in range(hops):
            nxt = set()
            for u in frontier:
                for v in G.successors(u):
                    if v not in in_root:
                        nxt.add(v)
            in_root |= nxt
            frontier = nxt
        G_root = G.subgraph(in_root).copy()
        G_rest = G.subgraph(set(G.nodes) - in_root).copy()
        return G_root, G_rest

    def weakly_connected_components_sorted_in_topo_order(G):
        topo = list(nx.topological_sort(G))
        order = {n: i for i, n in enumerate(topo)}
        comps = []
        for comp in nx.weakly_connected_components(G):
            nodes_sorted = sorted(comp, key=lambda n: order[n])
            comps.append((min(order[n] for n in comp), nodes_sorted))
        comps.sort(key=lambda x: x[0])
        return [nodes for _, nodes in comps]

    def get_coarsened_tasks(G):
        components = weakly_connected_components_sorted_in_topo_order(G)
        return components

    def get_ntt_size(benchName):
        import re
        m = re.match(r"ntt(\d+)__(\d+)u_yc", benchName)
        assert m is not None
        return int(m.group(1))

    ntt_size = get_ntt_size(config["BENCH_NAME"])
    #coarsen_stages = config["UNROLL_FACTOR"]
    coarsen_stages = 2 # ntt4 ntt8

    G = build_ntt_graph(ntt_size, include_feed=False)
    G_rest = G
    coarsened_tasks = []
    while G_rest.number_of_nodes() > 0:
        G_root, G_rest = split_graph_based_on_hops(G_rest, coarsen_stages - 1)
        coarsened_tasks.extend(get_coarsened_tasks(G_root))

    split_by_size = defaultdict(list)
    for ct in coarsened_tasks:
        split_by_size[len(ct)].append(ct)

    fams = []
    for ct_size in sorted(list(split_by_size.keys())):
        if ct_size == 1:
            continue
        fams.append(split_by_size[ct_size])

    return fams


def temp_unroll_coarseneing(G, config):

    class TaskIdxGen:
        def __init__(self, tasks):
            self.idx = 0
            for t in tasks:
                self.idx = max(self.idx, t.idx)
            assert self.idx > 0, "Makes sense"
            self.idx += 1000

        def get(self):
            idx = self.idx
            self.idx += 1
            return idx


    def get_coarsened_task_families(G, coarsened_families):
        label_to_task = {t.label: t for t in G.nodes()}
        assert None not in label_to_task
        cf_tasks = []
        for fam_labels in coarsened_families:
            fam_tasks = []
            for coarsened_labels in fam_labels:
                coarsened_tasks = []
                for label in coarsened_labels:
                    coarsened_tasks.append(label_to_task[label])
                    del label_to_task[label]
                fam_tasks.append(tuple(coarsened_tasks))
            cf_tasks.append(fam_tasks)

        for rem_task in label_to_task.values():
            cf_tasks.append([(rem_task,)])

        return cf_tasks

    def split_edges(G, ct):
        external_edges = []
        internal_edges = []
        external_vars = set()
        internal_vars = set()
        for t in ct:
            for e in G.out_edges(t):
                assert t == e.producer
                if e.producer == e.consumer:
                    # Because it won't have local variables
                    external_edges.append(e)
                    for v in e.vars:
                        assert v not in internal_vars
                        external_vars.add(v)
                elif e.consumer in ct:
                    internal_edges.append(e)
                    for v in e.vars:
                        assert v not in external_vars
                        assert not v.is_mem
                        internal_vars.add(v)
                else:
                    external_edges.append(e)
                    for v in e.vars:
                        assert v not in internal_vars
                        external_vars.add(v)

        internal_vars = list(internal_vars)
        external_vars = list(external_vars)

        return (external_edges, internal_edges, external_vars, internal_vars)

    def task_rank_within_coarsened(ct, internal_edges):
        G_ct = nx.DiGraph()

        idx_to_task = {}
        for t in ct:
            G_ct.add_node(t.idx, data=t)
            idx_to_task[t.idx] = t

        ct_set = set(ct)
        for e in internal_edges:
            if e.producer == e.consumer:
                continue
            if e.cycle_delta != 1:
                assert e.cycle_delta == 0
                continue
            if e.consumer not in ct_set:
                continue
            G_ct.add_edge(e.producer.idx, e.consumer.idx)

        idx_rank = {idx: 0 for idx in G_ct.nodes}

        for idx in nx.topological_sort(G_ct):
            for succ in G_ct.successors(idx):
                idx_rank[succ] = max(idx_rank[succ], idx_rank[idx] + 1)

        return {
            idx_to_task[idx]: rank
            for idx, rank in idx_rank.items()
        }

    def update_external_edges(external_edges, task_to_rank):
        for e in external_edges:
            if e.producer == e.consumer:
                continue
            e.cycle_delta = e.cycle_delta + task_to_rank[e.producer]
            for v in e.vars:
                v.cycle_delta = e.cycle_delta

    def generate_family_task_code(gen, family_i, sample_ct, external_vars, internal_vars):
        coarsen_name = f"coarsen___family_{family_i}"
        return generate_coarsened_task_code(coarsen_name, sample_ct, gen)


    coarsened_families = None
    if config["APPLICATION"] == "systolic":
        coarsened_families = systolic_coarsened_families(config)
    elif config["APPLICATION"] == "ntt":
        coarsened_families = ntt_coarsened_families(config)
    else:
        assert False, f"Unsupported app: {config['APPLICATION']}"

    for fam in coarsened_families:
        assert len({len(ct) for ct in fam}) <= 1, "All coarsen tasks within a family must have the same len"

    def print_fams(fams):
        for i, fam in enumerate(fams):
            print(f"====== FAMILY: {i}")
            print(f"=== len: {len(fam)}")
            for j, ct in enumerate(fam):
                print(f"--> [{i}, {j}] -> ")
                pprint(ct)

    coarsened_families_labels = coarsened_families
    coarsened_families = get_coarsened_task_families(G, coarsened_families)

    task_to_ct = {}
    for family in coarsened_families:
        for ct in family:
            for t in ct:
                assert t not in task_to_ct
                task_to_ct[t] = ct

    ct_to_data = defaultdict(dict)
    for family in coarsened_families:
        for ct in family:
            data = {}
            ct_to_data[ct] = data

            data["external_edges"], data["internal_edges"], data["external_vars"], data["internal_vars"] = split_edges(G, ct)

            data["task_to_rank"] = task_rank_within_coarsened(ct, data["internal_edges"])
            update_external_edges(data["external_edges"], data["task_to_rank"])


    ct_to_ptr = {}
    if True:
        name = "coarsenedTasks.h"
        header_filename = os.path.join(config["OUT_PATH"], name)
        config["GENERATED_FILES_TO_INCLUDE"].append(name)
        gen = CppFileGenerator(header_filename)
        gen.add(CppFileGenerator.Line(''))
        gen.add(CppFileGenerator.Line('// This file contains generated coarsend tasks, do not edit\n'))

        taskIdxGen = TaskIdxGen(G.nodes())

        for i, family in enumerate(coarsened_families):
            assert len(family) > 0
            sample_ct = family[0]
            if len(sample_ct) == 1:
                assert len(family) == 1
                ct_to_ptr[sample_ct[0]] = sample_ct[0]
            else:
                #sample_external_vars = ct_to_data[sample_ct]["external_vars"]
                #sample_internal_vars = ct_to_data[sample_ct]["internal_vars"]
                fam_fn_name, task_args = generate_family_task_code(gen, i, sample_ct, None, None)
                for ct in family:
                    ptr = generate_coarsened_task_and_fix_var_refs(ct, fam_fn_name, task_args, taskIdxGen.get())
                    ct_to_ptr[ct] = ptr

        gen.flush()

    coarsened_raw = {}
    coarsened_raw["tasks"] = sorted(list(set(ct_to_ptr.values())), key=lambda t: t.idx)
    vars = set()
    if True:
        for t in coarsened_raw["tasks"]:
            for _, _, var in t.args:
                vars.add(var)
        vars = sorted(list(vars), key=lambda v: v.idx)
    coarsened_raw["vars"] = vars

    return coarsened_raw

    #ct_edges_to_edges = defaultdict(lambda: defaultdict(list))
    #for data in ct_to_data.values():
    #    for e in data["external_edges"]:
    #        ct_edges_to_edges[(prod_ct, cons_ct)][e.cycle_delta].append(e)


    #if True:
    #    ct_to_idx = {}
    #    idx = 0
    #    for family in coarsened_families:
    #        for ct in family:
    #            ct_to_idx[ct] = idx
    #            idx += 1

    #    G_ct = nx.MultiDiGraph()
    #    for ct,idx in ct_to_idx.items():
    #        G_ct.add_node(idx, label=" + ".join([t.label for t in ct]))

    #    for data in ct_to_data.values():
    #        for e in data["external_edges"]:
    #            prod_ct = ct_to_idx[task_to_ct[e.producer]]
    #            cons_ct = ct_to_idx[task_to_ct[e.consumer]]

    #            G_ct.add_edge(prod_ct, cons_ct, label=f"cd={e.cycle_delta} ({e.producer.label} -> {e.consumer.label})")
    #    name = "coarsened_retimed"
    #    dotfile = os.path.join(config["OUT_PATH"], f"{name}.dot")
    #    pdffile = os.path.join(config["OUT_PATH"], f"{name}.pdf")
    #    nx.drawing.nx_pydot.write_dot(G_ct, dotfile)
    #    subprocess.run(["dot", "-Tpdf", dotfile, "-o", pdffile], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    #    print(f"Generated: {pdffile}")

    #assert False


    #from pprint import pprint
    #pprint(coarsened_families)



    #assert False

    #return None

def temporal_unrolling(G, raw, config):
    if config["ENABLE_COARSENING"] == "FALSE":
        return raw

    allowed_apps = []
    allowed_apps.extend(["ntt", "systolic", "cores", "coresWithCaches"])
    assert config["APPLICATION"] in allowed_apps, f"Unknown application for coarsening: {config['APPLICATION']}"

    if config["APPLICATION"] in ["cores", "coresWithCaches"]:
        return raw


    coarsened_raw = temp_unroll_coarseneing(G, config)

    G_coarsened = get_graph(coarsened_raw)
    if config["GEN_DOT"]:
        generate_dot_graph("temp_unrolling_coarsened", G_coarsened, config)

    coarsen_unroll_factor = max([v.cycle_delta for v in coarsened_raw["vars"]])
    unroll_to_coarsen_ratio = config["UNROLL_FACTOR"]
    unroll_factor = coarsen_unroll_factor * unroll_to_coarsen_ratio
    config["UNROLL_FACTOR"] =  unroll_factor
    print(f"[temporal_unrolling] coarsen_unroll_factor: {coarsen_unroll_factor} -- unroll_to_coarsen_ratio: {unroll_to_coarsen_ratio} -- unroll_factor: {unroll_factor}")

    if False:
        if config["BACKEND"] == "lotus":
            map_tasks(G_coarsened, config)
        elif config["BACKEND"] == "cpu":
            map_tasks_cpu(G_coarsened, config)
        else:
            assert False, "Unknown backend"

    u_raw = unroll_raw(coarsened_raw, config)

    if config["GEN_DOT"]:
        G = get_graph(u_raw)
        generate_dot_graph("temp_unrolling_final", G, config)

    config["ENABLE_COARSENING"] = "DONE"
    return u_raw



class ParseStdIn:
    def parse(n):
        res = {}
        for i in range(n):
            l = sys.stdin.readline().strip()
            (key, val) = l.split(": ")
            res[key] = val
        return res
    @timed
    def get_tasks_and_vars(config):
        include_path = os.path.join(config["OUT_PATH"], config["TASKS_INCLUDE"])
        function_args = parse_functions_with_arg_macros(include_path)
        tasks = {}
        vars = {}
        part_hint = None
        coarse_hint = None
        curr_label = None
        next_var_is_unroll = False

        def parse_val(v: str) -> int:
            try:
                return int(v)
            except ValueError:
                v = v.strip()
                try:
                    decoded = v.encode("utf-8").decode("unicode_escape")
                    return ord(decoded)
                except Exception:
                    raise ValueError(f"Cannot parse value: {v!r}")
        while True:
            l = sys.stdin.readline()
            if l == "":
                break
            type = l.strip()
            if type == "Edge":
                e = ParseStdIn.parse(4)
                edge_idx    = int(e["edgeIdx"])
                typee       = e["type"]
                if "initValue" in e:
                    if "{" in e["initValue"]:
                        init_val = [parse_val(v) for v in e["initValue"][1:-1].split(", ")]
                    else:
                        init_val    = int(e["initValue"])
                else:
                    assert "filename" in e
                    init_val = e["filename"]
                cycle_delta = int(e["cycleDelta"])
                var = LotusVar(edge_idx, typee, init_val, cycle_delta)
                var.is_unroll_var = next_var_is_unroll
                next_var_is_unroll = False
                assert edge_idx not in vars
                vars[edge_idx] = var
            elif type == "Task":
                t = ParseStdIn.parse(4)
                task_idx = int(t["taskIdx"])
                fn       = t["fn"]
                task = LotusTask(task_idx, fn, part_hint, coarse_hint)
                assert task_idx not in tasks
                if curr_label is not None:
                    task.label = curr_label
                    curr_label = None
                tasks[task_idx] = task
                in_vars   = [int(x.strip()) for x in t["inEdges"].split(';')]
                in_types  = [a["type"] for a in function_args[fn]["args"]]
                in_dirs   = [a["direction"] for a in function_args[fn]["args"]]
                in_accs   = [a["access"] for a in function_args[fn]["args"]]
                for in_var, in_type, in_dir, in_acc in zip(in_vars, in_types, in_dirs, in_accs):
                    assert in_var in vars
                    var = vars[in_var]
                    var.typee = in_type
                    assert in_dir in ["IN", "OUT", "INOUT"]
                    assert in_acc in ["FULL", "PARTIAL", "PARTIAL_UNTRACKED"]
                    task.args.append((LotusTask.ARG_DIR[in_dir], LotusTask.ARG_ACCESS[in_acc], var))
                    #if in_acc == "PARTIAL_UNTRACKED":
                    #    in_acc = "PARTIAL"
                    if in_acc == "PARTIAL":
                        if not var.is_mem:
                            assert var.writer is None
                            assert len(var.readers) == 0
                            var.is_mem = True
                        assert var.is_mem
                    elif in_acc == "PARTIAL_UNTRACKED":
                        #assert False
                        if not var.is_mem:
                            assert var.writer is None
                            assert len(var.readers) == 0
                            var.is_mem = True
                            var.is_untracked = True
                        assert var.is_mem and var.is_untracked
                    else:
                        assert not var.is_mem

                    if in_dir in ["IN", "INOUT"]:
                        var.readers.append(task)
                    if in_dir in ["OUT", "INOUT"]:
                        assert var.writer is None, f"var: {var}"
                        var.writer = task
            elif type == "NextTaskLabel":
                e = ParseStdIn.parse(1)
                assert curr_label is None
                curr_label = e["label"]
            elif type == "NextVarIsUnroll":
                next_var_is_unroll = True
            elif type == "NewPart":
                if part_hint is None:
                    part_hint = 0
                    config["HAS_PART_HINTS"] = True
                else:
                    part_hint += 1
            elif type == "NewCoarse":
                if coarse_hint is None:
                    coarse_hint = 0
                    config["HAS_COARSE_HINTS"] = True
                else:
                    coarse_hint += 1
            elif "[DEBUG]" in l:
                pass
            else:
                print(f"ERROR, unknown type!! type={type} -- l: {l}")
                sys.exit(-1)

        # Confirm that if a var is untracked in one,
        # It's untracked in all tasks that use it
        def confirm_var_is_untracked(task, var):
            props = var.writer.get_props_in_args(var)
            assert props is not None
            _, acc = props
            assert acc == LotusTask.ARG_ACCESS.PARTIAL_UNTRACKED
        for var in vars.values():
            if not var.is_untracked:
                continue
            assert var.is_mem
            if var.writer:
                confirm_var_is_untracked(var.writer, var)
            for r in var.readers:
                confirm_var_is_untracked(r, var)

        # Get the size of vars
        types = set()
        for var in vars.values():
            types.add(var.typee)
        sizes = get_type_sizes("sizes", types, config)
        for var in vars.values():
            size, align = sizes[var.typee]
            var.size = size
            var.align = align

        for v in vars.values():
            assert v.size == len(v.init_val), f"Var: type = `{v.typee}` -- size = {v.size} -- init_val = {v.init_val}"

        raw = {}
        raw["tasks"] = [t for _,t in tasks.items()]
        raw["vars"]  = [v for _,v in vars.items()]
        return raw


def unroll_raw(raw, config):
    if config["ENABLE_COARSENING"] == "DONE":
        return raw
    unroll = config['UNROLL_FACTOR']
    assert unroll >= 1, f"Unroll must be >= 1: {unroll}"
    if unroll == 1:
        return raw
    for t in raw["tasks"]:
        for (dir, _, _) in t.args:
            assert dir != LotusTask.ARG_DIR.INOUT, f"{t.fn} has INOUT, not supported with unrolling"
    class IdxGen:
        def __init__(self):
            self.idx = 0
        def next(self):
            o = self.idx
            self.idx += 1
            return o
    # What's returned
    unrolled_raw = {"tasks": [], "vars": []}
    # [task][unroll] -> task
    unrolled_tasks = defaultdict(dict)
    # [var][unroll] -> var
    unrolled_vars = defaultdict(dict)
    # each task becomes #unrolled tasks
    taskIdxGen = IdxGen()
    for t in raw["tasks"]:
        for u in range(unroll):
            nt = LotusTask(taskIdxGen.next(), t.fn, t.part_hint, t.coarse_hint)
            nt.mappedTo = t.mappedTo
            if t.label is not None:
                nt.label = f"{t.label}@{u}"
            nt.unroll_version = u
            unrolled_tasks[t][u] = nt
            unrolled_raw["tasks"].append(nt)
    def copyVar(oldVar, idx, cd):
        nv = LotusVar(idx, oldVar.typee, oldVar.init_val, cd)
        nv.is_unroll_var = oldVar.is_unroll_var
        nv.is_mem       = oldVar.is_mem
        nv.is_untracked = oldVar.is_untracked
        nv.size         = oldVar.size
        nv.align        = oldVar.align
        return nv
    varIdxGen = IdxGen()
    for v in raw["vars"]:
        d = v.cycle_delta
        # Need unroll >= d so the new cycle_delta stays in {0, 1}.
        # Worst case is copy (unroll-1): (unroll-1 + d)//unroll <= 1  iff  d <= unroll.
        assert d <= unroll, f"cycle_delta {d} > unroll {unroll}; can't reduce to {{0,1}}"
        physical_var = None
        if v.is_mem:
            physical_var = copyVar(v, varIdxGen.next(), None)
            physical_var.virtual_vars = []
        for u in range(unroll):
            # Copy u is written by writer-version u and read by reader-version
            # (u + d) % unroll, which lands d real cycles later. The execution
            # offset of that destination is the new cycle_delta, in {0, 1}.
            cd = (u + d) // unroll
            nv = copyVar(v, varIdxGen.next(), cd)
            nv.physical_var = physical_var
            if True:
                # Originally a cross-cycle edge (d >= 1) but this copy collapsed
                # to a same-cycle edge (cd == 0) within one unrolled execution.
                weak_can_coarsen = (d >= 1) and (cd == 0)
                # Self-referencing edges cause some ordering issues, just ignore them
                stronger_can_coarsen = weak_can_coarsen and (v.writer not in v.readers)
                nv.can_coarsen = stronger_can_coarsen
            if nv.can_coarsen:
                assert cd == 0
            nv.unroll_version = u
            if physical_var:
                physical_var.virtual_vars.append(nv)
            unrolled_vars[v][u] = nv
            unrolled_raw["vars"].append(nv)
    def get_var_unrolled(u, var, dir):
        assert dir != LotusTask.ARG_DIR.INOUT, "Currently INOUT is not supported with unrolling"
        d = var.cycle_delta
        if dir == LotusTask.ARG_DIR.OUT:
            # Writer version u writes its own copy.
            var_id = u % unroll
        elif dir == LotusTask.ARG_DIR.IN:
            # Reader version u reads the copy written d cycles earlier.
            var_id = (u - d) % unroll
        else:
            assert False, "Don't know how to handle other directions"
        use_var = unrolled_vars[var][var_id]
        return use_var
    for t in raw["tasks"]:
        has_unroll_var = t.has_unroll_var()
        for u in range(unroll):
            ut = unrolled_tasks[t][u]
            for (dir, access, var) in t.args:
                if has_unroll_var and (var.writer in var.readers):
                    use_var = unrolled_vars[var][u]
                    use_var.cycle_delta = 1
                else:
                    use_var = get_var_unrolled(u, var, dir)
                # Add var to task
                ut.args.append((dir, access, use_var))
                # Add task to var
                if dir in [LotusTask.ARG_DIR.IN, LotusTask.ARG_DIR.INOUT]:
                    use_var.readers.append(ut)
                if dir in [LotusTask.ARG_DIR.OUT, LotusTask.ARG_DIR.INOUT]:
                    assert use_var.writer is None, f"var: {use_var}"
                    use_var.writer = ut
    return unrolled_raw


def generate_coarsened_task_code(signature, sample_coarsen_tasks, gen):
    if isinstance(signature, str):
        coarsen_name = signature
    else:
        def sig_to_txt(sig):
            sig = sig[1]
            ss = []
            for s in sig:
                s = '_'.join([str(z) for z in s])
                ss.append(s)
            ss = "__".join(ss)
            return ss
        sig_txt = sig_to_txt(signature)
        coarsen_name = "__THEN__".join([f"{t.fn}_uv{t.unroll_version}" for t in sample_coarsen_tasks])
        coarsen_name = f"coarsen___{coarsen_name}___{sig_txt}"

    output_vars = defaultdict(list)
    input_vars  = defaultdict(list)
    if True:
        for task_idx, task in enumerate(sample_coarsen_tasks):
            for var_idx, (dir, access, var) in enumerate(task.args):
                assert dir    not in [LotusTask.ARG_DIR.INOUT]
                #assert access not in [LotusTask.ARG_ACCESS.PARTIAL, LotusTask.ARG_ACCESS.PARTIAL_UNTRACKED]
                var = var.get_physical()
                if dir == LotusTask.ARG_DIR.IN:
                    input_vars[var].append((task_idx, var_idx))
                elif dir == LotusTask.ARG_DIR.OUT:
                    output_vars[var].append((task_idx, var_idx))
                else:
                    assert False
        for ov in output_vars.values():
            ov.sort()
        for iv in input_vars.values():
            iv.sort()

    coarsen_task_inputs   = set()
    coarsen_task_outputs  = set()
    coarsen_internal_vars = []
    if True:
        # Categorize variables
        ambigeous_vars = set()
        for in_var in input_vars.keys():
            if (not in_var.is_mem) and (in_var in output_vars):
                ambigeous_vars.add(in_var)
                continue
            #assert in_var.is_mem or (len(input_vars[in_var]) == 1)
            coarsen_task_inputs.add(in_var)

        for out_var in output_vars.keys():
            if (not out_var.is_mem) and (out_var in input_vars):
                ambigeous_vars.add(out_var)
                continue
            #assert out_var.is_mem or (len(output_vars[out_var]) == 1)
            coarsen_task_outputs.add(out_var)

        # Now, figure out whether ambigeous vars are
        # 1) Same-cycle edge (internal variable)
        # 2) Cross-cycle edge (coarsen_task_io)
        for v in ambigeous_vars:
            assert not v.is_mem
            #assert len(input_vars[v]) == 1
            #assert len(output_vars[v]) == 1
            in_task_idx , _  = input_vars[v][0]
            out_task_idx, _  = output_vars[v][0]
            if out_task_idx < in_task_idx:
                # If there's a reader outside the task, it's only an OUT, otherwise internal
                reader_outside_ct = False
                for _vv in v.get_virtuals():
                    for _r in _vv.readers:
                        if _r not in sample_coarsen_tasks:
                            reader_outside_ct = True
                            break
                if reader_outside_ct:
                    coarsen_task_outputs.add(v)
                else:
                    # Producer before consumer
                    coarsen_internal_vars.append(v)
            else:
                # Producer after consumer
                # OR same task produces and consumes
                # Regardless, its IO
                coarsen_task_inputs.add(v)
                coarsen_task_outputs.add(v)

        # Sort for efficency
        coarsen_task_inputs  = sorted(list(coarsen_task_inputs), key= lambda v: input_vars[v][0])
        coarsen_task_outputs = sorted(list(coarsen_task_outputs), key= lambda v: output_vars[v][0] if v in output_vars else input_vars[v][0])
        # NOTE: For internal we assume write happens first, asserted below
        #       Otherwise, this is a cross-cycle edge that's not internal
        coarsen_internal_vars = list(coarsen_internal_vars)
        coarsen_internal_vars.sort(key= lambda v: output_vars[v][0])
        for internal_var in coarsen_internal_vars:
            write_idx = output_vars[internal_var]
            assert len(write_idx) == 1, "Doesn't have to be, but expect it"
            write_idx = write_idx[0]
            read_idx = input_vars[internal_var]
            assert len(read_idx) == 1, "Doesn't have to be, but expect it"
            read_idx = read_idx[0]
            assert write_idx < read_idx, f"Write has to happen before read, otherwise its not internal. task_idx shows ordering"

    coarsen_task_io = []
    if True:
        for input_var in coarsen_task_inputs:
            for task_idx, var_idx in input_vars[input_var]:
                dir, access, expected_var = sample_coarsen_tasks[task_idx].args[var_idx]
                expected_var = expected_var.get_physical()
                assert expected_var == input_var
                assert dir == LotusTask.ARG_DIR.IN
                coarsen_task_io.append((dir, access, (task_idx, var_idx)))
        for output_var in coarsen_task_outputs:
            for task_idx, var_idx in output_vars[output_var]:
                dir, access, expected_var = sample_coarsen_tasks[task_idx].args[var_idx]
                expected_var = expected_var.get_physical()
                assert expected_var == output_var
                assert dir == LotusTask.ARG_DIR.OUT
                coarsen_task_io.append((dir, access, (task_idx, var_idx)))


    # Note: while I'm using the var's index here,
    #       this is just for naming within the function.
    #       The function will still be able to generalize for all patterns
    def var_to_name(v, dir):
        if v in coarsen_internal_vars:
            return f"var_{v.idx}"
        if (dir == LotusTask.ARG_DIR.IN) and (v in coarsen_task_inputs):
            return f"var_{v.idx}_{dir.name}"
        # Force output (even if input, SC coarsen that's going to other tasks)
        assert v in coarsen_task_outputs
        dir = LotusTask.ARG_DIR.OUT
        return f"var_{v.idx}_{dir.name}"


    function_args = []
    if True:
        vars_done = set()
        for dir, access, (task_idx, var_idx) in coarsen_task_io:
            expected_dir, expected_access, var = sample_coarsen_tasks[task_idx].args[var_idx]
            assert expected_dir == dir
            assert expected_access == access
            var = var.get_physical()
            k = (dir, access, var)
            if k in vars_done:
                continue
            function_args.append((f"\n    ARG_UNPAREN({dir.name}, {access.name}, ({var.typee}))", f"{var_to_name(var, dir)}"))
            vars_done.add(k)

    gen.add(CppFileGenerator.FunctionSignature("TASK", coarsen_name, function_args, False))
    functionScope = CppFileGenerator.Scope()
    gen.add(functionScope)

    for v in coarsen_internal_vars:
        functionScope.add(CppFileGenerator.Line(f"{v.typee} {var_to_name(v, None)}" + "{};"))

    for t in sample_coarsen_tasks:
        args = []
        for (dir, _, v) in t.args:
            v = v.get_physical()
            args.append(var_to_name(v, dir))
        functionScope.add(CppFileGenerator.Line(f"// Label: {t.label}"))
        functionScope.add(CppFileGenerator.FunctionCall(t.fn, args))

    return (coarsen_name, coarsen_task_io)

def generate_coarsened_task_and_fix_var_refs(coarsen_tasks, coarsen_name, coarsen_args, task_idx):
    hints = set()
    if True:
        for t in coarsen_tasks:
            hints.add((t.part_hint, t.coarse_hint))
        assert len(hints) == 1, f"Hints: {hints}"
        hints, = hints

    coarsen_task = LotusTask(task_idx, coarsen_name, hints[0], hints[1])
    if True:
        label = None
        labels = [t.label for t in coarsen_tasks]
        assert all(x is None for x in labels) or all(isinstance(x, str) for x in labels)
        if labels[0] is not None:
            label = "+".join(labels)
        coarsen_task.label = label

    fixup_var_to_dirs = defaultdict(list)

    added = set()
    for dir, access, (task_idx, var_idx) in coarsen_args:
        #assert access not in [LotusTask.ARG_ACCESS.PARTIAL, LotusTask.ARG_ACCESS.PARTIAL_UNTRACKED]
        assert dir    not in [LotusTask.ARG_DIR.INOUT]

        prev_arg_owner = coarsen_tasks[task_idx]

        prev_dir, prev_access, arg_var = prev_arg_owner.args[var_idx]
        assert prev_dir == dir
        assert prev_access == access
        assert arg_var.virtual_vars is None, "Must be virtual itself"
        fixup_var_to_dirs[arg_var].append(dir)

        ky = (dir, access, arg_var.get_physical())
        if ky in added:
            continue
        added.add(ky)
        # 1. Add it to args
        coarsen_task.args.append((dir, access, arg_var))


    # Change var references
    for v, dirs in fixup_var_to_dirs.items():
        isWriter = False
        if v.writer in coarsen_tasks:
            v.writer = None
            isWriter = True
        isReader = False
        for t in coarsen_tasks:
            if t in v.readers:
                isReader = True
                v.readers.pop(v.readers.index(t))

        # Before coarsening could be read, but after coarsening no read
        # For example: A-0>B and A-0->C. If AB, then AB is not a reader + AB-0->C.
        for d in dirs:
            if d == LotusTask.ARG_DIR.OUT:
                assert isWriter
                v.writer = coarsen_task
            elif d == LotusTask.ARG_DIR.IN:
                assert isReader
                v.readers.append(coarsen_task)
            else:
                assert False
        assert isWriter or isReader

    # NOTE(farese): Not sure if this is hacky. Sometimes there's a mem dep
    #               that gets converted into a same-cycle self-reference edge, change these to cross-cycle
    for _, _, var in coarsen_task.args:
        if var.cycle_delta >= 1:
            continue
        assert var.cycle_delta == 0
        if var.writer not in var.readers:
            continue
        assert len(var.readers) == 1
        var.cycle_delta = 1

    return coarsen_task

@timed
def get_generic_coarsen_candidate(G, config):
    # Group tasks based on "coarsenable" edges, ignores order edges
    coarsen_graph = nx.DiGraph()
    if True:
        blacklist = set()
        for t in G.nodes():
            if "node_" in t.fn:
                blacklist.add(t)
            coarsen_graph.add_node(t.idx)

        for e in G.edges():
            #orderEdge = ((e.cycle_delta == 0) and ("Order" in e.typee))
            # TODO(farese): Think about whether we also need to consider order edges here
            if e.can_coarsen():
                assert e.cycle_delta == 0
                if e.producer in blacklist:
                    continue
                if e.consumer in blacklist:
                    continue
                coarsen_graph.add_edge(e.producer.idx, e.consumer.idx)


    def calcBytes(vars):
        def next_multiple_of_4(n):
            return ((n + 3) // 4) * 4
        # TODO(farese): can also consider packing and parents
        return sum([next_multiple_of_4(v.bytes()) for v in vars])

    def is_valid_ct(ct):
        ct_cross_tile = set()
        for t in ct:
            for d, _, v in t.args:
                if d in [LotusTask.ARG_DIR.OUT, LotusTask.ARG_DIR.INOUT]:
                    continue
                if v.writer is None:
                    continue
                if config["HAS_PART_HINTS"] and (v.writer.part_hint == t.part_hint):
                    continue
                assert not v.is_mem
                ct_cross_tile.add(v)
        ct_bytes = calcBytes(ct_cross_tile)
        return ct_bytes <= (14*4)
    def split_in_half(lst):
        mid = len(lst) // 2
        return lst[:mid], lst[mid:]


    notAllowedDir    = [LotusTask.ARG_DIR.INOUT]
    #notAllowedAccess = [LotusTask.ARG_ACCESS.PARTIAL, LotusTask.ARG_ACCESS.PARTIAL_UNTRACKED]
    notAllowedAccess = []
    coarsenedTasks = []
    #coarsenedTasksRanks = []
    ratio_of_split_by_hint = []
    if True:
        components = list(nx.weakly_connected_components(coarsen_graph))
        for comp in components:
            if len(comp) == 1:
                continue
            # More than one
            H = coarsen_graph.subgraph(comp)
            assert nx.is_directed_acyclic_graph(H)
            ordered = list(nx.lexicographical_topological_sort(H, key=lambda idx: idx))
            coarsenedTask = [G.get_node(idx) for idx in ordered]
            skipGrb = False
            for t in coarsenedTask:
                skipGrb = skipGrb or any([d in notAllowedDir    for (d, _, _) in t.args])
                skipGrb = skipGrb or any([a in notAllowedAccess for (_, a, _) in t.args])
            if skipGrb:
                continue
            hint_to_tasks = defaultdict(list)
            for t in coarsenedTask:
                hint_to_tasks[t.coarse_hint].append(t)
            ratio_of_split_by_hint.append(len(hint_to_tasks))
            #ranks = dag_ranks_longest_path(H)
            #ranks = {G.get_node(idx): rank for idx, rank in ranks.items()}
            for ct in hint_to_tasks.values():
                coarsenedTasks.append(ct)
                #coarsenedTasksRanks.append(ranks)

    print(f"[get_coarsen_candidates] Number of coarsenedTasks = {len(coarsenedTasks)}")
    if True:
        ct_stats = stats_int(ratio_of_split_by_hint)
        print(f"Stats for Coarsened Tasks split Due to Coarse Hint ====== ")
        for s in ["min", "max", "mean", "median", "std_dev"]:
            print(f"    {s:<{10}} = {ct_stats[s]}")

    if len(coarsenedTasks) == 0:
        return []

    #assert len(coarsenedTasks) == len(coarsenedTasksRanks)
    #coarsenedTasks_guided = []
    #for ct, ranks in zip(coarsenedTasks, coarsenedTasksRanks):
    #    ct_by_layer = []
    #    if True:
    #        for t in ct:
    #            r = ranks[t]
    #            while r >= len():
    #                ct_by_layer.append([])
    #            ct_by_layer[r].append(t)

    #    # Now we construct actual coarsen task candidates.
    #    # For each pass, for each layer pick only one task.
    #    # At the root, you pick the task that's first
    #    # At other levels, you pick one task that communicates the most
    #    # With accumulating tasks

    #    current_batch = []


    # Split based on corss-tile input size
    coarsenedTasks_unbounded = coarsenedTasks
    coarsenedTasks = []
    ratio_tasks = []
    if True:
        for ct in coarsenedTasks_unbounded:
            tests = [ct]
            ts = 0
            while len(tests):
                test = tests.pop()
                if is_valid_ct(test):
                    coarsenedTasks.append(test)
                    ts += 1
                else:
                    a,b = split_in_half(test)
                    if len(a) > 1:
                        tests.append(a)
                    if len(b) > 1:
                        tests.append(b)
            ratio_tasks.append(ts)

    print(f"\n[get_coarsen_candidates] Number of coarsenedTasks = {len(coarsenedTasks)}")
    if True:
        ct_stats = stats_int(ratio_tasks)
        print(f"Stats for Coarsened Tasks split Due to Cross-Tile Input Bytes ====== ")
        for s in ["min", "max", "mean", "median", "std_dev"]:
            print(f"    {s:<{10}} = {ct_stats[s]}")


    return coarsenedTasks

def get_systolic_coarsen_candidates(G, config):
    def gen_coarsen_labels(N, unroll):
        def mac_name(i, j, t):
            return f"mac[{i}, {j}]@{t}"
        cs = []
        for big_i in range(0, N, unroll):
            for t in range(unroll):
                for m in ["a", "b"]:
                    cs.append([f"{m}_feedInputs[{i}]@{t}" for i in range(big_i, big_i+unroll)])

        for big_i in range(0, N, unroll):
            for big_j in range(0, N, unroll):
                # Create one coarsened task per phase
                for phase in range(unroll):
                    coarsened_task = []
                    # k = shell level
                    prev_t = None
                    for k in range(unroll):

                        t = (k + phase) % unroll

                        if (prev_t is not None) and (t < prev_t) and len(coarsened_task):
                            cs.append(coarsened_task)
                            coarsened_task = []

                        prev_t = t

                        i0 = big_i + k
                        j0 = big_j + k

                        # diagonal element
                        name = mac_name(i0, j0, t)
                        coarsened_task.append(name)

                        # remaining row
                        for j in range(j0 + 1, big_j + unroll):
                            name = mac_name(i0, j, t)
                            coarsened_task.append(name)

                        # remaining column
                        for i in range(i0 + 1, big_i + unroll):
                            name = mac_name(i, j0, t)
                            coarsened_task.append(name)

                    if len(coarsened_task):
                        cs.append(coarsened_task)
        return cs

    def get_systolic_size(benchName):
        # systolic(\d)+__(\d)+u_yc
        import re
        m = re.match(r"systolic(\d+)__(\d+)u_yc", benchName)
        assert m is not None
        return int(m.group(1))

    coarsen_labels = gen_coarsen_labels(get_systolic_size(config["BENCH_NAME"]), config["UNROLL_FACTOR"])
    task_to_label = {t.label: t for t in G.nodes()}
    assert None not in task_to_label

    coarsenedTasks = []
    for cl in coarsen_labels:
        ct = []
        for l in cl:
            ct.append(task_to_label[l])
            del task_to_label[l]
        coarsenedTasks.append(ct)

    def calcBytes(vars):
        def next_multiple_of_4(n):
            return ((n + 3) // 4) * 4
        # TODO(farese): can also consider packing and parents
        return sum([next_multiple_of_4(v.bytes()) for v in vars])

    def is_valid_ct(ct):
        ct_cross_tile = set()
        for t in ct:
            for d, _, v in t.args:
                if d in [LotusTask.ARG_DIR.OUT, LotusTask.ARG_DIR.INOUT]:
                    continue
                if v.writer is None:
                    continue
                if config["HAS_PART_HINTS"] and (v.writer.part_hint == t.part_hint):
                    continue
                assert not v.is_mem
                ct_cross_tile.add(v)
        ct_bytes = calcBytes(ct_cross_tile)
        return ct_bytes <= (14*4)
    def split_in_half(lst):
        mid = len(lst) // 2
        return lst[:mid], lst[mid:]

    # Split based on corss-tile input size
    coarsenedTasks_unbounded = coarsenedTasks
    coarsenedTasks = []
    ratio_tasks = []
    if True:
        for ct in coarsenedTasks_unbounded:
            tests = [ct]
            ts = 0
            while len(tests):
                test = tests.pop()
                if is_valid_ct(test):
                    coarsenedTasks.append(test)
                    ts += 1
                else:
                    a,b = split_in_half(test)
                    if len(a) > 1:
                        tests.append(a)
                    if len(b) > 1:
                        tests.append(b)
            ratio_tasks.append(ts)

    print(f"\n[get_coarsen_candidates] Number of coarsenedTasks = {len(coarsenedTasks)}")
    if True:
        ct_stats = stats_int(ratio_tasks)
        print(f"Stats for Coarsened Tasks split Due to Cross-Tile Input Bytes ====== ")
        for s in ["min", "max", "mean", "median", "std_dev"]:
            print(f"    {s:<{10}} = {ct_stats[s]}")

    #for i, ct in enumerate(coarsen_tasks):
    #    cl = [t.label for t in ct]
    #    print(f"[{i}] ---> {cl}")

    return coarsenedTasks


@timed
def get_coarsen_candidates(G, config):
    if config["APPLICATION"] == None:
        return (True, get_generic_coarsen_candidate(G, config))

    allowed_apps = []
    allowed_apps.extend(["ntt", "nttRetimed", "nttVirtuzlized"])
    allowed_apps.extend(["systolic", "systolicRetimed", "systolicVirtuzlized"])
    allowed_apps.extend(["cores", "coresWithCaches"])
    assert config["APPLICATION"] in allowed_apps, f"Unknown application for coarsening: {config['APPLICATION']}"

    if config["APPLICATION"] == "systolic":
        return (False, get_systolic_coarsen_candidates(G, config))
    else:
        return (True, get_generic_coarsen_candidate(G, config))

def __sc_cycles_in_coarsened_graph(G, super_nodes):
    same_cycle_graph = nx.DiGraph()
    if True:
        for sni in range(len(super_nodes.super_nodes)):
            same_cycle_graph.add_node(sni)

        for e in G.edges():
            if e.cycle_delta == 1:
                continue
            # Only same-cycle edges
            prod_sni = super_nodes.task_to_sni[e.producer]
            cons_sni = super_nodes.task_to_sni[e.consumer]
            if prod_sni == cons_sni:
                continue
            same_cycle_graph.add_edge(prod_sni, cons_sni)

    cycles = []
    if True:
        components = list(nx.strongly_connected_components(same_cycle_graph))
        for snis in components:
            if len(snis) == 1:
                continue
            cycles.append(snis)
    return cycles

def _sc_cycles_in_coarsened_graph(G, super_nodes):
    same_cycle_graph = nx.DiGraph()
    if True:
        same_cycle_graph.add_nodes_from(range(len(super_nodes.super_nodes)))

        for e in G.edges():
            if e.cycle_delta == 1:
                continue
            # Only same-cycle edges
            prod_sni = super_nodes.task_to_sni[e.producer]
            cons_sni = super_nodes.task_to_sni[e.consumer]
            if prod_sni == cons_sni:
                continue
            same_cycle_graph.add_edge(prod_sni, cons_sni)

    return not nx.is_directed_acyclic_graph(same_cycle_graph)

def __sc_cycles_in_coarsened_graph(G, super_nodes):
    task_to_sni = super_nodes.task_to_sni
    n = len(super_nodes.super_nodes)

    adj = [set() for _ in range(n)]
    indeg = [0] * n

    for e in G.edges():
        if e.cycle_delta == 1:
            continue
        u = task_to_sni[e.producer]
        v = task_to_sni[e.consumer]
        if u == v:
            continue
        # dedupe to keep indeg correct + reduce work
        if v not in adj[u]:
            adj[u].add(v)
            indeg[v] += 1

    # Kahn's algorithm for DAG check
    from collections import deque
    q = deque([i for i, d in enumerate(indeg) if d == 0])
    seen = 0
    while q:
        u = q.popleft()
        seen += 1
        for v in adj[u]:
            indeg[v] -= 1
            if indeg[v] == 0:
                q.append(v)

    # if we couldn't process all nodes, there's a cycle
    return seen != n

def __cs_cycles_in_coarsened_graph(G, super_nodes):
    pairs_to_cd = {}

    for e in G.edges():
        if "Order" == e.typee:
            continue
        prod_sni = super_nodes.task_to_sni[e.producer]
        cons_sni = super_nodes.task_to_sni[e.consumer]
        if (prod_sni == cons_sni) and (e.cycle_delta == 0):
            continue
        k = (prod_sni, cons_sni)
        if k in pairs_to_cd:
            if e.cycle_delta != pairs_to_cd[k]:
                return True
        else:
            pairs_to_cd[k] = e.cycle_delta

    return False

from dataclasses import dataclass
from itertools import combinations


def get_coarsened_task_sig(coarsenedTask):
    # This function returns signature for each task
    # If two tasks share the same signature, they can also share the same gen function code
    # Which saves i-cache capacity
    signature = []
    # 1) A simple check for function names
    signature.append(tuple([t.fn for t in coarsenedTask]))

    # 2) However, not because they share the same atoms that means they're the same.
    #    For example: imagine tasks {A, B, C, D} all use computation function ntt2
    #                 A coarsened task could be    output(A)[0]->input(C)[0]
    #                                           OR output(A)[0]->input(C)[1]
    task_to_idx = {i:t for i,t in enumerate(coarsenedTask)}
    var_to_idx  = {}
    if True:
        var_idx_gen = 0
        for t in coarsenedTask:
            for _, _, v in t.args:
                v = v.get_physical()
                if v not in var_to_idx:
                    var_to_idx[v] = var_idx_gen
                    var_idx_gen += 1

    args_sig = []
    if True:
        for t in coarsenedTask:
            args_sig.append([])
            for _, _, v in t.args:
                v = v.get_physical()
                args_sig[-1].append(var_to_idx[v])
            args_sig[-1] = tuple(args_sig[-1])
    signature.append(tuple(args_sig))
    return tuple(signature)


from collections import deque
from dataclasses import dataclass
from itertools import combinations


class Permute:
    @dataclass(frozen=True)
    class Proposal:
        group: tuple
        remaining: tuple
    def __init__(self, items, min_size=2):
        self.items = tuple(items)
        self.min_size = min_size
        assert self.min_size >= 2
        self._gen = self._make_gen(self.items)
        self._started = False
        self._done = False

    def next(self):
        if self._done:
            return None
        try:
            if not self._started:
                self._started = True
                return next(self._gen)
            return self.send(False)
        except StopIteration:
            self._done = True
            return None

    def send(self, accepted):
        if self._done:
            return None
        if not self._started:
            return self.next()
        try:
            return self._gen.send(bool(accepted))
        except StopIteration:
            self._done = True
            return None

    def _make_gen(self, items):
        min_size = self.min_size

        def rec(remaining):
            if len(remaining) < min_size:
                return

            anchor, rest = remaining[0], remaining[1:]

            for k in range(len(remaining), min_size - 1, -1):
                for comb_rest in combinations(rest, k - 1):
                    group = (anchor,) + comb_rest
                    group_set = set(group)
                    new_remaining = tuple(x for x in remaining if x not in group_set)

                    accepted = yield Permute.Proposal(group, new_remaining)

                    if accepted:
                        yield from rec(new_remaining)
                        return

        yield from rec(items)


class CoarseningHistory:
    class HistApplier:
        def __init__(self, hist, ct):
            self.hist = hist
            self.ct = ct

        def _apply(self, recipe, ct):
            return [ct[i] for i in recipe]

        def __repr__(self):
            return self.__str__()

        def __str__(self):
            og = [t.useful_name() for t in self.ct]
            other = []
            for recipe in self.hist:
                ct = self._apply(recipe, self.ct)
                other.append([t.useful_name() for t in ct])
            return f"{og} ==> {other}"

        def apply(self, ct):
            assert len(ct) > 0
            assert isinstance(ct[0], LotusTask)
            return [self._apply(recipe, ct) for recipe in self.hist]

    class HistAccum:
        def __init__(self, sig, ct):
            assert len(ct) > 0
            assert isinstance(ct[0], LotusTask)
            self.ct = ct
            self.sig = sig
            self.history = []

            # Big improvement over repeated self.ct.index(t)
            self.task_to_idx = {t: i for i, t in enumerate(ct)}

        def accept(self, a_ct):
            assert len(a_ct) > 0
            assert isinstance(a_ct[0], LotusTask)
            self.history.append([self.task_to_idx[t] for t in a_ct])

        def applier(self):
            return CoarseningHistory.HistApplier(self.history, self.ct)

    def __init__(self):
        self.hist = {}
        self.accum = None

    def start_new_hist(self, sig, ct):
        assert self.accum is None
        self.accum = CoarseningHistory.HistAccum(sig, ct)

    def accept(self, a_ct):
        assert self.accum is not None
        self.accum.accept(a_ct)

    def end_hist(self):
        assert self.accum is not None
        self.hist[self.accum.sig] = self.accum.applier()
        self.accum = None

    def get_hist(self, sig):
        return self.hist.get(sig, None)

    def print_state(self):
        for sig, hi in self.hist.items():
            print(f"sig: {sig[0]} ------ hist: {hi}")


class CoarseningState:
    """
    Incremental quotient-graph contraction state.

    This replaces repeatedly doing:

        SuperNodes.create(G, proposed)
        sc_cycles_in_coarsened_graph(G, super_nodes)
        cs_cycles_in_coarsened_graph(G, super_nodes)

    with:

        state.can_merge(tasks)
        state.merge(tasks)

    Assumption:
        Coarsening is monotonic. Once tasks are merged, they are never split.
    """

    def __init__(self, G, validate_initial=True):
        self.G = G

        self.tasks = list(G.nodes())
        self.num_initial_tasks = len(self.tasks)

        # Current super-node mapping.
        self.task_to_sni = {t: i for i, t in enumerate(self.tasks)}
        self.super_nodes = [{t} for t in self.tasks]

        # Original edge indices by original task.
        self.out_edges = {t: [] for t in self.tasks}
        self.in_edges = {t: [] for t in self.tasks}

        self.edges = list(G.edges())

        for e in self.edges:
            self.out_edges[e.producer].append(e)
            self.in_edges[e.consumer].append(e)

        # Same-cycle quotient graph: only cycle_delta == 0 edges.
        self.sc_succ = [set() for _ in self.tasks]
        self.sc_pred = [set() for _ in self.tasks]

        # Cross/same-cycle pair-delta masks.
        #
        # mask bit 0: saw cycle_delta == 0
        # mask bit 1: saw cycle_delta == 1
        #
        # Conflict iff mask == 0b11.
        self.cs_pair_mask = {}

        # Reverse indices so we can delete affected pair masks quickly.
        self.cs_out_keys = [set() for _ in self.tasks]
        self.cs_in_keys = [set() for _ in self.tasks]

        self._build_initial_sc_graph()
        self._build_initial_cs_masks()

        if validate_initial:
            assert not self._full_sc_cycle_check(), "Initial same-cycle quotient graph has a cycle"
            assert not self._full_cs_conflict_check(), "Initial CS pair-delta conflict exists"

    # ----------------------------------------------------------------------
    # Initial construction
    # ----------------------------------------------------------------------

    def _build_initial_sc_graph(self):
        for e in self.edges:
            if e.cycle_delta != 0:
                continue

            u = self.task_to_sni[e.producer]
            v = self.task_to_sni[e.consumer]

            if u == v:
                continue

            if v not in self.sc_succ[u]:
                self.sc_succ[u].add(v)
                self.sc_pred[v].add(u)

    def _build_initial_cs_masks(self):
        for e in self.edges:
            if e.typee == "Order":
                continue

            u = self.task_to_sni[e.producer]
            v = self.task_to_sni[e.consumer]

            if u == v and e.cycle_delta == 0:
                continue

            self._add_cs_pair_mask((u, v), e.cycle_delta)

    # ----------------------------------------------------------------------
    # Public API
    # ----------------------------------------------------------------------

    def can_merge(self, tasks):
        """
        Return True iff contracting the supernodes containing `tasks`
        does not introduce either:
            1. same-cycle quotient cycle
            2. mixed cycle_delta conflict between same producer/consumer pair
        """

        if len(tasks) < 2:
            return True

        snis = {self.task_to_sni[t] for t in tasks}

        # Already in same supernode.
        if len(snis) <= 1:
            return True

        if self._merge_creates_sc_cycle(snis):
            return False

        if self._merge_creates_cs_conflict(snis):
            return False

        return True

    def merge(self, tasks):
        """
        Permanently contract the supernodes containing `tasks`.

        Caller should first call can_merge(tasks).
        """

        if len(tasks) < 2:
            return

        snis = {self.task_to_sni[t] for t in tasks}

        if len(snis) <= 1:
            return

        rep = min(snis)
        old_snis = set(snis)
        dead_snis = old_snis - {rep}

        new_members = set()
        for sni in old_snis:
            new_members.update(self.super_nodes[sni])

        # Remove old CS pair masks involving any merged supernode.
        self._remove_cs_keys_touching(old_snis)

        # Update task mapping.
        for t in new_members:
            self.task_to_sni[t] = rep

        # Update super-node membership.
        self.super_nodes[rep] = new_members
        for sni in dead_snis:
            self.super_nodes[sni] = set()

        # Update same-cycle quotient graph.
        self._commit_sc_merge(old_snis, rep)

        # Rebuild only CS pair masks involving the new representative.
        self._rebuild_cs_masks_for_rep(rep)

    def current_coarsened_tasks(self):
        return [list(sn) for sn in self.super_nodes if len(sn) > 0]

    # ----------------------------------------------------------------------
    # Same-cycle cycle check
    # ----------------------------------------------------------------------

    def _merge_creates_sc_cycle(self, snis):
        """
        Contracting S creates a quotient cycle iff there exists a path:

            S -> outside nodes -> S

        Direct S -> S edges are ignored because the original full checker ignored
        u == v edges after coarsening.
        """

        S = set(snis)

        frontier = []
        seen = set()

        for u in S:
            for v in self.sc_succ[u]:
                if v in S:
                    continue
                if v not in seen:
                    seen.add(v)
                    frontier.append(v)

        while frontier:
            u = frontier.pop()

            for v in self.sc_succ[u]:
                if v in S:
                    return True

                if v not in seen:
                    seen.add(v)
                    frontier.append(v)

        return False

    def _commit_sc_merge(self, old_snis, rep):
        S = set(old_snis)

        new_succ = set()
        new_pred = set()

        for u in S:
            new_succ.update(self.sc_succ[u])
            new_pred.update(self.sc_pred[u])

        new_succ.difference_update(S)
        new_pred.difference_update(S)

        # Remove old references.
        for u in S:
            for v in list(self.sc_succ[u]):
                self.sc_pred[v].discard(u)
            for v in list(self.sc_pred[u]):
                self.sc_succ[v].discard(u)

        # Clear old adjacency.
        for u in S:
            self.sc_succ[u].clear()
            self.sc_pred[u].clear()

        # Add redirected edges.
        self.sc_succ[rep] = new_succ
        self.sc_pred[rep] = new_pred

        for p in new_pred:
            self.sc_succ[p].add(rep)

        for q in new_succ:
            self.sc_pred[q].add(rep)

    # ----------------------------------------------------------------------
    # CS conflict check
    # ----------------------------------------------------------------------

    def _merge_creates_cs_conflict(self, snis):
        """
        Simulate the merge locally and check whether any pair obtains both
        cycle_delta == 0 and cycle_delta == 1.

        Only edges incident to the merged supernodes can affect the result.
        """

        S = set(snis)
        rep = min(S)

        local_masks = {}

        affected_original_tasks = set()
        for sni in S:
            affected_original_tasks.update(self.super_nodes[sni])

        for e in self._incident_edges_for_tasks(affected_original_tasks):
            if e.typee == "Order":
                continue

            u = self.task_to_sni[e.producer]
            v = self.task_to_sni[e.consumer]

            if u in S:
                u = rep
            if v in S:
                v = rep

            if u == v and e.cycle_delta == 0:
                continue

            k = (u, v)
            bit = 1 << e.cycle_delta
            local_masks[k] = local_masks.get(k, 0) | bit

            if local_masks[k] == 0b11:
                return True

        return False

    def _rebuild_cs_masks_for_rep(self, rep):
        affected_tasks = self.super_nodes[rep]

        for e in self._incident_edges_for_tasks(affected_tasks):
            if e.typee == "Order":
                continue

            u = self.task_to_sni[e.producer]
            v = self.task_to_sni[e.consumer]

            if u == v and e.cycle_delta == 0:
                continue

            self._add_cs_pair_mask((u, v), e.cycle_delta)

    def _incident_edges_for_tasks(self, tasks):
        seen_edge_ids = set()

        for t in tasks:
            for e in self.out_edges[t]:
                eid = id(e)
                if eid not in seen_edge_ids:
                    seen_edge_ids.add(eid)
                    yield e

            for e in self.in_edges[t]:
                eid = id(e)
                if eid not in seen_edge_ids:
                    seen_edge_ids.add(eid)
                    yield e

    def _add_cs_pair_mask(self, key, cycle_delta):
        u, v = key
        bit = 1 << cycle_delta

        old = self.cs_pair_mask.get(key, 0)
        new = old | bit

        self.cs_pair_mask[key] = new
        self.cs_out_keys[u].add(key)
        self.cs_in_keys[v].add(key)

    def _remove_cs_keys_touching(self, snis):
        keys = set()

        for sni in snis:
            keys.update(self.cs_out_keys[sni])
            keys.update(self.cs_in_keys[sni])

        for key in keys:
            self._remove_cs_key(key)

    def _remove_cs_key(self, key):
        if key not in self.cs_pair_mask:
            return

        u, v = key

        del self.cs_pair_mask[key]

        self.cs_out_keys[u].discard(key)
        self.cs_in_keys[v].discard(key)

    # ----------------------------------------------------------------------
    # Debug / validation
    # ----------------------------------------------------------------------

    def _full_sc_cycle_check(self):
        """
        Full Kahn check on current incremental quotient graph.
        Used only for debug validation.
        """

        active = [i for i, sn in enumerate(self.super_nodes) if len(sn) > 0]
        active_set = set(active)

        indeg = {i: 0 for i in active}

        for u in active:
            for v in self.sc_succ[u]:
                if v in active_set:
                    indeg[v] += 1

        q = deque([i for i in active if indeg[i] == 0])
        seen = 0

        while q:
            u = q.popleft()
            seen += 1

            for v in self.sc_succ[u]:
                if v not in active_set:
                    continue

                indeg[v] -= 1
                if indeg[v] == 0:
                    q.append(v)

        return seen != len(active)

    def _full_cs_conflict_check(self):
        for mask in self.cs_pair_mask.values():
            if mask == 0b11:
                return True
        return False

    def validate(self):
        assert not self._full_sc_cycle_check(), "Incremental state has SC cycle"
        assert not self._full_cs_conflict_check(), "Incremental state has CS conflict"


@timed
def super_coarsen_groups(G, coarsenedTasks):
    def coarsened_stats(name, cts):
        ct_stats = stats_int([len(ct) for ct in cts])
        print(f"[coarsened_stats][{name}] Stats for Number Tasks Per Coarsened Node ====== ")
        for s in ["min", "max", "mean", "median", "std_dev"]:
            print(f"    {s:<{10}} = {ct_stats[s]}")

    coarsened_stats("Initial Naive Coarsend Graph", coarsenedTasks)

    state_timer = AccumTimer("CoarseningState.can_merge")
    merge_timer = AccumTimer("CoarseningState.merge")

    state = CoarseningState(G, validate_initial=True)

    coarsening_steps = []
    num_used_hist = 0
    num_hist_reject = 0

    coarsenedTasksAccepted = []

    chist = CoarseningHistory()

    # Optional debug knob. Turn this on briefly to compare incremental state.
    VALIDATE_EVERY = None
    num_merges = 0

    for ct in coarsenedTasks:
        assert isinstance(ct, list)

        hist = chist.get_hist(get_coarsened_task_sig(ct))

        while hist is not None:
            assert len(ct)

            used = set()
            num_used_hist += 1

            hist_cts = hist.apply(ct)

            for hct in hist_cts:
                state_timer.start()
                accept = state.can_merge(hct)
                state_timer.stop()

                if accept:
                    merge_timer.start()
                    state.merge(hct)
                    merge_timer.stop()

                    coarsenedTasksAccepted.append(hct)
                    used.update(hct)

                    num_merges += 1
                    if VALIDATE_EVERY is not None and num_merges % VALIDATE_EVERY == 0:
                        state.validate()
                else:
                    num_hist_reject += 1

            ct = [t for t in ct if t not in used]

            if len(used) == 0:
                break

            hist = chist.get_hist(get_coarsened_task_sig(ct))

        if len(ct):
            permute = Permute(ct)

            chist.start_new_hist(get_coarsened_task_sig(ct), ct)
            coarsening_steps.append(0)

            ctc = permute.next()

            while ctc is not None:
                ctc = list(ctc.group)
                assert len(ctc) >= 2

                coarsening_steps[-1] += 1

                state_timer.start()
                accept = state.can_merge(ctc)
                state_timer.stop()

                if accept:
                    merge_timer.start()
                    state.merge(ctc)
                    merge_timer.stop()

                    coarsenedTasksAccepted.append(ctc)
                    chist.accept(ctc)

                    num_merges += 1
                    if VALIDATE_EVERY is not None and num_merges % VALIDATE_EVERY == 0:
                        state.validate()

                ctc = permute.send(accept)

            chist.end_hist()

    chist.print_state()

    coarsened_stats("After Removing Cycles Coarsend Graph", coarsenedTasksAccepted)

    if len(coarsening_steps):
        avg_steps = sum(coarsening_steps) / float(len(coarsening_steps))
    else:
        avg_steps = 0.0

    print(
        f"Total coarsening steps: {sum(coarsening_steps)} "
        f"-- average steps per coarsened task: {avg_steps}"
    )

    print(
        f"Number of coarsening tasks that used history: {num_used_hist} "
        f"-- num of rejects: {num_hist_reject}"
    )

    state_timer.print()
    merge_timer.print()

    return coarsenedTasksAccepted


@timed
def order_tasks_in_coarsen(G, coarsenedTasks):
    task_to_order = {}
    if True:
        same_cycle_graph = nx.DiGraph()
        if True:
            for t in G.nodes():
                same_cycle_graph.add_node(t.idx)

            for e in G.edges():
                if e.cycle_delta == 1:
                    continue
                same_cycle_graph.add_edge(e.producer.idx, e.consumer.idx)

        sorted_nodes = list(nx.topological_sort(same_cycle_graph))
        task_to_order = {n: i for i, n in enumerate(sorted_nodes)}

    final_cts = []
    tasks = list(G.nodes())
    for ct in coarsenedTasks:
        final_cts.append(sorted(list(ct), key=lambda t: task_to_order[t.idx]))
    return final_cts

@timed
def coarsen_graph(G, config):
    # Creates initial coarsneed groups
    superCoarsen, coarsenedTasks = get_coarsen_candidates(G, config)
    if len(coarsenedTasks):
        # Combines coarsen groups that create cycles
        if superCoarsen:
            coarsenedTasks = super_coarsen_groups(G, coarsenedTasks)
        # Make sure tasks are ordered correctly
        coarsenedTasks = order_tasks_in_coarsen(G, coarsenedTasks)

    print(f"Number of generated coarsen tasks: {len(coarsenedTasks)}")
    if len(coarsenedTasks):
        print(f"Average number of tasks per coarsened task: {sum([len(ct) for ct in coarsenedTasks])/float(len(coarsenedTasks))}")

    # Group coarsened tasks:
    coarsenedGroups = defaultdict(list)
    for coarsenedTask in coarsenedTasks:
        coarsenedGroups[get_coarsened_task_sig(coarsenedTask)].append(coarsenedTask)

    print(f"Number of unique coarsened tasks: {len(coarsenedGroups)}")

    name = "coarsenedTasks.h"
    header_filename = os.path.join(config["OUT_PATH"], name)
    config["GENERATED_FILES_TO_INCLUDE"].append(name)
    gen = CppFileGenerator(header_filename)
    gen.add(CppFileGenerator.Line(''))
    gen.add(CppFileGenerator.Line('// This file contains generated coarsend tasks, do not edit\n'))

    class TaskIdxGen:
        def __init__(self, tasks):
            self.idx = 0
            for t in tasks:
                self.idx = max(self.idx, t.idx)
            assert self.idx > 0, "Makes sense"
            self.idx += 1000

        def get(self):
            idx = self.idx
            self.idx += 1
            return idx

    taskIdxGen = TaskIdxGen(G.nodes())

    task_to_carsened_task = {t:t for t in G.nodes()}

    # Create tasks:
    deleted_tasks = []
    for sig, cg in coarsenedGroups.items():
        coarsen_fn_name, coarsen_args = generate_coarsened_task_code(sig, cg[0], gen)
        for grb in cg:
            if len(grb) == 0:
                continue
            ct = generate_coarsened_task_and_fix_var_refs(grb, coarsen_fn_name, coarsen_args, taskIdxGen.get())
            for t in grb:
                task_to_carsened_task[t] = ct
    gen.flush()

    coarsened_raw = {}
    coarsened_raw["tasks"] = sorted(list(set(task_to_carsened_task.values())), key=lambda t: t.idx)
    vars = set()
    if True:
        for t in coarsened_raw["tasks"]:
            for _, _, var in t.args:
                vars.add(var)
        vars = sorted(list(vars), key=lambda v: v.idx)
    coarsened_raw["vars"] = vars

    return coarsened_raw


@timed
def get_graph(raw):
    G = LotusGraph()
    for task in raw["tasks"]:
        G.add_node(task.idx, task)

    class EdgeHandler:
        def __init__(self):
            self.edges = {}

        def get_edge(self, producer, consumer, cycle_delta):
            key = (producer, consumer, cycle_delta)
            if key not in self.edges:
                self.edges[key] = LotusEdge(producer, consumer, cycle_delta, "Data")
            return self.edges[key]
        def get_all_edges(self):
            return self.edges

    e_handler = EdgeHandler()
    for var in raw["vars"]:
        if var.writer is None:
            #assert len(var.readers) == 1
            continue
        assert var.writer is not None
        #assert len(var.readers)
        for reader in var.readers:
            edge = e_handler.get_edge(var.writer, reader, var.cycle_delta)
            edge.add_var(var)

    for _, edge in e_handler.get_all_edges().items():
        G.add_edge(edge.producer.idx, edge.consumer.idx, edge)

    return G

def graph_to_raw(G):
    raw = dict()
    raw["tasks"] = [t for t in G.nodes()]

    vs = set()
    for e in G.edges():
        for v in e.vars:
            vs.add(v)
    raw["vars"] = sorted(list(vs), key=lambda v: v.idx)
    pass

@timed
def get_vars_from_graph(G):
    vars = set()
    for task in G.nodes():
        for (_, _, v) in task.args:
            vars.add(v)
    vars = sorted(list(vars), key=lambda v: v.idx)
    return vars
@timed
def add_order_edges(G):
    # Edges that need to be added:
    # 1. Any task that has an input that's LotusTask.Input.MEM_WR needs an order edge to itself
    #    -- This should mostly be removed by remove_transitive_edges unless it's read/write access to itself
    def add_edge(prod, cons, cycle_delta):
        nonlocal G
        if (prod == cons) and (cycle_delta == 0):
            return

        if cycle_delta == 1:
            # If there's a sc, don't need this order
            if G.has_edge(prod, cons, 0):
                return

        if not G.has_edge(prod, cons, cycle_delta):
            e = LotusEdge(prod, cons, cycle_delta, "Order")
            G.add_edge(e.producer.idx, e.consumer.idx, e)

    for task in G.nodes():
        if any([v.is_mem for (_, _, v) in task.args]):
            add_edge(task, task, 1)

    # 2. Mem Data ( a -mem-1-> b) needs (b -order-0-> a)
    # 3. Mem Data ( a -mem-0-> b) needs (b -order-1-> a)
    # 4. Reg Data ( a -reg-1-> b) needs (b -order-1-> a)
    # 5. Reg Data ( a -reg-0-> b) needs (b -order-2-> a) => (a -order-1-> a) + (a -order-1> b)
    for edge in G.edges():
        if edge.typee != "Data":
            continue
        mem_edge = any([v.is_mem for v in edge.vars])
        if mem_edge:
            cycle_delta = 0 if edge.cycle_delta == 1 else 1
            add_edge(edge.consumer, edge.producer, cycle_delta)
        elif edge.cycle_delta == 1:
            add_edge(edge.consumer, edge.producer, 1)
        else:
            assert edge.cycle_delta == 0
            add_edge(edge.consumer, edge.consumer, 1)
            add_edge(edge.consumer, edge.producer, 1)


    # 6. For is_mem vars that have been unrolled, we need
    #    to order all versions since they read/write to same mem address
    #    if SC:
    #         write[0] -mem-0->   read[0]
    #         write[1] -mem-0->   read[1]
    #         read[0]  -order-0-> write[1]
    #         read[1]  -order-1-> write[0]
    #    if CS:
    #         write[0] -mem-0->   read[1]
    #         write[1] -mem-1->   read[0]
    #         read[1]  -order-0-> write[1]
    #         read[0]  -order-0-> write[0]
    #     This description shows the indicies as "task virtual" cycles
    #     However, the get_virtuals()["var virtual" cycle], and the edges show
    #              the correct tasks in that touch this variable, regardless of the task virtual cycle

    # This only applies to ordering virtual vars that share the same physical var
    physical_vars = set()
    for v in get_vars_from_graph(G):
        p = v.get_physical()
        if p != v:
            assert len(p.get_virtuals()) > 1
            if v.writer is None:
                # Variable is read-only, no need to add order edges
                for vv in p.get_virtuals():
                    assert vv.writer is None
                continue
            physical_vars.add(p)
        else:
            assert len(p.get_virtuals()) == 1


    physical_vars = sorted(list(physical_vars), key=lambda v: v.idx)
    for pv in physical_vars:
        assert pv.is_mem
        vvs = pv.get_virtuals()
        n_virtuals = len(vvs)
        assert n_virtuals > 1
        true_cycle_delta = vvs[-1].cycle_delta
        if true_cycle_delta == 0:
            for read_i, write_i in [(i, (i + 1) % n_virtuals) for i in range(n_virtuals)]:
                cycle_delta = 0 if (read_i < write_i) else 1
                for read in vvs[read_i].readers:
                    assert vvs[write_i].writer is not None
                    add_edge(read, vvs[write_i].writer, cycle_delta)
        else:
            assert true_cycle_delta == 1
            for read_i, write_i in [(i, (i + 1) % n_virtuals) for i in range(n_virtuals)]:
                for read in vvs[read_i].readers:
                    assert vvs[write_i].writer is not None
                    add_edge(read, vvs[write_i].writer, 0)

@timed
def remove_transitive_edges(G):
    from collections import defaultdict

    def print_stats(G, name):
        stats = {"data": 0, "order": 0}
        for e in G.edges():
            if e.typee == "Data":   stats["data"]  += 1
            elif e.typee == "Order": stats["order"] += 1
            else: assert False
        print(f"[remove_transitive_edges] [{name}]  data: {stats['data']}, order: {stats['order']}")

    print_stats(G, "before removal")

    idxs = list(G.nodes_.keys())
    pos  = {idx: i for i, idx in enumerate(idxs)}
    N    = len(idxs)
    removed = set()

    # 1. exact-parallel Order edges (same prod, cons, delta): keep one survivor.
    groups = defaultdict(list)
    for e in G.edges():
        groups[(pos[e.producer.idx], pos[e.consumer.idx], e.cycle_delta)].append(e)
    for es in groups.values():
        if len(es) > 1:
            survivor = next((e for e in es if e.typee != "Order"), es[0])
            for e in es:
                if e is not survivor and e.typee == "Order":
                    removed.add(e)

    # 2. adjacency. reachability uses ALL edge types; only Order edges are candidates.
    succ0        = [[] for _ in range(N)]    # delta-0 successors (all types)
    order0       = defaultdict(list)         # producer -> [(consumer, edge)] delta-0 Order
    order1       = defaultdict(list)         # producer -> [(consumer, edge)] delta-1 Order
    bridge_heads = [[] for _ in range(N)]    # tail -> [head,...] over ALL delta-1 edges
    for e in G.edges():
        if e in removed:
            continue
        p, c = pos[e.producer.idx], pos[e.consumer.idx]
        if e.cycle_delta == 0:
            succ0[p].append(c)
            if e.typee == "Order":
                order0[p].append((c, e))
        else:
            bridge_heads[p].append(c)
            if e.typee == "Order":
                order1[p].append((c, e))

    # 3. delta-0 Order edges: u->c redundant iff c reachable from u by a delta-0 path >= 2.
    for u, lst in order0.items():
        seen = set(); stack = []
        for a in succ0[u]:                   # seed from grandchildren => length >= 2
            for b in succ0[a]:
                if b not in seen:
                    seen.add(b); stack.append(b)
        while stack:
            x = stack.pop()
            for y in succ0[x]:
                if y not in seen:
                    seen.add(y); stack.append(y)
        for c, e in lst:
            if c in seen:
                removed.add(e)

    # 4. delta-1 Order edges: P->C redundant iff another bridge X->Y has
    #    X in Desc0(P) and C in Desc0(Y).
    for P, lst in order1.items():
        fwd = {P}; stack = [P]
        launch = list(bridge_heads[P])
        while stack:
            x = stack.pop()
            for y in succ0[x]:
                if y not in fwd:
                    fwd.add(y); stack.append(y)
                    launch.extend(bridge_heads[y])

        head_count = defaultdict(int)        # length-0 cover: another bridge head == C
        for h in launch:
            head_count[h] += 1

        cover1 = set(); stack = []           # delta-0 reach length >= 1 from launch heads
        for h in launch:
            for y in succ0[h]:
                if y not in cover1:
                    cover1.add(y); stack.append(y)
        while stack:
            x = stack.pop()
            for y in succ0[x]:
                if y not in cover1:
                    cover1.add(y); stack.append(y)

        for c, e in lst:
            if c in cover1 or head_count[c] >= 2:
                removed.add(e)

    # 5. BATCH removal — one O(E) rebuild instead of ~147K O(E) list.remove() calls.
    if removed:
        G.remove_edges(removed)

    print_stats(G, "after removal")


#@timed
#def remove_transitive_edges(G):
#    def print_stats(G, name):
#        stats = {"data": 0, "order": 0}
#        for e in G.edges():
#            if e.typee == "Data":
#                stats["data"] += 1
#            elif e.typee == "Order":
#                stats["order"] += 1
#            else:
#                assert False
#        print(f"[remove_transitive_edges] [{name}]  data: {stats['data']}, order: {stats['order']}")
#
#    def can_remove_edge(e):
#        return e.typee == "Order"
#    def is_transitive(G, edge_to_check, removed_edges):
#        target = (edge_to_check.consumer, edge_to_check.cycle_delta)
#        start  = (edge_to_check.producer, 0)
#
#        seen = {start}
#        stack = [start]
#        while stack:
#            node = stack.pop()
#            if node == target:
#                return True
#            task, cycle = node
#            for e in G.out_edges(task):
#                if e is edge_to_check or e in removed_edges:
#                    continue
#                nc = cycle + e.cycle_delta
#                if nc > target[1]:
#                    continue
#                nxt = (e.consumer, nc)
#                if nxt not in seen:
#                    seen.add(nxt)
#                    stack.append(nxt)
#        return False
#
#    print_stats(G, "before removal")
#
#    removed_edges = set()
#    for e in G.edges():
#        if not can_remove_edge(e):
#            continue
#        if is_transitive(G, e, removed_edges):
#            removed_edges.add(e)
#
#    for e in removed_edges:
#        G.remove_edge(e)
#
#    print_stats(G, "after removal")

@timed
def ensure_no_cycles(G, config):
    def create_single_cycle_graph(G):
        stats = defaultdict(int)

        G_sc = nx.DiGraph()
        for n in G.nodes():
            G_sc.add_node(n.idx, data=n)
        for e in G.edges():
            if e.producer == e.consumer:
                assert e.cycle_delta == 1
                continue
            if e.cycle_delta == 0:
                G_sc.add_edge(e.producer.idx, e.consumer.idx)
                if e.typee == "Data":
                    stats["data_edges"] += 1
                else:
                    assert e.typee == "Order"
                    stats["order_edges"] += 1
        return (G_sc, stats)

    if False:
        traph = LotusGraph()
        for t in G.nodes():
            traph.add_node(t.idx, t)

        for e in G.edges():
            if e.cycle_delta == 0:
                traph.add_edge(e.producer.idx, e.consumer.idx, e)
        generate_dot_graph("ensure_no_cycle", traph, config)

    (G_sc, stats) = create_single_cycle_graph(G)
    if not nx.is_directed_acyclic_graph(G_sc):
        try:
            cycle = next(nx.simple_cycles(G_sc))
            idx_to_label = {t.idx: t.label for t in G.nodes()}
            cycle = [idx_to_label[idx] for idx in cycle]
        except StopIteration:
            cycle = None
        raise ValueError(f"Rank graph is not a DAG. Example cycle: {cycle}")

@timed
def check_edges(G, config):
    edges = defaultdict(list)
    for e in G.edges():
        edges[(e.producer, e.consumer)].append(e)

    will_error = False
    for (prod, cons), es in edges.items():
        if len(es) <= 1:
            continue
        will_error = True
        print(f"======= ABOUT TO ERROR")
        print(f"Parent: {prod.fn} -- version: {prod.unroll_version} -- index: {prod.idx}")
        print(f"Child : {cons.fn} -- version: {cons.unroll_version} -- index: {cons.idx}")
        print(f"Number of edges: {len(es)}")
        for e in es:
            print(f"Edge type={e.typee}, cycle_delta={e.cycle_delta}, vars: {len(e.vars)}")
    assert not will_error

@timed
def register_alloc(G, config):
    def ensure_contig(regs):
        producers_saw = []
        current_prod = None
        for r in regs:
            assert len(r)
            # r[0][0] is the idx inside task.args
            p = r[0][1].writer
            assert p not in producers_saw, f"Producer produces to registers that aren't after each other"
            if current_prod is None:
                curr_prod = p
            else:
                if curr_prod != p:
                    producers_saw.append(curr_prod)
                    curr_prod = p

    class AllocManager:
        def __init__(self):
            self.tileToNumRegsToAllocs = defaultdict(lambda: defaultdict(lambda: defaultdict(set)))
            self.tileToNumMovRegsToAllocs = defaultdict(lambda: defaultdict(lambda: defaultdict(set)))
            self.allocToNumMovRegs        = {}
            self.taskToAlloc           = {}
            self.allocs = []
            self.maxArgsPerTask = None
            self.numArgsPerTile = None
            self.blacklist = set()
            self.from_const = False
            self.constInputs = None
            self.num_picks_from_const_inputs = 0
            self.num_picks_from_non_const = 0


        def calculate_constInptus(self):
            def numConsts(a):
                # Must match overflow function
                n = 0
                for vars in a.regs_to_vars:
                    v = vars[0][1]
                    if v.is_mem:
                        n += 1
                    noWriter = all(v.writer is None for _, v, _, _, _, _ in vars)
                    if noWriter:
                        n += 1
                return n

            self.constInputs = defaultdict(list)
            a_to_n = {}
            for a in self.allocs:
                n = numConsts(a)
                if n:
                    a_to_n[a] = n
                    self.constInputs[a.task.mappedTo].append(a)

            self.constInputs = dict(self.constInputs)

            for cIns in self.constInputs.values():
                cIns.sort(key=lambda a: (a_to_n[a], a.task.num_instrs))

        def print_stats(self):
            print(f"num_picks_from_const_inputs = {self.num_picks_from_const_inputs}")
            print(f"num_picks_from_non_const = {self.num_picks_from_non_const}")
            nTiles = config["TILES_PER_DEVICE"] * config["DEVICES"]
            stats = {
                        "perTask": {
                            "totalInBytes": [],
                            "regInBytes": [],
                            "regInCTPerc": [],
                            "memInBytes": [],
                            "percInMem" : [],
                            },
                        "perTile": {
                            "totalRegsUsed": defaultdict(int),
                            "totalMemUsed": defaultdict(int),
                            },
                        }

            for a in self.allocs:
                regInBytes    = len(a.regs_to_vars) * 4
                regInBytesST  = a.num_same_tile_comm_regs() * 4
                regInBytesCT  = regInBytes - regInBytesST
                if regInBytes == 0:
                    regInCTPerc   = 0.0
                else:
                    regInCTPerc   = float(regInBytesCT) / float(regInBytes)
                memInBytes = a.task.struct_alloc.est_bytes() if a.task.struct_alloc else 0
                stats["perTask"]["regInBytes"].append(regInBytes)
                stats["perTask"]["regInCTPerc"].append(regInCTPerc)

                stats["perTask"]["memInBytes"].append(memInBytes)
                stats["perTask"]["totalInBytes"].append(regInBytes + memInBytes)
                stats["perTask"]["percInMem"].append(float(memInBytes)/(float(regInBytes+memInBytes)))

                stats["perTile"]["totalRegsUsed"][a.task.mappedTo] += regInBytes
                stats["perTile"]["totalMemUsed"][a.task.mappedTo] += memInBytes

            if False:
                import pandas as pd
                rows_task = []
                for name, nums in stats.get("perTask", {}).items():
                    s = stats_int(nums)
                    rows_task.append({"metric": name, "count": len(nums), **s})

                rows_tile = []
                for name, d in stats.get("perTile", {}).items():
                    vals = list(d.values())
                    s = stats_int(vals)
                    rows_tile.append({"metric": name, "count": len(vals), **s})

                df_task = pd.DataFrame(rows_task).set_index("metric").sort_index()
                df_tile = pd.DataFrame(rows_tile).set_index("metric").sort_index()

                # Nice formatting
                def fmt(df):
                    df = df.copy()
                    for col in ["min", "max", "mean", "median", "std_dev"]:
                        if col in df.columns:
                            df[col] = pd.to_numeric(df[col], errors="coerce")
                    return df

                df_task = fmt(df_task)
                df_tile = fmt(df_tile)

                with pd.option_context(
                    "display.width", 140,
                    "display.max_columns", None,
                    "display.max_rows", 200,
                    "display.float_format", "{:,.4g}".format,
                ):
                    print("\n=== perTask (list metrics) ===")
                    print(df_task)

                    print("\n=== perTile (dict value metrics) ===")
                    print(df_tile)

        def add_to_blacklist(self, a):
            self.blacklist.add(a)

        def ensure_correct(self):
            for tileId in self.tileToNumRegsToAllocs.keys():
                for numInstrs in self.tileToNumRegsToAllocs[tileId].keys():
                    for numRegs, allocs in self.tileToNumRegsToAllocs[tileId][numInstrs].items():
                        for a in allocs:
                            if numRegs != a.numRegs():
                                print(f"ABOUT TO ERROR")
                                for nr, aas in self.tileToNumRegsToAllocs[tileId][numInstrs].items():
                                    print(f" {nr} = {[a.numRegs() for a in aas]}")
                                    print(f" {nr} = {[(a.task.fn, a.task.idx) for a in aas]}")
                                assert False
            #print(f"AllocManager tileToNumRegsToAllocs is correct!")

        def setConfig(self, maxArgsPerTask, numArgsPerTile):
            self.maxArgsPerTask = maxArgsPerTask
            self.numArgsPerTile = numArgsPerTile

        def tileNumRegs(self, tileId):
            nr = 0
            for numInstrs in self.tileToNumRegsToAllocs[tileId].keys():
                for numRegs, allocs in self.tileToNumRegsToAllocs[tileId][numInstrs].items():
                    paddedNumRegs = (numRegs+1) if ((numRegs&1) == 1) else numRegs
                    nr += paddedNumRegs*len(allocs)
            return nr

        def getBestPick(self):
            self.from_const = False
            #self.ensure_correct()
            #FIXME(farese): This isn't the best strategy. There are tasks
            # that are better to overflow that aren't the largest tasks. Fix later
            for tileId in sorted(self.tileToNumRegsToAllocs.keys()):
                for numInstrs in sorted(self.tileToNumRegsToAllocs[tileId].keys()):
                    max_key = max(self.tileToNumRegsToAllocs[tileId][numInstrs].keys())
                    if max_key > self.maxArgsPerTask:
                        return self.getBestPickFromTile(tileId)

            for tileId in sorted(self.tileToNumRegsToAllocs.keys()):
                if self.tileNumRegs(tileId) > self.numArgsPerTile:
                    return self.getBestPickFromTile(tileId)
            return None

        def getAllocForTask(self, task):
            return self.taskToAlloc[task]

        def add(self, alloc):
            self.taskToAlloc[alloc.task] = alloc
            self.allocs.append(alloc)
            #self.tileToNumRegsToAllocs[alloc.task.mappedTo][alloc.task.num_instrs][alloc.numRegs()].add(alloc)
            self.tileToNumRegsToAllocs[alloc.task.mappedTo][0][alloc.numRegs()].add(alloc)
            self.allocToNumMovRegs[alloc] = alloc.num_same_tile_comm_regs()


        def getBestPickFromTile(self, tileId):
            # numMovToAllocs = self.tileToNumMovRegsToAllocs[tileId]
            # if len(numMovToAllocs):
            #     max_mov = max(numMovToAllocs.keys())
            #     allocs = numMovToAllocs[max_mov]
            #     return next(iter(allocs))
            if (tileId in self.constInputs) and len(self.constInputs[tileId]):
                self.num_picks_from_const_inputs += 1
                self.from_const = True
                return self.constInputs[tileId].pop()

            self.num_picks_from_non_const += 1

            numRegsToAllocs = self.tileToNumRegsToAllocs[tileId]

            for numInstrs in sorted(numRegsToAllocs.keys()):
                for r in sorted(numRegsToAllocs[numInstrs].keys(), reverse=True):
                    for a in sorted(numRegsToAllocs[numInstrs][r], key=lambda a: a.task.idx):
                        if a in self.blacklist:
                            continue
                        if self.allocToNumMovRegs[a] == 0:
                            continue
                        if a.numRegs() <= 1:
                            continue
                        return a

            print(f"========= tileId={tileId}")
            for numInstrs in sorted(numRegsToAllocs.keys()):
                print(f"    - numInstrs: {numInstrs}")
                for r in sorted(numRegsToAllocs[numInstrs].keys(), reverse=True):
                    print(f"    - Looking at numRegs = {r} -- numTasks = {len(numRegsToAllocs[numInstrs][r])}")
                    for a in numRegsToAllocs[numInstrs][r]:
                        print("%%%%%%%%%%%%%%%")
                        print(f"        => {a.get_vars_to_tiles()}")
                        print(f"        - task: {a.task.label} has numMoveRegs = {self.allocToNumMovRegs[a]}")
                        print(f"        - task: {a.task.label} ACTUAL numMoveRegs = {a.num_same_tile_comm_regs()}")
                        if a in self.blacklist:
                            print(f"        - task: {a.task.fn} in blacklist")
                            continue
                        if self.allocToNumMovRegs[a] == 0:
                            continue

            assert False, f"Should have found an alloc"

            #max_regs = max(numRegsToAllocs.keys())
            #allocs = numRegsToAllocs[max_regs]
            ##return next(iter(allocs))
            #return next(iter(sorted(list(allocs), key=lambda a: -self.allocToNumMovRegs[a])))
            ## for a in allocs:
            ##     if self.allocToNumMovRegs[a] > 0:
            ##         return a

        @contextmanager
        def updating(self, alloc):
            old_regs = alloc.numRegs()
            old_mov  = alloc.num_same_tile_comm_regs()
            try:
                yield
            finally:
                new_regs = alloc.numRegs()
                #print(f"updating {alloc.task.fn} from {old_regs} to {new_regs}")
                if new_regs != old_regs:
                    #bucket = self.tileToNumRegsToAllocs[alloc.task.mappedTo][alloc.task.num_instrs].get(old_regs)
                    bucket = self.tileToNumRegsToAllocs[alloc.task.mappedTo][0].get(old_regs)
                    if bucket and alloc in bucket:
                        bucket.remove(alloc)
                        if not bucket:
                            #self.tileToNumRegsToAllocs[alloc.task.mappedTo][alloc.task.num_instrs].pop(old_regs, None)
                            self.tileToNumRegsToAllocs[alloc.task.mappedTo][0].pop(old_regs, None)
                    self.tileToNumRegsToAllocs[alloc.task.mappedTo][0][new_regs].add(alloc)
                new_mov = alloc.num_same_tile_comm_regs()
                if (new_mov != old_mov) or (alloc not in self.allocToNumMovRegs):
                    if alloc in self.allocToNumMovRegs:
                        del self.allocToNumMovRegs[alloc]
                    #bucket = self.tileToNumMovRegsToAllocs[alloc.task.mappedTo][alloc.task.num_instrs].get(old_mov)
                    bucket = self.tileToNumMovRegsToAllocs[alloc.task.mappedTo][0].get(old_mov)
                    if bucket and alloc in bucket:
                        bucket.remove(alloc)
                        if not bucket:
                            #self.tileToNumMovRegsToAllocs[alloc.task.mappedTo][alloc.task.num_instrs].pop(old_mov, None)
                            self.tileToNumMovRegsToAllocs[alloc.task.mappedTo][0].pop(old_mov, None)
                    self.allocToNumMovRegs[alloc] = new_mov
                    if new_mov != 0:
                        #self.tileToNumMovRegsToAllocs[alloc.task.mappedTo][alloc.task.num_instrs][new_mov].add(alloc)
                        self.tileToNumMovRegsToAllocs[alloc.task.mappedTo][0][new_mov].add(alloc)

    class DoAlloc:
        allocManager = AllocManager()
        def __init__(self, task):
            self.task          = task
            self.regs_to_vars  = []
            self.regs_to_prods = []
            self.bytesUsed     = []
            DoAlloc.allocManager.add(self)


        def numRegs(self):
            hasStruct = 1 if self.task.struct_alloc else 0
            return len(self.regs_to_vars) + hasStruct

        def get_vars_to_tiles(self):
            vars_to_tiles = {}
            for reg in self.regs_to_vars:
                for comp in reg:
                    var = comp[1]
                    tiles = set()
                    if var.writer:
                        tiles.add(var.writer.mappedTo)
                    for r in var.readers:
                        tiles.add(r.mappedTo)
                    vars_to_tiles[(var.idx, var.typee, var.size)] = tiles
            return vars_to_tiles


        def num_same_tile_comm_regs(self):
            regs = 0
            for reg in self.regs_to_vars:
                tiles = set()
                for comp in reg:
                    var = comp[1]
                    for vv in var.get_virtuals():
                        if vv.writer:
                            tiles.add(vv.writer.mappedTo)
                        for r in vv.readers:
                            tiles.add(r.mappedTo)
                if len(tiles) == 1:
                    regs += 1
            return regs


        def has_var(self, var):
            for regs in self.regs_to_vars:
                for c in regs:
                    v = c[1]
                    if v == var:
                        return True
            return False

        def allocVar(self, idx, v, acc, prod):
            with DoAlloc.allocManager.updating(self):
                size = v.size
                if v.is_mem:
                    # Pointer
                    size = 4
                startByte = 0
                while size != 0:
                    useBytes = min(size, 4)
                    endByte  = startByte + useBytes - 1
                    self.regs_to_vars.append([(idx, v, acc, startByte, endByte, useBytes)])
                    self.regs_to_prods.append(prod)
                    self.bytesUsed.append(useBytes)
                    startByte = endByte + 1
                    size = size - useBytes

        def get_best_pack_can(self):
            #TODO(farese): There are better ways
            smallest_value = min(self.bytesUsed)
            smallest_index = self.bytesUsed.index(smallest_value)
            return smallest_index

        def try_packing_one(self):
            can_idx = self.get_best_pack_can()
            can_val = self.bytesUsed[can_idx]
            pack_index = None
            for i, bu in enumerate(self.bytesUsed):
                sameReg        = i == can_idx
                diffProd       = self.regs_to_prods[can_idx] != self.regs_to_prods[i]
                if sameReg or diffProd:
                    continue
                notEnoughSpace = (bu+can_val) > 4
                if notEnoughSpace:
                    continue
                if pack_index is None:
                    pack_index = i
                elif bu > self.bytesUsed[pack_index]:
                    pack_index = i
            if pack_index is None:
                return False
            assert pack_index != can_idx
            self.bytesUsed[pack_index] += can_val
            assert self.bytesUsed[pack_index] <= 4
            self.regs_to_vars[pack_index].extend(self.regs_to_vars[can_idx])
            del self.regs_to_vars[can_idx]
            del self.regs_to_prods[can_idx]
            del self.bytesUsed[can_idx]
            return True
        def pack(self, targetRegs):
            #self.confirm_inputs("Before pack")
            with DoAlloc.allocManager.updating(self):
                didPack = True
                while (self.numRegs() > targetRegs) and didPack:
                    didPack = self.try_packing_one()
                return self.numRegs() <= targetRegs

        def addStruct(self):
            if not self.task.struct_alloc:
                with DoAlloc.allocManager.updating(self):
                    self.task.struct_alloc = TaskStruct(self.task)

        def overflow(self, targetRegs):
            with DoAlloc.allocManager.updating(self):
                if len(self.regs_to_vars) <= (targetRegs-1):
                    return

                # Need to leave 1 reg for struct pointer
                goal_num_regs = targetRegs - 1
                goal_remove   = len(self.regs_to_vars) - goal_num_regs

                picked_to_remove = SortedSet()

                # 1. Pick vars that are constants
                for i, vars in enumerate(self.regs_to_vars):
                    v = vars[0][1]
                    if v.is_mem:
                        picked_to_remove.add(i)
                        continue

                    noWriter = all(v.writer is None for _, v, _, _, _, _ in vars)
                    if noWriter:
                        picked_to_remove.add(i)

                if (len(picked_to_remove) < goal_remove) and (not DoAlloc.allocManager.from_const):
                    # Figure out groups
                    var_to_regs = defaultdict(list)
                    reg_to_vars = defaultdict(list)
                    for i, vars in enumerate(self.regs_to_vars):
                        for _, v, _, _, _, _ in vars:
                            var_to_regs[v].append(i)
                            reg_to_vars[i].append(v)

                    size_to_vars = defaultdict(list)
                    max_size     = 0
                    for v, regs in var_to_regs.items():
                        size_to_vars[len(regs)].append(v)
                        max_size = max(max_size, len(regs))

                    private_variables = []
                    for size in range(0, max_size+1):
                        if size in size_to_vars:
                            for var in size_to_vars[size]:
                                tasks = set()
                                if var.writer:
                                    tasks.add(var.writer)
                                for t in var.readers:
                                    tasks.add(t)
                                if len(tasks) == 1:
                                    private_variables.append(var)

                    local_variables = []
                    for size in range(0, max_size+1):
                        if size in size_to_vars:
                            for var in size_to_vars[size]:
                                if var in private_variables:
                                    continue
                                tiles = set()
                                if var.writer:
                                    tiles.add(var.writer.mappedTo)
                                for t in var.readers:
                                    tiles.add(t.mappedTo)
                                if len(tiles) == 1:
                                    local_variables.append(var)

                    #NOTE: We want to pick variables that need to move to memory.
                    #      First, if a size(variable) >= sizeNeedToMoveToMem then we pick that large one.
                    #      Otherwise, pick the next largest variable, and then try again.
                    #      #FIXME(farese): This is not optimal, and picks things that move to memory when
                    #      It's not needed
                    private_variables.sort(key=lambda v: v.idx)
                    local_variables.sort(key=lambda v: v.idx)
                    while len(picked_to_remove) < goal_remove:
                        if len(private_variables):
                            # 1. pick variables produced by the task itself
                            root_var = private_variables.pop()
                        elif len(local_variables):
                            # 2. pick variables produced by the tasks on the same tile
                            root_var = local_variables.pop()
                        else:
                            if True:
                                print(f"========= ABOUT TO ERROR OVERFLOW FOR TAS: {self.task.useful_name()}")
                                DoAlloc.allocManager.print_stats()
                                assert False, f"Unreachable, want non-private non-local to overflow -- picked_to_remove:{len(picked_to_remove)} -- goal_remove: {goal_remove} -- num_regs: {len(self.regs_to_vars)}"
                                break
                                mappedTo = self.task.mappedTo
                                vs = []
                                for v in var_to_regs.keys():
                                    mps = set()
                                    if v.writer:
                                        mps.add(v.writer.mappedTo)
                                    for r in v.readers:
                                        mps.add(r.mappedTo)
                                    vs.append(mps)
                                assert False, f"WANT A NON-PRIVATE AND NON-LOCAL VARIABLE self.mappedTo={mappedTo} -- vars={vs}"
                            assert False, f"MAKE DETERMINISTIC"
                            real_d = goal_remove - len(picked_to_remove)
                            use_d = real_d
                            while (use_d < max_size) and (use_d not in size_to_vars):
                                use_d = use_d + 1
                            if use_d not in size_to_vars:
                                use_d = real_d
                                while (use_d > 0) and (use_d not in size_to_vars):
                                    use_d = use_d - 1
                            assert use_d in size_to_vars
                            root_var = size_to_vars[use_d][0]

                        regs = var_to_regs[root_var]
                        for r in regs:
                            picked_to_remove.add(r)

                        all_vars = set()
                        for r in regs:
                            for v in reg_to_vars[r]:
                                if v in var_to_regs:
                                    del var_to_regs[v]
                                all_vars.add(v)
                            del reg_to_vars[r]


                        remove_sizes = []
                        for size, vars in size_to_vars.items():
                            size_to_vars[size] = [v for v in vars if v not in all_vars]
                            if len(size_to_vars[size]) == 0:
                                remove_sizes.append(size)
                        for size in remove_sizes:
                            del size_to_vars[size]

                if (len(picked_to_remove) < goal_remove) and (not DoAlloc.allocManager.from_const):
                    assert self.numRegs() < DoAlloc.allocManager.maxArgsPerTask, f"Task is not Valid, need to coarsen more before blacklisting ({self.numRegs()} < {DoAlloc.allocManager.maxArgsPerTask}) (picked_to_remove: {len(picked_to_remove)})"
                    DoAlloc.allocManager.add_to_blacklist(self)
                #assert len(picked_to_remove) >= goal_remove

                prod_to_vars = defaultdict(set)
                picked_vars = set()
                for p in picked_to_remove:
                    prod = self.regs_to_prods[p]
                    for _, v, _, _, _, _ in self.regs_to_vars[p]:
                        prod_to_vars[prod].add(v)
                        picked_vars.add(v)

                self.regs_to_vars = [
                    v for i, v in enumerate(self.regs_to_vars)
                    if i not in picked_to_remove
                ]
                self.regs_to_prods = [
                    v for i, v in enumerate(self.regs_to_prods)
                    if i not in picked_to_remove
                ]
                self.bytesUsed = [
                    v for i, v in enumerate(self.bytesUsed)
                    if i not in picked_to_remove
                ]

                for p in prod_to_vars.keys():
                    prod_to_vars[p] = list(prod_to_vars[p])

                if self.task.struct_alloc is None:
                    self.task.struct_alloc = TaskStruct(self.task)

                self.task.struct_alloc.update(list(picked_vars), prod_to_vars)

                def has_non_mem(vs):
                    assert len(vs)
                    for v in vs:
                        if not v.is_mem:
                            return True
                    return False

                for prod, vs in prod_to_vars.items():
                    if prod != self.task and (prod is not None) and has_non_mem(vs):
                        DoAlloc.allocManager.getAllocForTask(prod).addStruct()
            #self.confirm_inputs("overflow")


        def sort(self):
            # Sort so that parents are contigeous
            prod_to_vals = defaultdict(list)
            for i in range(len(self.regs_to_vars)):
                prod_to_vals[self.regs_to_prods[i]].append((self.regs_to_vars[i], self.bytesUsed[i]))
            self.regs_to_vars  = []
            self.regs_to_prods = []
            self.bytesUsed     = []
            for prod, vals in prod_to_vals.items():
                for vars, bu in vals:
                    self.regs_to_vars.append(vars)
                    self.regs_to_prods.append(prod)
                    self.bytesUsed.append(bu)

            # Sort so that in each reg it's descending
            for vars in self.regs_to_vars:
                #vars.sort(reverse=True, key=lambda v: v[5])
                vars.sort(key=lambda v: (-v[5], v[0]))

            new_regs = []
            for vars in self.regs_to_vars:
                new_vars = []
                reg_byte = 0
                for (idx, v, acc, startByte, endByte, useBytes) in vars:
                    new_vars.append((idx, v, acc, reg_byte, startByte, endByte, useBytes))
                    reg_byte += useBytes
                new_regs.append(new_vars)
            self.regs_to_vars = new_regs

        def confirm_inputs(self, name):
            rs = []
            for r in self.regs_to_vars:
                rs.append([])
                for c in r:
                    rs[-1].append(c[1].idx)

            ss = []
            i = None
            if self.task.struct_alloc:
                i = id(self.task.struct_alloc)
                ss = [s.idx for s in self.task.struct_alloc.vars]
            print(f"===== confirm_inputs({self.task.fn}, {self.task.idx}) -- {name} -- rs={rs} -- id={id(i)} -- ss={ss} -- args={[v.idx for _, _, v in self.task.args]}")
            for i, (dir, acc, var) in enumerate(self.task.args):
                if acc in [LotusTask.ARG_ACCESS.PARTIAL, LotusTask.ARG_ACCESS.PARTIAL_UNTRACKED]:
                    continue
                inRegs = self.has_var(var)
                inStruct = False
                if self.task.struct_alloc:
                    inStruct = var in self.task.struct_alloc.vars
                if inRegs or inStruct:
                    continue
                assert acc == LotusTask.ARG_ACCESS.FULL
                if not ((dir == LotusTask.ARG_DIR.OUT) or (var.writer is None)):
                    print(f"NOT FOUND => Var: {var}")
                assert (dir == LotusTask.ARG_DIR.OUT) or (var.writer is None)

    def alloc(task):
        nonlocal config
        parents_to_vars = defaultdict(list)
        is_mem_physical_vars = defaultdict(list)
        for idx, (dir, acc, var) in enumerate(task.args):
            if var.is_mem:
                # For is_mem, we only add physical vars.
                # This saves on passing the same pointer multiple times
                is_mem_physical_vars[var.get_physical()].append((idx, dir, acc))
                continue
            if dir in [LotusTask.ARG_DIR.IN, LotusTask.ARG_DIR.INOUT]:
                parents_to_vars[var.writer].append((idx, dir, acc, var))
            elif (dir == LotusTask.ARG_DIR.OUT) and (acc in [LotusTask.ARG_ACCESS.PARTIAL, LotusTask.ARG_ACCESS.PARTIAL_UNTRACKED]):
                parents_to_vars[var.writer].append((idx, dir, acc, var))

        parent_to_key = {p: tuple(sorted([idx for idx, _, _, _ in vs])) for p, vs in parents_to_vars.items()}

        parents_to_vars_sorted = []
        for parent in sorted(parents_to_vars.keys(), key=lambda p: parent_to_key[p]):
            parents_to_vars_sorted.append((parent, sorted(parents_to_vars[parent], key=lambda m: m[0])))

        alloc = DoAlloc(task)
        for parent, var_metas in parents_to_vars_sorted:
            for (idx, _, acc, var) in var_metas:
                alloc.allocVar(idx, var, acc, parent)

        mem_var_to_key = {v: tuple(sorted([idx for idx, _, _ in vs])) for v, vs in is_mem_physical_vars.items()}
        is_mem_physical_vars_sorted = []
        for var in sorted(is_mem_physical_vars.keys(), key=lambda v: mem_var_to_key[v]):
            is_mem_physical_vars_sorted.append((var, sorted(is_mem_physical_vars[var], key=lambda m: m[0])))

        # The parent doesn't matter here because we only pass a pointer
        is_mem_physical_vars_zipped = []
        for var, args in is_mem_physical_vars_sorted:
            is_mem_physical_vars_zipped.append((var, tuple(map(list, zip(*args)))))

        for pv, (idxs, dirs, accs) in is_mem_physical_vars_zipped:
            assert len(set(accs)) == 1
            alloc.allocVar(idxs, pv, accs[0], None)
        #alloc.confirm_inputs("from alloc")



    def limit_args(alloc, maxArgs):
        if alloc.pack(maxArgs):
            return
        alloc.overflow(maxArgs)

    tasks = list(G.nodes())
    tasks.sort(key=lambda t: t.idx)
    for task in tasks:
        alloc(task)

    #maxArgsPerTask = 8
    maxArgsPerTask = config["MAX_ARGS_PER_TASK"]
    numArgsPerTile = config["AVG_ARGS_PER_TASK"] * config["TASKS_PER_TILE"]

    #NOTE(farese): Idk if this is hacky, but this is how this works:
    # AllocManager observes any changes to the number of regs of each task.
    # At each iteration, bestPick picks the best candidate to reduce registers for
    # and any side-effects will be reflected at the next call to getBestPick()
    allocManager = DoAlloc.allocManager
    allocManager.setConfig(maxArgsPerTask, numArgsPerTile)

    print(f"================= Before any overflow")
    allocManager.print_stats()

    # Pack if greater than maxArgsPerTask
    for alloc in allocManager.allocs:
        if alloc.numRegs() <= maxArgsPerTask:
            continue
        # Try packing
        alloc.pack(maxArgsPerTask)

    print(f"================= After maxArgsPerTask PACKING only (will overflow later)")
    allocManager.print_stats()

    allocManager.calculate_constInptus()

    # bestPick is one of these two:
    # 1. a task with numRegs() > maxArgsPerTask
    # 2. a task from a tile with numRegs() > numArgsPerTile
    bestPick = allocManager.getBestPick()
    while bestPick:
        #bestPick.confirm_inputs("@@@@@@@@@@@@@@@@@@@@ bestPick BEFORE")
        nr = bestPick.numRegs()
        assert nr > 1
        targetRegs = nr-1
        targetRegs = min(maxArgsPerTask, targetRegs)
        limit_args(bestPick, targetRegs)
        #bestPick.confirm_inputs("@@@@@@@@@@@@@@@@@@@@ bestPick AFTER")
        bestPick = allocManager.getBestPick()

    print(f"================= Final stats")
    allocManager.print_stats()

    for alloc in allocManager.allocs:
        assert alloc.numRegs() <= maxArgsPerTask
        alloc.sort()

        regs = alloc.regs_to_vars
        prods = alloc.regs_to_prods

        ensure_contig(regs)

        ra = RegisterAllocation(alloc.task, regs, prods)
        #alloc.confirm_inputs("final")
        alloc.task.register_alloc = ra
        #alloc.task.assert_args_inputs()

    argsPerTile     = defaultdict(int)
    for task in tasks:
        args = len(task.register_alloc.regs)
        paddedArgs = (args+1) if ((args&1) == 1) else args
        argsPerTile[task.mappedTo] += paddedArgs

    for t in argsPerTile.keys():
        assert argsPerTile[t] <= numArgsPerTile, f"ARGS VIOLATION -- Tile: {t} -- {argsPerTile[t]} <= {numArgsPerTile}"


@timed
def output_table(G, config):
    def do_alloc(task):
        nonlocal config
        nonlocal G
        class DoAlloc:
            def __init__(self):
                self.regs = []
                self.consumers = []
                self.regs_to_in_ids = []

            def get_output_id(self, in_id, target_reg, consumer):
                get_sig = lambda r: [(var, regByte, startByte, endByte) for _, var, _, regByte, startByte, endByte, _  in r]

                target_sig = get_sig(target_reg)
                for id, ref_reg in enumerate(self.regs):
                    ref_sig = get_sig(ref_reg)
                    if target_sig == ref_sig:
                        self.consumers[id].append(consumer)
                        self.regs_to_in_ids[id][consumer] = in_id
                        return id
                id = len(self.regs)
                self.regs.append(target_reg)
                self.consumers.append([consumer])
                self.regs_to_in_ids.append({consumer: in_id})
                return id

            def get_output_ids(self, regs, consumer):
                ids = {}
                for in_id, target_reg in regs:
                    ids[in_id] = self.get_output_id(in_id, target_reg, consumer)
                return ids

        def has_mem(reg):
            for _, var, acc, _, _, _, _ in reg:
                if var.is_mem:
                    assert acc in [LotusTask.ARG_ACCESS.PARTIAL, LotusTask.ARG_ACCESS.PARTIAL_UNTRACKED]
                    return True
                else:
                    assert acc == LotusTask.ARG_ACCESS.FULL
            return False
        # Register allocation
        alloc = DoAlloc()
        edges = [e for e in G.out_edges(task.idx)]
        #edges.sort(key=lambda e: (e.producer.idx, e.consumer.idx))
        def edge_key(e):
            k = []
            for v in e.vars:
                i = e.producer.get_var_arg_idx(v)
                assert i is not None
                k.append(i)
            k.sort()
            return tuple(k)
        edges.sort(key=edge_key)
        if True:
            data_edges = [e for e in edges if e.typee == "Data"]
            consumers = set()
            for e in data_edges:
                idx = e.consumer.idx
                if idx in consumers:
                    print(f"======= ABOUT TO ERROR")
                    prod = e.producer
                    cons = e.consumer
                    es = [ z for z in data_edges if z.consumer == cons]
                    print(f"Parent: {prod.fn} -- version: {prod.unroll_version} -- index: {prod.idx}")
                    print(f"Child : {cons.fn} -- version: {cons.unroll_version} -- index: {cons.idx}")
                    print(f"Number of edges: {len(es)}")
                    for e in es:
                        print(f"\tEdge type={e.typee}, cycle_delta={e.cycle_delta}, vars: {len(e.vars)}")
                        for v in e.vars:
                            print(f"\t\tvar: {v}")
                assert idx not in consumers, f"Two data edges to the same task?"
                consumers.add(idx)
        for e in edges:
            if e.typee == "Order":
                e.output_ids = {}
                continue
            assert e.typee == "Data"
            regs = e.consumer.register_alloc.get_regs_for(task)
            regs = [(in_id, reg) for in_id, reg in regs if not has_mem(reg)]
            output_ids = alloc.get_output_ids(regs, e.consumer)
            e.output_ids = output_ids
        assert len(alloc.regs) < config["OUT_REGS_PER_TASK"]
        alloc = RegisterAllocation(task, alloc.regs, alloc.consumers, alloc.regs_to_in_ids)
        task.output_table = alloc

        # Memory allocation
        for e in edges:
            cons = e.consumer
            if cons.struct_alloc is None:
                continue
            vars = cons.struct_alloc.get_vars_for(task)
            if not vars:
                continue
            vars = [v for v in vars if not v.is_mem]
            if not vars:
                continue
            assert task.struct_alloc, f"Should have been allocated in register_alloc"
            task.struct_alloc.struct_pointers.append(cons.struct_alloc)
            if task.output_mem is None:
                task.output_mem = {}
            task.output_mem[cons.struct_alloc] = sorted(vars, key=lambda v: v.idx)
        if task.struct_alloc:
            task.struct_alloc.struct_pointers.sort(key=lambda sa: sa.task.idx)

    for task in G.nodes():
        do_alloc(task)
@timed
def recipe_generation(G, config):
    def do_recipes(task):
        nonlocal G
        nonlocal config
        def group_dict_items(d):
            result = []
            keys = sorted(d.keys())
            i = 0
            while i < len(keys):
                k = keys[i]
                if k % 2 == 0 and i + 1 < len(keys) and keys[i + 1] == k + 1:
                    result.append([(k, d[k]), (keys[i + 1], d[keys[i + 1]])])
                    i += 2
                else:
                    result.append([(k, d[k])])
                    i += 1
            return result
        recipes = []
        def isHasMemDataDep(edge):
            for v in edge.vars:
                # Either produced in a single-buffer mem
                if v.is_mem:
                    if v.is_untracked:
                        # The purpose of untracked is not to label the edge as memDep
                        continue
                    return True
                if edge.consumer.struct_alloc:
                    # Or produced in a double-buffer mem
                    if v in edge.consumer.struct_alloc.vars:
                        assert v in edge.consumer.struct_alloc.prod_to_vars[edge.producer]
                        return True
            return False
        def getVarsMemDep(edge):
            memDeps = []
            for v in edge.vars:
                # Either produced in a single-buffer mem
                if v.is_mem:
                    if v.is_untracked:
                        # The purpose of untracked is not to label the edge as memDep
                        continue
                    memDeps.append((v.typee, edge.consumer.get_var_arg_idx(v), "VAR IS MEM"))
                    continue
                if edge.consumer.struct_alloc:
                    # Or produced in a double-buffer mem
                    if v in edge.consumer.struct_alloc.vars:
                        memDeps.append((v.typee, edge.consumer.get_var_arg_idx(v), "VAR PRODUCED IN struct_alloc"))
                        continue
            return memDeps

        for edge in G.out_edges(task.idx):
            cons_in_id_to_prod_out_id = edge.output_ids
            hasMemDataDep = isHasMemDataDep(edge)
            # if hasMemDataDep:
            #     print(f"EDGE {edge.producer.fn} -> {edge.consumer.fn} hasMemDataDep={hasMemDataDep} memDeps={getVarsMemDep(edge)}")
            grouped = group_dict_items(cons_in_id_to_prod_out_id)
            if len(grouped) == 0:
                r = Recipe(edge.consumer, edge.cycle_delta, hasMemDataDep, 0, None, None)
                recipes.append(r)
            else:
                for recipe_pairs in grouped:
                    arg0_in_id, arg0_out_id = recipe_pairs[0]
                    arg1_out_id = None
                    if len(recipe_pairs) > 1:
                        arg1_in_id, arg1_out_id = recipe_pairs[1]
                        assert arg1_in_id == (arg0_in_id+1)
                    r = Recipe(edge.consumer, edge.cycle_delta, hasMemDataDep, arg0_in_id, arg0_out_id, arg1_out_id)
                    recipes.append(r)
        assert len(recipes) < config["RECIPES_PER_TASK"]
        task.recipes = recipes

    for task in G.nodes():
        do_recipes(task)


@dataclass
class HyperGraph:
    filename: str
    nodes: List[Any]                 # typically task objects (must have .idx)
    hyperedges: List[List[int]]      # list of pins (node indices)
    hyperedge_weights: List[int]     # one weight per hyperedge
    node_weights: List[int]          # one weight per node
    dumped: bool = False

    # ----- Your existing helpers (fixed) -----

    def partition_stats(self, k: int, partitions: Dict[int, int], config):
        tasks_per_partition = [0 for _ in range(k)]
        for _, part in partitions.items():
            tasks_per_partition[part] += 1
        print(f"tasks per partition (k={k}): {tasks_per_partition}")

        # for i, n in enumerate(tasks_per_partition):
        #     tup = partition_id_conv(i, config)
        #     print(f"Partition={i} -- tup={tup} -- destTile={dest_tile_conv(tup, config)}")
        # assert False

    def dump(self):
        self.dumped = True
        nconst = 1

        V = len(self.nodes)
        N = len(self.hyperedges)
        num_pins = sum(len(pins) for pins in self.hyperedges)

        # Sanity checks (BUGFIX: use hyperedge_weights)
        assert len(self.hyperedge_weights) == N, "Mismatch: #hyperedge_weights != #hyperedges"
        assert len(self.node_weights) == V, "Mismatch: #node_weights != #nodes"
        assert nconst >= 1, "nconst must be >= 1"

        with open(self.filename, "w") as f:
            f.write(f"0 {V} {N} {num_pins} 3 {nconst}\n")
            for w, pins in zip(self.hyperedge_weights, self.hyperedges):
                line = [str(int(w))] + [str(int(p)) for p in pins]
                f.write(" ".join(line) + "\n")
            for vw in self.node_weights:
                if nconst == 1:
                    f.write(f"{int(vw)}\n")
                else:
                    f.write(" ".join(str(int(x)) for x in vw) + "\n")

    # ----- Partition front-door: flat or hierarchical, supernodes optional -----

    def partition(
        self,
        k: int = None,
        levels: Tuple[int, ...] = None,
        use_supernodes: Callable = None,
        partitioner: "Partitioner" = None,
        get_vars_from_graph: Callable = None,   # only needed if use_supernodes=True
        use_part_hint=None,
        G=None                                  # only needed if use_supernodes=True
    ) -> Tuple[int, float, Dict[int, int]]:
        if (k is None) == (levels is None):
            raise ValueError("Provide exactly one of k or levels (flat OR hierarchical).")

        if partitioner is None:
            def partitioner(hg: "HyperGraph", kk: int) -> List[int]:
                n = len(hg.nodes)
                if kk <= 0:
                    kk = 1
                return [i % kk for i in range(n)]

        # Choose the working hypergraph: base or contracted
        if use_supernodes is not None:
            if get_vars_from_graph is None or G is None:
                raise ValueError("use_supernodes=True requires get_vars_from_graph and G.")

            HG_work, orig_to_super, super_to_members = contract_with_supernodes(
                filename=self.filename,
                G=G,
                get_vars_from_graph=get_vars_from_graph,
                use_part_hint=use_part_hint,
                # co-locate rule (tweak if needed)
                force_union_pred=use_supernodes,
                # build from THIS hypergraph's nodes/edges/weights if they exist
                # (here we re-derive from G for correctness)
            )
        else:
            HG_work = self
            orig_to_super = None
            super_to_members = None

        # Partition (flat or hierarchical)
        if levels is not None:
            parts_work = hierarchical_partition(HG_work, partitioner, levels=tuple(levels))
            k_eff = 1
            for L in levels:
                k_eff *= L
        else:
            parts_work = partitioner(HG_work, k)
            k_eff = k

        # If we used supernodes, expand to original
        if use_supernodes is not None:
            # HG_work nodes correspond to supernodes; map to original tasks in self.nodes (0..V-1)
            # orig_to_super is for tasks sorted by idx in the *contract* builder; we need a robust map.
            # We'll reconstruct mapping via task.idx so it matches `self.nodes`.
            # Build self index-by-idx:
            idx_to_pos_self = {t.idx: pos for pos, t in enumerate(self.nodes)}
            # The contract builder used tasks sorted by t.idx → its orig indices are 0..(len(tasks)-1) by sort order.
            # We need a map from those orig indices to our self node positions.
            # Construct a sorted list of our tasks by .idx to replicate that order:
            tasks_sorted_by_idx = sorted(self.nodes, key=lambda t: t.idx)
            origIndex_to_selfPos = {orig_i: idx_to_pos_self[tasks_sorted_by_idx[orig_i].idx]
                                    for orig_i in range(len(tasks_sorted_by_idx))}
            # Now expand: parts_per_original_selfpos[selfPos] = parts_work[super_of_orig]
            parts_expanded = [0]*len(self.nodes)
            for orig_i, super_i in enumerate(orig_to_super):
                self_pos = origIndex_to_selfPos[orig_i]
                parts_expanded[self_pos] = parts_work[super_i]
            final_parts_list = parts_expanded
        else:
            # Working HG is the same as self
            final_parts_list = parts_work

        # Build dict {task.idx: part}
        partitions_dict = {task.idx: final_parts_list[i] for i, task in enumerate(self.nodes)}

        # Compute simple cut-size & load-balance metrics on *this* graph
        cut_size = compute_cut_size(self.hyperedges, self.hyperedge_weights, final_parts_list)
        load_balance = compute_load_imbalance(final_parts_list, k_eff)

        return cut_size, load_balance, partitions_dict

    # ----- Factory: your original builder (unchanged behavior) -----

    #@staticmethod
    @timed
    def createBasic(filename, G):
        # Collect and sort tasks once
        tasks = list(G.nodes())
        tasks.sort(key=attrgetter("idx"))  # slightly faster than lambda

        # Precompute idx -> position map ONCE (critical)
        node_weights = [] #[1] * V
        idx_to_pos = {}
        for i, t in enumerate(tasks):
            idx_to_pos[t.idx] = i
            #node_weights.append(t.consumed_bytes())
            #node_weights.append(1)
            node_weights.append(t.num_instrs)

        vars_ = get_vars_from_graph(G)

        V = len(tasks)
        hyperedges = []
        hyperedge_weights = []

        # Local bindings to avoid global/attribute lookups in the loop
        append_edge = hyperedges.append
        append_w = hyperedge_weights.append

        for v in vars_:
            writer = getattr(v, "writer", None)
            if writer is None:
                continue

            # Build pins directly in 0..V-1 space without extra set->list churn
            # Readers
            pins = {idx_to_pos[t.idx] for t in v.readers if t.idx in idx_to_pos}
            # Writer
            wpos = idx_to_pos.get(writer.idx)
            if wpos is not None:
                pins.add(wpos)

            if not pins:
                continue

            # If order doesn't matter to the builder, skip sorting:
            # edge = list(pins)
            # If you DO need a stable order, keep this:
            edge = sorted(pins)

            append_edge(edge)

            # Compute weight once
            w = v.bytes()  # Assuming this is O(1); if not, cache it when v is created

            # Choose the weight variant with one set of getattr calls
            is_mem = v.is_mem
            overflows = v.overflows
            if is_mem or overflows:
                append_w(w)
            else:
                append_w(w)

        return HyperGraph(filename, tasks, hyperedges, hyperedge_weights, node_weights)
# ---------- Utilities ----------

def compute_cut_size(hyperedges: List[List[int]], weights: List[int], parts: List[int]) -> int:
    cut = 0
    for pins, w in zip(hyperedges, weights):
        used = set(parts[p] for p in pins)
        if len(used) > 1:
            cut += w
    return cut

def compute_load_imbalance(parts: List[int], k: int) -> float:
    counts = [0]*k
    for p in parts:
        counts[p] += 1
    avg = len(parts)/k if k > 0 else len(parts)
    worst = max(counts) if counts else 0
    return (worst/avg) if avg > 0 else 1.0

# ---------- DSU + SuperNodes contraction ----------

class DSU:
    def __init__(self, n: int):
        self.p = list(range(n))
        self.r = [0]*n
    def find(self, x: int) -> int:
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]
            x = self.p[x]
        return x
    def union(self, a: int, b: int):
        ra, rb = self.find(a), self.find(b)
        if ra == rb: return
        if self.r[ra] < self.r[rb]:
            ra, rb = rb, ra
        self.p[rb] = ra
        if self.r[ra] == self.r[rb]:
            self.r[ra] += 1

@timed
def contract_with_supernodes(
    filename: str,
    G,
    get_vars_from_graph: Callable,
    use_part_hint,
    force_union_pred=None
) -> Tuple[HyperGraph, List[int], Dict[int, List[int]]]:
    assert force_union_pred, f"Should pass func"
    # Build tasks sorted by idx (stable indexing 0..N-1)
    tasks = sorted(list(G.nodes()), key=lambda t: t.idx)
    idx_of = {t: i for i, t in enumerate(tasks)}
    vars_ = get_vars_from_graph(G)

    dsu = DSU(len(tasks))

    # 1. Based on partition hints
    if use_part_hint:
        part_hint_to_tasks = defaultdict(list)
        for t in tasks:
            part_hint_to_tasks[t.part_hint].append(t)
        for same_hint_tasks in part_hint_to_tasks.values():
            root = same_hint_tasks[0]
            for rest in same_hint_tasks[1:]:
                dsu.union(idx_of[root], idx_of[rest])

    # 2. Based memory communication must be mapped in the same tile
    for v in vars_:
        if v.writer is None:
            continue
        if force_union_pred(v):
            w = idx_of[v.writer]
            for r in v.readers:
                dsu.union(w, idx_of[r])

    # 3. Based on mem communication that's physical (not virtual)
    physical_vars = set()
    for v in vars_:
        pv = v.get_physical()
        if pv != v:
            physical_vars.add(pv)
    physical_vars = sorted(list(physical_vars), key=lambda v: v.idx)
    for pv in physical_vars:
        vvs = pv.get_virtuals()
        pvts = set()
        for vv in vvs:
            if vv.writer is not None:
                pvts.add(vv.writer)
            for r in vv.readers:
                pvts.add(vv.writer)
        pvts = sorted(list(pvts), key=lambda t: t.idx if t is not None else 0)
        root = pvts[0]
        for o in pvts[1:]:
            dsu.union(idx_of[root], idx_of[o])

    # 4. If two tasks communicate more than allowed memory
    for e in G.edges():
        if e.typee != "Data":
            assert e.typee == "Order"
            continue
        vars_comm = set([v for (d, _, v) in e.consumer.args if ((d == LotusTask.ARG_DIR.IN) and (v.writer == e.producer) and (not force_union_pred(v)))])
        vars_bytes = sum([v.bytes() for v in vars_comm])
        if vars_bytes >= (10*4):
            dsu.union(idx_of[e.producer], idx_of[e.consumer])

    # Map original -> super root ids
    root_to_super = {}
    super_members: Dict[int, List[int]] = {}
    for i, _t in enumerate(tasks):
        r = dsu.find(i)
        if r not in root_to_super:
            root_to_super[r] = len(root_to_super)
            super_members[root_to_super[r]] = []
        super_members[root_to_super[r]].append(i)
    orig_to_super = [root_to_super[dsu.find(i)] for i in range(len(tasks))]
    S = len(super_members)

    # Sum node weights into supernodes (default weight=1)
    node_weights_super = [0]*S
    for i, t in enumerate(tasks):
        #node_weights_super[orig_to_super[i]] += t.consumed_bytes()
        #node_weights_super[orig_to_super[i]] += 1
        node_weights_super[orig_to_super[i]] += t.num_instrs

    # Rebuild hyperedges over supernodes; aggregate identical pin-sets
    he_counter: Dict[Tuple[int, ...], int] = {}
    for v in vars_:
        if v.writer is None:
            continue
        pins = { orig_to_super[idx_of[v.writer]] }
        pins |= { orig_to_super[idx_of[r]] for r in v.readers }
        pins = sorted(pins)
        if len(pins) < 2:
            continue
        key = tuple(pins)
        w = v.bytes() if hasattr(v, "bytes") else 1
        he_counter[key] = he_counter.get(key, 0) + w

    hyperedges_super = [list(p) for p in he_counter.keys()]
    hyperedge_weights_super = list(he_counter.values())

    # For supergraph nodes, store a representative tuple of member original indices
    super_nodes = [tuple(super_members[i]) for i in range(S)]

    if True:
        super_nodes_stats = stats_int([len(super_members[i]) for i in range(S)])
        print(f"Stats for Number of Nodes Per Super-Node ====== ")
        for s in ["min", "max", "mean", "median", "std_dev"]:
            print(f"    {s:<{10}} = {super_nodes_stats[s]}")

    HG_super = HyperGraph(
        filename=filename,
        nodes=super_nodes,
        hyperedges=hyperedges_super,
        hyperedge_weights=hyperedge_weights_super,
        node_weights=node_weights_super
    )
    return HG_super, orig_to_super, super_members

# ---------- Hierarchical partitioning ----------

Partitioner = Callable[[HyperGraph, int], List[int]]

def induce_subgraph(hg: HyperGraph, keep_nodes: List[int]) -> HyperGraph:
    keep = set(keep_nodes)
    new_idx = {old: i for i, old in enumerate(keep_nodes)}

    new_hyperedges = []
    new_hyperedge_weights = []
    for pins, w in zip(hg.hyperedges, hg.hyperedge_weights):
        pins2 = sorted({new_idx[p] for p in pins if p in keep})
        if len(pins2) >= 2:
            new_hyperedges.append(pins2)
            new_hyperedge_weights.append(w)

    new_nodes = [hg.nodes[i] for i in keep_nodes]
    new_node_weights = [hg.node_weights[i] for i in keep_nodes]

    return HyperGraph(
        filename=hg.filename,
        nodes=new_nodes,
        hyperedges=new_hyperedges,
        hyperedge_weights=new_hyperedge_weights,
        node_weights=new_node_weights
    )

@timed
def hierarchical_partition(hg: HyperGraph, partitioner: Partitioner, levels: Tuple[int, ...]) -> List[int]:
    Ks = list(levels)
    n = len(hg.nodes)

    # Level 0
    k0 = max(1, Ks[0])
    ratio = 1
    k00 = k0 * ratio
    p0 = partitioner(hg, min(k00, max(1, n)))
    # Using min_p ensures this work whether we're zero based or 1-based
    min_p = min(p0)
    p0 = [(p - min_p) % k0 + min_p for p in p0]
    codes_per_node = [[p0[i]] for i in range(n)]
    current_level_parts = p0

    # Refinement levels
    for level in range(1, len(Ks)):
        kL = max(1, Ks[level])
        parent_to_nodes: Dict[int, List[int]] = {}
        for i, parent in enumerate(current_level_parts):
            parent_to_nodes.setdefault(parent, []).append(i)

        next_level_parts = [0]*n
        for parent, group_nodes in parent_to_nodes.items():
            sub = induce_subgraph(hg, group_nodes)
            if len(sub.nodes) == 0:
                continue
            k_eff = min(kL, max(1, len(sub.nodes)))
            sub_parts = partitioner(sub, k_eff)
            for local_i, global_i in enumerate(group_nodes):
                next_level_parts[global_i] = sub_parts[local_i]
                codes_per_node[global_i].append(sub_parts[local_i])

        current_level_parts = next_level_parts

    final_parts = []
    for codes in codes_per_node:
        acc = codes[0]
        for i in range(1, len(Ks)):
            acc = acc*Ks[i] + codes[i]
        final_parts.append(acc)
    return final_parts

def make_patoh_partitioner(
    patoh_bin: str = os.path.join(os.environ["PATOH"], "patoh"),
    flags: Optional[str] = "FI=0.15 PQ=Q",
    #flags: Optional[str] = "PQ=Q",
    workdir: Optional[str] = None,
):
    def _dump_hgr_to(path: str, V: int, N: int, num_pins: int, node_w: List[int], hedges: List[List[int]], hedge_w: List[int]):
        nconst = 1
        assert len(hedge_w) == N, "Mismatch: #hyperedge_weights != #hyperedges"
        assert len(node_w) == V, "Mismatch: #node_weights != #nodes"
        assert nconst >= 1, "nconst must be >= 1"

        with open(path, "w") as f:
            # Same header shape you already use: "0 V N pins 3 nconst"
            f.write(f"0 {V} {N} {num_pins} 3 {nconst}\n")
            for w, pins in zip(hedge_w, hedges):
                line = [str(int(w))] + [str(int(p)) for p in pins]
                f.write(" ".join(line) + "\n")
            for vw in node_w:
                if nconst == 1:
                    f.write(f"{int(vw)}\n")
                else:
                    f.write(" ".join(str(int(x)) for x in vw) + "\n")

    def _read_solution(path: str, V: int) -> List[int]:
        parts: List[int] = []
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts.extend(int(tok) for tok in line.split())
        if len(parts) != V:
            raise ValueError(f"Solution length {len(parts)} != number of vertices {V}")
        return parts

    @timed
    def _partitioner(hg, k: int) -> List[int]:
        V = len(hg.nodes)
        if k <= 1 or V == 0:
            return [0]*V

        # Compute pins count
        N = len(hg.hyperedges)
        num_pins = sum(len(p) for p in hg.hyperedges)

        # Choose a working directory
        base_dir = workdir or (os.path.dirname(hg.filename) if hg.filename else os.getcwd())

        # Create a unique temp filename (no extension required by PaToH, but we'll use .hgr for clarity)
        unique = uuid.uuid4().hex
        hgr_path = os.path.join(base_dir, f"{os.path.basename(hg.filename) or 'graph'}.{unique}.hgr")
        sol_path = f"{hgr_path}.part.{int(k)}"

        # Always dump fresh (don’t mutate hg.dumped; subgraphs may share names)
        _dump_hgr_to(
            path=hgr_path,
            V=V,
            N=N,
            num_pins=num_pins,
            node_w=hg.node_weights,
            hedges=hg.hyperedges,
            hedge_w=hg.hyperedge_weights
        )

        # Build command
        cmd = [patoh_bin, hgr_path, str(int(k))]
        if flags:
            cmd.append(flags)
        print(f"patoh command: {' '.join(cmd)}")

        # Run PaToH
        proc = subprocess.run(cmd, capture_output=True, text=True)

        if proc.returncode != 0:
            # Keep temp files for debugging
            raise RuntimeError(
                "PaToH failed with exit code "
                f"{proc.returncode}\nCMD: {' '.join(cmd)}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
            )

        # Parse metrics (optional: not returned; you already compute cut/imbalance in Python)
        # Try a few common patterns PaToH prints
        # (We don't *need* these for the interface, but they’re useful when debugging.)
        _ = re.search(r"Cut(?:size| Cost):\s*([0-9]+)", proc.stdout)
        _ = re.search(r"(?:Balance|Imbalance|Load\s+Imbalance):\s*([0-9.]+)", proc.stdout)

        # Read solution
        if not os.path.isfile(sol_path):
            # Some PaToH builds write to <basename>.part.<k> without .hgr; try that too
            alt_sol_path = f"{os.path.splitext(hgr_path)[0]}.part.{int(k)}"
            if os.path.isfile(alt_sol_path):
                sol_path = alt_sol_path
            else:
                raise FileNotFoundError(f"Expected solution file not found: {sol_path}")

        parts = _read_solution(sol_path, V)

        # Optional cleanup: you can remove temp files here if desired.
        # Keep them if you want to inspect results or reuse for later runs.
        # try:
        #     os.remove(hgr_path)
        #     os.remove(sol_path)
        # except OSError:
        #     pass

        return parts

    return _partitioner

@timed
def map_tasks_cpu(G, config):
    #tasks = [t for t in G.nodes()]
    def get_task_instrs_helper():
        nonlocal G
        nonlocal config
        fns = set()
        for t in G.nodes():
            fns.add(t.fn)
        fn_to_instrs = get_task_instrs("tasks_sizes", fns, config)
        for t in G.nodes():
            t.num_instrs = fn_to_instrs[t.fn]

    get_task_instrs_helper()

    filename = os.path.join(config["OUT_PATH"], "part_graph_cpu.hgr")
    graph = HyperGraph.createBasic(filename, G)
    partitioner = make_patoh_partitioner()

    numPartitions = config["CORES_PER_TILE"]
    cut_size, load_balance, partitions = graph.partition(
        k=numPartitions,
        use_supernodes=lambda v: v.is_same_cycle(G) or v.is_mem,
        partitioner=partitioner,
        get_vars_from_graph=get_vars_from_graph,
        G=G
    )

    graph.partition_stats(numPartitions, partitions, config)

    tasks_per_thread = [[] for _ in range(numPartitions)]
    for task in graph.nodes:
        task.mappedTo = (partitions[task.idx],)


@timed
def map_tasks(G, config):

    def get_task_instrs_helper():
        nonlocal G
        nonlocal config
        fns = set()
        for t in G.nodes():
            fns.add(t.fn)
        fn_to_instrs = get_task_instrs("tasks_sizes", fns, config)
        for t in G.nodes():
            t.num_instrs = fn_to_instrs[t.fn]

    get_task_instrs_helper()


    filename = os.path.join(config["OUT_PATH"], "part_graph.hgr")
    graph = HyperGraph.createBasic(filename, G)

    hier = True
    #use_supernodes = lambda v: v.is_mem or v.overflows or (v.size > 16)
    use_supernodes = lambda v: v.is_mem or v.overflows
    partitioner = make_patoh_partitioner()

    over_partition_ratio = 1

    if hier:
        # Hierarchical
        levels = ((config["DEVICES"]*over_partition_ratio), config["TILES_PER_DEVICE"])
        cut_size, load_balance, partitions = graph.partition(
            levels=levels,
            use_supernodes=use_supernodes,
            partitioner=partitioner,
            get_vars_from_graph=get_vars_from_graph,
            use_part_hint=config["HAS_PART_HINTS"],
            G=G
        )
        k_final = 1
        for L in levels:
            k_final *= L
    else:
        # Flat
        k = (config["DEVICES"]*over_partition_ratio) * config["TILES_PER_DEVICE"]
        cut_size, load_balance, partitions = graph.partition(
            k=k,
            use_supernodes=use_supernodes,
            partitioner=partitioner,
            get_vars_from_graph=get_vars_from_graph,
            use_part_hint=config["HAS_PART_HINTS"],
            G=G
        )
        k_final = k

    graph.partition_stats(k_final, partitions, config)
    for task in graph.nodes:
        # If you need a conversion func, plug it back:
        #task.mappedTo = dest_tile_conv(partitions[task.idx], config)
        actual_tiles = config["DEVICES"] * config["TILES_PER_DEVICE"]
        par = partitions[task.idx] % actual_tiles
        if over_partition_ratio == 1:
            assert par == partitions[task.idx]
        task.mappedTo = partition_id_conv(par, config)
        #task.mappedTo = partitions[task.idx]

    tasks_per_partition = defaultdict(int)
    instructions_per_partition = defaultdict(int)
    for task in graph.nodes:
        tasks_per_partition[task.mappedTo] += 1
        instructions_per_partition[task.mappedTo] += task.num_instrs

    tasks_per_partition        = stats_int(list(tasks_per_partition.values()))
    instructions_per_partition = stats_int(list(instructions_per_partition.values()))

    do_stats = [("Tasks Per Partition", tasks_per_partition), ("Instructions Per Partition", instructions_per_partition)]

    for name, sd in do_stats:
        print(f"{name} ====== ")
        for s in ["min", "max", "mean", "median", "std_dev"]:
            print(f"    {s:<{10}} = {sd[s]}")


    for var in get_vars_from_graph(G):
        if (not getattr(var, "is_mem", False)) or (not getattr(var, "overflows", False)) or (var.writer is None):
            continue
        w = var.writer
        for r in var.readers:
            assert w.mappedTo == r.mappedTo, "Mem communication has to be same tile"

    return cut_size, load_balance, partitions

def get_tile_structs(G, config):
    structs = []
    numTiles = 1 << ( 1 if config["TILES_PER_DEVICE"] == 1 else int(math.ceil(math.log2(config["TILES_PER_DEVICE"]))))
    for t_id in range(config["DEVICES"]*numTiles):
        structs.append(TileStruct(t_id))

    physical_mem_vars = {v.get_physical() for v in get_vars_from_graph(G) if v.is_mem}
    physical_mem_vars = sorted(list(physical_mem_vars), key=lambda v: v.idx)
    for v in physical_mem_vars:
        assert v.is_mem
        mappedTo = set()
        for vv in v.get_virtuals():
            if vv.writer:
                mappedTo.add(vv.writer.mappedTo)
            for r in vv.readers:
                mappedTo.add(r.mappedTo)
        assert len(mappedTo) == 1
        (mappedTo,) = mappedTo
        mappedTo = dest_tile_conv(mappedTo, config)
        #mappedTo = partition_id_conv(t.mappedTo, config)
        # NOTE(farese): The physical var is the one being added
        structs[mappedTo].add_var(v)

    for task in G.nodes():
        if task.struct_alloc:
            mappedTo = dest_tile_conv(task.mappedTo, config)
            #mappedTo = partition_id_conv(task.mappedTo, config)
            structs[mappedTo].add_var(task.struct_alloc)
    return structs

class CppFileGenerator:
    class LotusRegCommit:
        def __init__(self, arg0, arg1):
            self.arg0 = arg0
            self.arg1 = arg1
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            if self.arg0 is None:
                return "lotus::stream_outputs();"
            if self.arg0 is not None and self.arg1 is None:
                return f"lotus::stream_outputs({self.arg0});"
            return f"lotus::stream_outputs({self.arg0}, {self.arg1});"
        def __str__(self):
            return self.get_line()
    class LotusDeq:
        def __init__(self):
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return "lotus::finish_task();"
        def __str__(self):
            return self.get_line()
    class LotusHeartbeat:
        def __init__(self):
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return "lotus::heartbeat();"
        def __str__(self):
            return self.get_line()
    class Assignment:
        def __init__(self, lhs, rhs):
            self.lhs = lhs
            self.rhs = rhs
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return f"{self.lhs} = {self.rhs};"
        def __str__(self):
            return self.get_line()
    class MoveBytes:
        def __init__(self, dst, src, dstOff, srcOff, leng):
            self.dst = dst
            self.src = src
            self.dstOff = dstOff
            self.srcOff = srcOff
            self.leng = leng
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return f"move_bytes<{self.dstOff}, {self.srcOff}, {self.leng}>({self.dst}, {self.src});"
    class MoveBytesToU32:
        def __init__(self, dst, src, dstOff, srcOff, leng):
            self.dst = dst
            self.src = src
            self.dstOff = dstOff
            self.srcOff = srcOff
            self.leng = leng
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return f"move_bytes_to_u32<{self.dstOff}, {self.srcOff}, {self.leng}>({self.dst}, {self.src});"
    class TupleExtract:
        def __init__(self, varName, idx):
            self.varName = varName
            self.idx = idx
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return f"std::get<{self.idx}>({self.varName})"
        def __str__(self):
            return self.get_line()
    class StaticCast:
        def __init__(self, typee, name):
            self.typee = typee
            self.name = name
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return f"static_cast<{self.typee}>({self.name})"
        def __str__(self):
            return self.get_line()
    class BitCast:
        def __init__(self, typee, name):
            self.typee = typee
            self.name = name
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return f"std::bit_cast<{self.typee}>({self.name})"
        def __str__(self):
            return self.get_line()
    class Unpack:
        def __init__(self, typee, name, byte_off):
            self.typee = typee
            self.name = name
            self.byte_off = byte_off
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return f"unpack_from_u32<{self.typee}>({self.name}, {self.byte_off})"
        def __str__(self):
            return self.get_line()
    class Pack:
        def __init__(self, out, typee, name, byte_off):
            self.out = out
            self.typee = typee
            self.name = name
            self.byte_off = byte_off
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return f"pack_into_u32<{self.typee}>({self.out}, {self.name}, {self.byte_off});"
        def __str__(self):
            return self.get_line()
    class CastToReference:
        def __init__(self, typee, name):
            self.typee = typee
            self.name = name
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return f"*reinterpret_cast<{self.typee}*>({self.name})"
        def __str__(self):
            return self.get_line()
    class Line:
        def __init__(self, l):
            self.l = l
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            return f"{self.l}"
        def __str__(self):
            return self.get_line()
    class FunctionSignature:
        def __init__(self, return_type, fn_name, args, decl=False):
            self.return_type = return_type
            self.fn_name = fn_name
            self.args = args
            self.decl = decl
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            args = ", ".join([f"{t} {n}" for t,n in self.args])
            l = f"{self.return_type} {self.fn_name}({args})"
            if self.decl:
                l += ";"
            return l
        def __str__(self):
            return self.get_line()
    class FunctionCall:
        def __init__(self, func_name, args):
            self.func_name = func_name
            self.args = args
            self.got_line = False
        def get_line(self):
            if self.got_line:
                return None
            self.got_line = True
            args = ", ".join(self.args)
            return f"{self.func_name}({args});"
        def __str__(self):
            return self.get_line()

    class Scope:
        def __init__(self):
            self.statements = []
            self.i = None
            self.done = False
        def add(self, stat):
            self.statements.append(stat)
        def get_line(self):
            if self.done:
                return None
            if self.i is None:
                self.i = 0
                return "{"
            while self.i < len(self.statements):
                l = self.statements[self.i].get_line()
                if l is not None:
                    return f"    {l}"
                self.i += 1
            self.done = True
            return "}"
        def get_lines(self):
            lines = []
            while True:
                line = self.get_line()
                if line is None:
                    break
                lines.append(line)
            return lines
        def __str__(self):
            return "\n".join(self.get_lines())

    def __init__(self, name):
        self.name = name
        self.statements = []

    def add(self, i):
        self.statements.append(i)
    def get_lines(self):
        lines = []
        i = 0
        while i < len(self.statements):
            l = self.statements[i].get_line()
            if l is not None:
                lines.append(l)
                continue
            i += 1
        return lines
    def flush(self):
        with open(f"{self.name}", "w", encoding="utf-8") as f:
            f.write(f"{self}")

        print(f"CppFileGenerator -- Generated {self.name}")
    def __str__(self):
        return "\n".join(self.get_lines())


@timed
def gen_cpp_main(G, tile_structs, config):
    def gen_structs(gen, task_groups):
        nonlocal tile_structs
        task_structs = []
        for grb in task_groups:
            sa = grb[0].struct_alloc
            if sa:
                task_structs.append(sa)

        gen.add(CppFileGenerator.Line(f"///////// Forward declaring task structs"))
        for sa in task_structs:
            gen.add(CppFileGenerator.Line(f"struct {sa.type_name};"))
        gen.add(CppFileGenerator.Line(f"\n"))

        gen.add(CppFileGenerator.Line(f"///////// Defining *task* structs"))
        for sa in task_structs:
            gen.add(CppFileGenerator.Line(sa.to_str()))
        gen.add(CppFileGenerator.Line(f"\n"))

        # gen.add(CppFileGenerator.Line(f"///////// Defining *tile* structs"))
        # for tile_struct in tile_structs:
        #     gen.add(CppFileGenerator.Line(''))
        #     gen.add(CppFileGenerator.Line('struct {'))
        #     for i, v in enumerate(tile_struct.vars):
        #         if isinstance(v, LotusVar):
        #             gen.add(CppFileGenerator.Line(f'    {v.typee} var_{i};'))
        #         elif isinstance(v, TaskStruct):
        #             gen.add(CppFileGenerator.Line(f'    std::array<{v.type_name}, 2> var_{i};'))
        #         else:
        #             assert False
        #     gen.add(CppFileGenerator.Line('} ' + f'{tile_struct.name};'))
        #     gen.add(CppFileGenerator.Line(''))
    def gen_wrappers(gen, task_groups):
        nonlocal G
        nonlocal config

        wrapper_samples = []
        for tasks in task_groups:
            sample_task = tasks[0]
            wrapper_fn_name = f"fn__{sample_task.fn}___example_id__{sample_task.idx}___num_users__{len(tasks)}_wrapper"
            if sample_task.setsHeartbeats:
                wrapper_fn_name += "_setsHeartbeats"

            wrapper_samples.append(tasks[0])
            for task in tasks:
                task.wrapper_fn = wrapper_fn_name
            arg_types = []
            arg_names = []
            MAX_FUNC_ARGS = 15 #8
            totalArgs = len(sample_task.register_alloc.regs) + (1 if sample_task.struct_alloc else 0)

            for i in range(totalArgs):
                if i < MAX_FUNC_ARGS:
                    arg_types.append("Word")
                    arg_names.append(f"in_reg_{i}")


            gen.add(CppFileGenerator.FunctionSignature("void __attribute__((riscv_lotus_task_cc))", wrapper_fn_name, list(zip(arg_types, arg_names)), False))
            functionScope = CppFileGenerator.Scope()
            gen.add(functionScope)

            functionScope.add(CppFileGenerator.Line(f"// Signature: {sample_task.sig()}"))
            functionScope.add(CppFileGenerator.Line(f"// Total args: {len(sample_task.register_alloc.regs)}"))

            if totalArgs > MAX_FUNC_ARGS:
                functionScope.add(CppFileGenerator.Line("__LOTUS_EXTRA_TASK_ARGS__(Word, in_reg_)"))
                functionScope.add(CppFileGenerator.Line(""))

            if sample_task.struct_alloc:
                sa = sample_task.struct_alloc
                functionScope.add(CppFileGenerator.Line(f"{sa.type_name}* localStruct = reinterpret_cast<{sa.type_name}*>(in_reg_{totalArgs-1});"))

            gen.add(CppFileGenerator.Line(''))
            if sample_task.setsHeartbeats:
                unroll = config['UNROLL_FACTOR']
                assert unroll >= 1, f"Unroll must be >= 1: {unroll}"
                # To simplify results scripts, just increment heartbeats
                # by the unroll factor for each Lotus cycle
                for i in range(unroll):
                    functionScope.add(CppFileGenerator.LotusHeartbeat())


            function_call_args = []
            vars_to_names  = {}
            for i, (dir, acc, var) in enumerate(sample_task.args):
                name = f"arg_{i}"
                function_call_args.append(name)
                if (dir == LotusTask.ARG_DIR.OUT) and (not var.is_mem):
                    comp = []
                else:
                    comp = sample_task.get_in_var_comp(var)
                if sample_task.struct_alloc:
                    localStructRef = sample_task.struct_alloc.get_layout_ref("localStruct", var, False)
                else:
                    localStructRef = None
                if len(comp):
                    in_reg_id, _ = comp[0]
                    if acc in [LotusTask.ARG_ACCESS.PARTIAL, LotusTask.ARG_ACCESS.PARTIAL_UNTRACKED]:
                        assert len(comp) == 1
                        _, _, a, regByte, _, _, numBytes = comp[0][1]
                        assert a == acc
                        assert regByte == 0
                        assert numBytes == 4
                        functionScope.add(CppFileGenerator.Assignment(f"{var.typee}& {name}", CppFileGenerator.CastToReference(var.typee, f"in_reg_{in_reg_id}")))
                    else:
                        functionScope.add(CppFileGenerator.Line(f"{var.typee} {name}" + "{};"))
                        varScope = CppFileGenerator.Scope()
                        functionScope.add(varScope)
                        for in_reg_id, (_, _, _, regByte, varByte, _, numBytes) in comp:
                            varScope.add(CppFileGenerator.MoveBytes(name, f"in_reg_{in_reg_id}", varByte, regByte, numBytes))
                elif localStructRef:
                    if acc in [LotusTask.ARG_ACCESS.PARTIAL, LotusTask.ARG_ACCESS.PARTIAL_UNTRACKED]:
                        functionScope.add(CppFileGenerator.Assignment(f"{var.typee}& {name}", f"*{localStructRef}"))
                    else:
                        functionScope.add(CppFileGenerator.Assignment(f"{var.typee}& {name}", f"{localStructRef}"))
                else:
                    assert acc == LotusTask.ARG_ACCESS.FULL, f"access is: {acc.name}"
                    assert dir == LotusTask.ARG_DIR.OUT
                    functionScope.add(CppFileGenerator.Line(f"{var.typee} {name}" + "{};"))
                vars_to_names[var] = name


            functionScope.add(CppFileGenerator.FunctionCall(sample_task.fn, function_call_args))

            if sample_task.output_mem is not None:
                for sa, vars in sample_task.output_mem.items():
                    localStruct = sample_task.struct_alloc.get_layout_ref("localStruct", sa, False)
                    for v in vars:
                        assert not v.is_mem
                        #lhs = sa.get_layout_ref(localStruct, v.cycle_delta, v)
                        lhs = sa.get_layout_ref(localStruct, v, True)
                        rhs = vars_to_names[v]
                        functionScope.add(CppFileGenerator.Assignment(lhs, rhs))

            output_names = []
            for out_idx in range(len(sample_task.output_table.regs)):
                name = f"out_reg_{out_idx}"
                output_names.append(name)
                functionScope.add(CppFileGenerator.Assignment(f"Word {name}", "0"))
                varScope = CppFileGenerator.Scope()
                functionScope.add(varScope)
                for (_, var, acc, regByte, varByte, _, numBytes) in sample_task.output_table.regs[out_idx]:
                    assert acc == LotusTask.ARG_ACCESS.FULL
                    varScope.add(CppFileGenerator.MoveBytesToU32(name, vars_to_names[var], regByte, varByte, numBytes))
            if len(output_names) == 0:
                functionScope.add(CppFileGenerator.LotusRegCommit(None, None))
            else:
                output_names = [output_names[i:i+2] for i in range(0, len(output_names), 2)]
                for grp in output_names:
                    arg0 = grp[0]
                    arg1 = grp[1] if len(grp) > 1 else None
                    functionScope.add(CppFileGenerator.LotusRegCommit(arg0, arg1))
            functionScope.add(CppFileGenerator.LotusDeq())
        return wrapper_samples

    def gen_main(gen, wrapper_samples):
        gen.add(CppFileGenerator.Line(''))
        gen.add(CppFileGenerator.FunctionSignature("int", "main", [], False))
        mainScope = CppFileGenerator.Scope()
        gen.add(mainScope)

        for task in wrapper_samples:
            fScope = CppFileGenerator.Scope()
            mainScope.add(fScope)

            args = []
            for _ in range(len(task.register_alloc.regs)):
                args.append("0")
            if task.struct_alloc:
                args.append("0")
            MAX_FUNC_ARGS = 15 # was 8
            args = args[:MAX_FUNC_ARGS]
            #sa = task.struct_alloc
            #args.append(f"reinterpret_cast<{sa.type_name}*>(0)")
            fScope.add(CppFileGenerator.FunctionCall(task.wrapper_fn, args))

        mainScope.add(CppFileGenerator.Line("return 0;"))

    cpp_filename = os.path.join(config["OUT_PATH"], config["BENCH_NAME"]) + ".cpp"
    gen = CppFileGenerator(cpp_filename)

    gen.add(CppFileGenerator.Line('#include <tuple>'))
    gen.add(CppFileGenerator.Line('#include <bit>'))
    gen.add(CppFileGenerator.Line('#include "lotus_api.h"'))
    ti = config["TASKS_INCLUDE"]
    gen.add(CppFileGenerator.Line(f'#include "{ti}"'))

    for ih in config["GENERATED_FILES_TO_INCLUDE"]:
        gen.add(CppFileGenerator.Line(f'#include "{ih}"'))

    gen.add(CppFileGenerator.Line(''))

    task_groups = LotusTask.get_groups(G)
    gen_structs(gen, task_groups)
    wrapper_samples = gen_wrappers(gen, task_groups)
    gen_main(gen, wrapper_samples)
    gen.flush()

@timed
def make_task_structs_concrete(G, config):
    def align_by(sa, addr, align):
        newAddr = ((addr + align - 1) // align) * align
        if newAddr != addr:
            assert newAddr > addr
            sa.layout.append(newAddr - addr)
        return newAddr
    groups = []
    for _ in range(G.meta["num_groups"]):
        groups.append([])

    for task in sorted(G.nodes(), key=lambda t: t.idx):
        if task.struct_alloc:
            groups[task.group_id].append(task.struct_alloc)

    types_to_get_sizes_for = []
    types_definitions = []
    for i, grb in enumerate(groups):
        type_name = f"TaskStructGroup{i}_t"
        for sa in grb:
            sa.type_name = type_name
            sa.instance_name = f"task_struct_for_idx_{sa.task.idx}"
            sa.layout = []
            sa.struct_pointers.sort(key=lambda sp: sp.task.idx)
            sa.layout.extend(sa.struct_pointers)
            addr = 0
            for vars_s in sa.prod_to_vars.values():
                vars = sorted(list(vars_s), key=lambda v: (not v.is_mem, -v.size, v.idx))
                addr = align_by(sa, addr, 4)
                for v in vars:
                    if v.is_mem:
                        addr = align_by(sa, addr, 4)
                        sa.layout.append(v)
                        addr += 4
                    else:
                        addr = align_by(sa, addr, v.align)
                        sa.layout.append(v)
                        addr += v.size
            # NOTE: This makes all structs have a size to be amultiple of 4
            #       Making sure there is never any hidden padding at the end.
            #       In some cases this might not be needed, but simplifies both
            #       hidden padding detection at the end and later when constructing tile structs
            addr = align_by(sa, addr, 4)

    for i, grb in enumerate(groups):
        if len(grb):
            assert len(grb[0].layout) > 0, f"Task struct has no elements, {grb[0]}"
            types_to_get_sizes_for.append(grb[0].type_name)
            types_definitions.append(grb[0].to_str())

    forward_declare = [f"struct {t};" for t in types_to_get_sizes_for]

    types_definitions = "\n".join(forward_declare + ["\n"] + types_definitions)
    sizes = get_type_sizes("struct_sizes", types_to_get_sizes_for, config, types_definitions)

    for grb in groups:
        if len(grb):
            size, align = sizes[grb[0].type_name]
            for sa in grb:
                sa.size = size
                sa.align = align
@timed
def assign_task_ids(G, config):
    def create_rank_graph(G):
        def edge_has_mem(e):
            for v in e.vars:
                if v.is_mem:
                    return True
            return False
        G_rank = nx.DiGraph()
        for n in G.nodes():
            G_rank.add_node(n.idx, data=n)
        for e in G.edges():
            if e.producer == e.consumer:
                continue
            if edge_has_mem(e):
                # Handles Case (1)
                if e.cycle_delta == 0:
                    G_rank.add_edge(e.producer.idx, e.consumer.idx)
                else:
                    G_rank.add_edge(e.consumer.idx, e.producer.idx)
            elif e.cycle_delta == 0:
                # Handles Case (2)
                G_rank.add_edge(e.producer.idx, e.consumer.idx)

        return G_rank
    has_cross_device_edge = set()
    for t in G.nodes():
        deviceId, _ = t.mappedTo
        for edge in G.out_edges(t):
            child = edge.consumer
            child_deviceId, _ = child.mappedTo
            if deviceId != child_deviceId:
                has_cross_device_edge.add(t.idx)
                break
    def sink_distance_layers_prioritized(G):
        if not nx.is_directed_acyclic_graph(G):
            raise ValueError("Graph must be a DAG")

        # --- 1) compute dist_to_sink on FULL graph
        topo_rev = list(reversed(list(nx.topological_sort(G))))

        dist_to_sink = {n: 0 for n in G.nodes()}
        for u in topo_rev:
            succs = list(G.successors(u))
            if succs:
                dist_to_sink[u] = 1 + max(dist_to_sink[v] for v in succs)

        maxd = max(dist_to_sink.values(), default=0)
        rank = {n: maxd - d for n, d in dist_to_sink.items()}  # smaller rank => higher priority

        # group nodes by rank
        layers_by_rank = {}
        for n, r in rank.items():
            layers_by_rank.setdefault(r, []).append(n)

        # --- 2) build priority closure: flagged nodes + all their ancestors ---
        flagged = [n for n in G.nodes() if n in has_cross_device_edge]
        if not flagged:
            # fallback to original behavior
            return [layers_by_rank[i] for i in range(max(layers_by_rank) + 1)] if layers_by_rank else []

        priority = set(flagged)
        for n in flagged:
            priority |= nx.ancestors(G, n)

        # --- 3) emit layers: priority first, then the rest ---
        out = []
        max_rank = max(layers_by_rank) if layers_by_rank else -1

        for r in range(max_rank + 1):
            pr = [n for n in layers_by_rank.get(r, []) if n in priority]
            if pr:
                out.append(pr)

        for r in range(max_rank + 1):
            rest = [n for n in layers_by_rank.get(r, []) if n not in priority]
            if rest:
                out.append(rest)

        return out

    def get_task_to_rank(G):
        G_rank = create_rank_graph(G)
        task_to_rank = {}
        for r, layer in enumerate(sink_distance_layers_prioritized(G_rank)):
            tasks = [G_rank.nodes[n]['data'] for n in layer]
            for t in tasks:
                task_to_rank[t] = r
        return task_to_rank

    task_to_rank = get_task_to_rank(G)

    dest_tile_to_tasks = defaultdict(list)
    for task in G.nodes():
        dest_tile_to_tasks[task.mappedTo].append(task)

    for tasks_in_tile in dest_tile_to_tasks.values():
        assert len(tasks_in_tile) < config["TASKS_PER_TILE"]
        tasks_in_tile.sort(key=lambda t: (task_to_rank[t], t.idx))
        for task_id, t in enumerate(tasks_in_tile):
            t.task_id = task_id
@timed
def gen_host_init(G, tile_structs, config):
    def add_hw_config(host_init):
        nonlocal config
        host_init["hwConfig"] = {
            "numDevices": config["DEVICES"],
            "numTilesPerDevice": config["TILES_PER_DEVICE"],
        }
    def add_recipe_tables(host_init):
        nonlocal G
        nonlocal config
        dest_tile_to_tasks = {}
        for task in G.nodes():
            if task.mappedTo not in dest_tile_to_tasks:
                dest_tile_to_tasks[task.mappedTo] = []
            dest_tile_to_tasks[task.mappedTo].append(task)

        for dest_tile in dest_tile_to_tasks:
            dest_tile_to_tasks[dest_tile].sort(key=lambda task: task.task_id)

        numTiles = 1 << ( 1 if config["TILES_PER_DEVICE"] == 1 else int(math.ceil(math.log2(config["TILES_PER_DEVICE"]))))
        global_recipes = [[] for _ in range(config["DEVICES"]*numTiles)]
        for dest_tile, tasks in dest_tile_to_tasks.items():
            l_recipes = global_recipes[dest_tile_conv(dest_tile, config)]
            for task in tasks:
                task.edgeRecipeStart = len(l_recipes)
                l_recipes.extend(task.recipes)

        def convert_recipe_to_dict(tile_id, recipe_id, recipe):
            nonlocal config
            invalid_i = config["OUT_REGS_PER_TASK"]
            args = []
            numArgs = 0
            if recipe.arg0 is not None:
                args.append(recipe.arg0)
                numArgs += 1
            else:
                args.append(invalid_i)
            if recipe.arg1 is not None:
                args.append(recipe.arg1)
                numArgs += 1
            else:
                args.append(invalid_i)
            args = [str(a) for a in args]
            return {
                "tileId"        : str(tile_id),
                "entryIdx"      : str(recipe_id),
                "targetTileId"  : str(dest_tile_conv(recipe.dst_task.mappedTo, config)),
                "targetTaskId"  : str(recipe.dst_task.task_id),
                "cycleDelta"    : str(recipe.cycle_delta),
                "firstArg"      : str(recipe.first_arg),
                "hasMemDataDep" : "true" if recipe.hasMemDataDep else "false",
                "args"          : str(", ".join(args)),
            }
        final_recipes = []
        for tile_id, tile_recipes in enumerate(global_recipes):
            f_recipes = []
            for recipe_id, recipe in enumerate(tile_recipes):
                f_recipes.append(convert_recipe_to_dict(tile_id, recipe_id, recipe))
            final_recipes.append(f_recipes)
        host_init["recipes"] = final_recipes
    def add_task_table(host_init):
        nonlocal G
        nonlocal config
        nonlocal tile_structs
        def get_task_dict(task):
            nonlocal config
            nonlocal G
            nonlocal tile_structs
            singleArgs = []
            for vars in task.register_alloc.regs:
                assert len(vars)
                acc = vars[0][2]
                if acc in [LotusTask.ARG_ACCESS.PARTIAL, LotusTask.ARG_ACCESS.PARTIAL_UNTRACKED]:
                    assert len(vars) == 1
                    v = vars[0][1]
                    tile_struct = tile_structs[dest_tile_conv(task.mappedTo, config)]
                    singleArgs.append(f"&{tile_struct.get_reference(v.get_physical())}")
                else:
                    reg_bytes = [0, 0, 0, 0]
                    for _, var, acc, regByte, startByte, _, numBytes in vars:
                        assert acc == LotusTask.ARG_ACCESS.FULL
                        init_val = var.init_val
                        assert isinstance(init_val, list)
                        assert len(init_val) == var.size
                        for i in range(numBytes):
                            reg_i = regByte+i
                            var_i = startByte+i
                            assert reg_i < len(reg_bytes)
                            assert var_i < len(init_val)
                            reg_bytes[reg_i] = init_val[var_i]
                    singleArgs.append(str(int.from_bytes(reg_bytes, byteorder="little")))

            doubleArgs = [[a for a in singleArgs], [a for a in singleArgs]]
            has_struct_alloc = 0
            if task.struct_alloc:
                has_struct_alloc = 1
                tile_struct = tile_structs[dest_tile_conv(task.mappedTo, config)]
                for cycle_id in [0, 1]:
                    doubleArgs[cycle_id].append(f"&{tile_struct.name}.{task.struct_alloc.instance_name}[{cycle_id}]")

            #TODO(farese) Make configurable
            MAX_ARGS=15

            for _ in range(MAX_ARGS-len(doubleArgs[0])):
                doubleArgs[0].append(str(0xdeadcafe))
                doubleArgs[1].append(str(0xdeadcafe))

            def only_const_struct_access(task):
                if not task.struct_alloc:
                    return True
                for v in task.struct_alloc.vars:
                    isReg = not v.is_mem
                    hasProd = not (v.writer is None)
                    if isReg and hasProd:
                        return False
                return True

            canSkip = (not task.setsHeartbeats) and only_const_struct_access(task)

            return {
                "taskId"              : str(task.task_id),
                "destTile"            : str(dest_tile_conv(task.mappedTo, config)),
                "taskName"            : task.wrapper_fn,
                "label"               : task.label,
                "taskFn"              : None,
                "numInstructions"     : None,
                "taskCacheLines"      : None,
                "numArgs"             : str(len(task.register_alloc.regs) + has_struct_alloc),
                "canSkip"             : canSkip,
                "args"                : doubleArgs,
                "numOutEdges"         : str(len(task.recipes)),
                "numOutArgs"          : str(len(task.output_table.regs)),
                "firstEdgeIdxStart"   : str(task.edgeRecipeStart),
            }
        tasks = [task for task in G.nodes()]
        tasks.sort(key=lambda task: task.mappedTo)
        task_table = []
        for task in tasks:
            task_table.append(get_task_dict(task))
        host_init["tasks"] = task_table
    def add_memory_table(host_init):
        nonlocal tile_structs
        mem_table = []
        def calc_struct_idx(prod_task, prod_cycle_id, cons_struct):
            assert prod_task.mappedTo == cons_struct.task.mappedTo, f"prod: {prod_task.mappedTo} -- cons: {cons_struct.task.mappedTo}"
            cycle_deltas = {v.cycle_delta for v in cons_struct.get_vars_for(prod_task)}
            assert len(cycle_deltas) == 1
            cycle_delta = next(iter(cycle_deltas))
            cycle_id = prod_cycle_id + cycle_delta
            cycle_id_to_idx = {0:0, 1:1, 2:0}
            return cycle_id_to_idx[cycle_id]

        def get_init_length(inits):
            bs = 0
            for i in inits:
                if isinstance(i, str):
                    bs += 4
                else:
                    bs += 1
            return bs

        for tile_struct in tile_structs:
            struct_vars = []
            for i, v in enumerate(tile_struct.vars):
                if isinstance(v, LotusVar):
                    struct_vars.append({"name": f"var_{i}", "class": "LotusVar", "type": v.typee, "size": v.size, "align": v.align, "init":v.init_val})
                elif isinstance(v, TaskStruct):
                    for cycle_id in [0, 1]:
                        init_val = []
                        for l in v.layout:
                            if isinstance(l, TaskStruct):
                                idx = calc_struct_idx(v.task, cycle_id, l)
                                init_val.extend([f"&{tile_struct.name}.{l.instance_name}[{idx}]"])
                            elif isinstance(l, LotusVar):
                                if l.is_mem:
                                    init_val.extend([f"&{tile_struct.get_reference(l)}"])
                                else:
                                    init_val.extend(l.init_val)
                            elif isinstance(l, int):
                                init_val.extend([0 for _ in range(l)])
                        #if v.size != get_init_length(init_val):
                        #    print(f"ABOUT TO ERROR struct_alloc.size = {v.size} -- Init Length: {get_init_length(init_val)} -- Name: {v.instance_name}  -- type: {v.type_name}")
                        #    b = 0;
                        #    for i, l in enumerate(v.layout):
                        #        if isinstance(l, TaskStruct):
                        #            print(f"Element: {i} -- Start Byte: {b} -- TaskStructPointer size = 4 -- ")
                        #            b += 4
                        #        elif isinstance(l, LotusVar):
                        #            if l.is_mem:
                        #                print(f"Element: {i} -- Start Byte: {b} -- LotusVar is_mem size = 4 -- ")
                        #                b += 4
                        #            else:
                        #                print(f"Element: {i} -- Start Byte: {b} -- LotusVar type = {l.typee}, size = {l.size} -- num_init = {len(l.init_val)}")
                        #                b += l.size
                        #        elif isinstance(l, int):
                        #                print(f"Element: {i} -- Start Byte: {b} -- Padding size = {l} -- ")
                        #                b += l
                        assert v.size == get_init_length(init_val), f"struct_alloc.size = {v.size} -- Init Length: {get_init_length(init_val)} -- Name: {v.instance_name}  -- type: {v.type_name}"
                        struct_vars.append({"name": f"{v.instance_name}[{cycle_id}]", "class": "TaskStruct", "type": v.type_name, "size": v.size, "align": v.align, "init":init_val})
            mem_table.append({"name":tile_struct.name, "vars": struct_vars})
        host_init["mem"] = mem_table

    host_init = {}
    add_hw_config(host_init)
    add_recipe_tables(host_init)
    add_task_table(host_init)
    add_memory_table(host_init)
    import json
    output = os.path.join(config["OUT_PATH"], config["BENCH_NAME"]) + ".host_init"
    with open(output, "w") as f:
        json.dump(host_init, f, indent=4)
        print(f"Generated host init dictionary: {output}")


def get_config():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--benchName', default=None, type=str, required=True)
    parser.add_argument('--tasksInclude', default=None, type=str, required=True)
    parser.add_argument('--outPath', default=".", type=str)
    parser.add_argument("--devices", default=1, type=int)
    parser.add_argument("--tilesPerDevice", default=1, type=int)
    parser.add_argument("--coresPerTile", default=1, type=int)
    parser.add_argument("--maxArgsPerTask", default=15, type=int)
    parser.add_argument("--avgArgsPerTask", default=4, type=int)
    parser.add_argument("--recipesPerTask", default=24, type=int)
    parser.add_argument("--outRegsBits", default=6, type=int)
    parser.add_argument("--tasksPerTile", default=2048, type=int)
    parser.add_argument("--unrollFactor", default=1, type=int)
    parser.add_argument("--backend", default="lotus", type=str)
    parser.add_argument("--defines", default="", type=str)
    parser.add_argument("--enableCoarsening", default=False, action="store_true")
    parser.add_argument("--application", default=None, type=str)
    args = parser.parse_args()

    config = {
        "BENCH_NAME": args.benchName,
        "OUT_PATH": args.outPath,
        "TASKS_INCLUDE": args.tasksInclude,
        "MAX_ARGS_PER_TASK": args.maxArgsPerTask,
        "AVG_ARGS_PER_TASK": args.avgArgsPerTask,
        "RECIPES_PER_TASK": args.recipesPerTask,
        "OUT_REGS_BITS": args.outRegsBits,
        "DEVICES": args.devices,
        "TILES_PER_DEVICE": args.tilesPerDevice,
        "CORES_PER_TILE": args.coresPerTile,
        "TASKS_PER_TILE": args.tasksPerTile,
        "BACKEND" : args.backend,
        "DEFINES": args.defines,
        "UNROLL_FACTOR": args.unrollFactor,
        "ENABLE_COARSENING": "TRUE" if args.enableCoarsening else "FALSE",
        "APPLICATION": args.application,
        "GENERATED_FILES_TO_INCLUDE": [],
        "HAS_COARSE_HINTS": False,
        "HAS_PART_HINTS": False,
        "GEN_DOT": False,
    }
    config["OUT_REGS_PER_TASK"] = (1 << config["OUT_REGS_BITS"]) - 1
    return config

@timed
def generate_dot_graph(name, G, config):
    if False:
        return
    graph = nx.MultiDiGraph()
    for t in G.nodes():
        if t.label is not None:
            label = t.label
        else:
            label = t.fn
            if t.unroll_version is not None:
                label = f"{label}@{t.unroll_version}"

        if t.task_id is not None:
            label = f"{label}+(tid={t.task_id})"
        graph.add_node(t.idx, label=label)

    for e in G.edges():
        graph.add_edge(e.producer.idx, e.consumer.idx, label=f"({e.typee},{str(e.cycle_delta)})")

    dotfile = os.path.join(config["OUT_PATH"], f"{name}.dot")
    pdffile = os.path.join(config["OUT_PATH"], f"{name}.pdf")
    nx.drawing.nx_pydot.write_dot(graph, dotfile)
    subprocess.run(["dot", "-Tpdf", dotfile, "-o", pdffile], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    print(f"Generated: {pdffile}")

@timed
def lotus_backend(G, config):

    register_alloc(G, config)

    #TODO: DTTs would go here

    output_table(G, config)


    # Spawners/Reducers

    recipe_generation(G, config)


    tile_structs = get_tile_structs(G, config)

    if True:
        for task in G.nodes():
            deviceId, _ = task.mappedTo
            if deviceId == 0:
                task.setsHeartbeats = True
                break

    LotusTask.assign_group_ids(G)

    make_task_structs_concrete(G, config)

    # Final generation
    gen_cpp_main(G, tile_structs, config)
    assign_task_ids(G, config)
    gen_host_init(G, tile_structs, config)

    if config["GEN_DOT"]:
        generate_dot_graph("final_task_graph", G, config)

@timed
def cpu_assign_task_ids(G):

    def create_rank_graph(G):
        def edge_has_mem(e):
            for v in e.vars:
                if v.is_mem:
                    return True
            return False
        G_rank = nx.DiGraph()
        for n in G.nodes():
            G_rank.add_node(n.idx, data=n)

        #NOTE(farese): Since the compiler is currently simple
        # The easiest way to handle simulation is to double buffer everything.
        # Why? Think A -cc-> B and B -cc-> A, this can't be implemented without some tricks
        # Instead, we cater for cross-cycle edges, supporting a different buffer for inputs vs outputs.
        # This leads to two cases that need handling
        # 1. PARTIAL, because tasks don't write the full values,
        #    we either memcpy or actually keep a single location.
        #    + Same thread and ordering
        #    + Single memory location for IN and OUT
        # 2. Consumers consume before the switch between IN and OUT happens (sc)
        #    + Same thread and ordering
        #    + Read/Write from OUT
        # 3. For INOUT vars:
        #    Writer task: reads IN, writes OUT
        #    Reader task: follows same rules as above
        # This comment related to this function + cpp_gen_cpp_main
        for e in G.edges():
            if e.producer == e.consumer:
                continue
            if edge_has_mem(e):
                # Handles Case (1)
                if e.cycle_delta == 0:
                    G_rank.add_edge(e.producer.idx, e.consumer.idx)
                else:
                    G_rank.add_edge(e.consumer.idx, e.producer.idx)
            elif e.cycle_delta == 0:
                # Handles Case (2)
                G_rank.add_edge(e.producer.idx, e.consumer.idx)

        return G_rank

    G_rank = create_rank_graph(G)
    if not nx.is_directed_acyclic_graph(G_rank):
        try:
            cycle = next(nx.simple_cycles(G_rank))
        except StopIteration:
            cycle = None
        raise ValueError(f"Rank graph is not a DAG. Example cycle: {cycle}")

    global_task_id = 0
    for layer in nx.topological_generations(G_rank):
        tasks = [G_rank.nodes[n]['data'] for n in layer]
        tasks.sort(key=lambda t: t.idx)
        for t in tasks:
            assert t.task_id is None
            t.task_id = global_task_id
            global_task_id += 1


def write_makefile(cpp_files, makefile_path, include_path, binary_name, defines):
    srcs = " ".join(sorted(set(cpp_files)))

    makefile_content = f"""# Auto-generated Makefile
CXX       = g++
CXXFLAGS ?= -std=gnu++20 -O2 -pthread
CPPFLAGS ?=
LDFLAGS  ?=
LDLIBS   ?=

CPPFLAGS += -I{include_path} {defines}

TARGET ?= {binary_name}

SRCS := {srcs}
OBJS := $(SRCS:.cpp=.o)
DEPS := $(OBJS:.o=.d)

all: $(TARGET)

$(TARGET): $(OBJS)
\t$(CXX) $(LDFLAGS) $(OBJS) -o $@ $(LDLIBS)

%.o: %.cpp
\t@mkdir -p $(dir $@)
\t$(CXX) $(CXXFLAGS) $(CPPFLAGS) -MMD -MP -c $< -o $@

-include $(DEPS)

clean:
\trm -f $(TARGET) $(DEPS) $(OBJS)

.PHONY: all clean
"""

    with open(makefile_path, "w") as f:
        f.write(makefile_content)

@timed
def cpu_gen_cpp_main(G, config):

    get_filename = lambda n: os.path.join(config["OUT_PATH"], n)

    def gen_struct(gen, type_name, task_to_threadId):
        nonlocal G
        vars = get_vars_from_graph(G)

        def get_var_sort_tuple(v):
            threadId = None
            if v.writer:
                threadId = task_to_threadId[v.writer]
            else:
                assert len(v.readers)
                threadId = task_to_threadId[v.readers[0]]
            assert threadId is not None

            return (threadId, v.idx)


        type_to_vars = defaultdict(list)
        for v in vars:
            type_to_vars[(v.typee, v.is_mem)].append(v)

        for vars in type_to_vars.values():
            vars.sort(key=get_var_sort_tuple)

        type_to_id = {}
        # 1. Produce struct
        gen.add(CppFileGenerator.Line(f"struct {type_name}" + "{"))
        type_id = 0
        for (type, is_mem), vars in type_to_vars.items():
            type_to_id[(type, is_mem)] = type_id
            if not is_mem:
                gen.add(CppFileGenerator.Line(f"    std::array<{type}, {len(vars)}> type_{type_id};"))
            else:
                gen.add(CppFileGenerator.Line(f"    std::array<{type}*, {len(vars)}> type_{type_id};"))
            type_id += 1
        gen.add(CppFileGenerator.Line("};"))
        gen.add(CppFileGenerator.Line(""))

        # 2. Get references

        var_to_ref = {}
        for (type, is_mem), vars in type_to_vars.items():
            type_id = type_to_id[(type, is_mem)]
            for i, v in enumerate(vars):
                ref = f"type_{type_id}[{i}]"
                var_to_ref[v] = ref

        return var_to_ref

    def gen_init(gen, init_name, include_filename, type_name, instance_name, var_to_ref):
        nonlocal G

        def format_cpp_initializer(lst, per_line=40, indent="        "):
            if not lst:
                return "{ }"

            lines = ["{"]  # opening brace
            for i in range(0, len(lst), per_line):
                chunk = lst[i:i + per_line]
                line = ", ".join(map(str, chunk)) + ","  # always add trailing comma
                lines.append(f"{indent}{line}")
            lines.append(indent + "}")  # closing brace
            return "\n".join(lines)

        def gen_init_parts():
            nonlocal init_name
            vars = get_vars_from_graph(G)
            initScopes = []
            for v in vars:
                initScope = CppFileGenerator.Scope()
                initScopes.append(initScope)

                if not v.is_mem:
                    initScope.add(CppFileGenerator.Line(f"std::array<uint8_t, {len(v.init_val)}> init_bytes{format_cpp_initializer(v.init_val)};"))

                    initScope.add(CppFileGenerator.Line(f'static_assert(sizeof({v.typee}) == {len(v.init_val)}, "Must match sizes");'))
                    #initScope.add(CppFileGenerator.Line(f'static_assert(std::is_trivially_copyable_v<{v.typee}>, "Must be trivially copyable");'))
                    #initScope.add(CppFileGenerator.Line(f'static_assert(std::is_standard_layout_v<{v.typee}>, "Must be trivially copyable");'))

                    initScope.add(CppFileGenerator.Line(f"std::memcpy(&({instance_name}.{var_to_ref[v]}), init_bytes.data(), sizeof({v.typee})); "))
                else:
                    initScope.add(CppFileGenerator.Line(f"std::array<uint8_t, {len(v.init_val)}> init_bytes{format_cpp_initializer(v.init_val)};"))
                    initScope.add(CppFileGenerator.Line(f"static {v.typee} partial_obj;"))

                    initScope.add(CppFileGenerator.Line(f'static_assert(sizeof({v.typee}) == {len(v.init_val)}, "Must match sizes");'))
                    #initScope.add(CppFileGenerator.Line(f'static_assert(std::is_trivially_copyable_v<{v.typee}>, "Must be trivially copyable");'))
                    #initScope.add(CppFileGenerator.Line(f'static_assert(std::is_standard_layout_v<{v.typee}>, "Must be trivially copyable");'))

                    initScope.add(CppFileGenerator.Line(f"std::memcpy(&partial_obj, init_bytes.data(), sizeof({v.typee})); "))


                    initScope.add(CppFileGenerator.Line(f"{instance_name}.{var_to_ref[v]} =  &partial_obj; "))

            initsPerFile = 250
            initScopesParts = [initScopes[i:i + initsPerFile] for i in range(0, len(initScopes), initsPerFile)]

            functionsInfo = []
            for i, initScopes in enumerate(initScopesParts):
                funcName = f"{init_name}_{i}"

                cppName  = get_filename(f"{funcName}.cpp")
                cppGen = CppFileGenerator(cppName)
                cppGen.add(CppFileGenerator.Line(f'#include "{include_filename}"'))

                funcArgs = [(f"{type_name}&", instance_name)]

                # This is for the implementation inside of this cpp file
                cppGen.add(CppFileGenerator.FunctionSignature("void", funcName, funcArgs, False))
                funcScope = CppFileGenerator.Scope()
                cppGen.add(funcScope)
                if True:
                    for initScp in initScopes:
                        funcScope.add(initScp)

                # This is for the forward declaration in the main cpp file
                funcCall = CppFileGenerator.FunctionCall(funcName, [instance_name])
                funcDecl = CppFileGenerator.FunctionSignature("void", funcName, funcArgs, True)

                functionsInfo.append((funcDecl, funcCall, cppName))
                cppGen.flush()
            return functionsInfo

        funcsInfo = gen_init_parts()
        for funcDecl, _, _ in funcsInfo:
            gen.add(funcDecl)
        gen.add(CppFileGenerator.FunctionSignature("void", init_name, [(f"{type_name}&", instance_name)], False))
        funcScope = CppFileGenerator.Scope()
        gen.add(funcScope)

        for _, funcCall, _ in funcsInfo:
            funcScope.add(funcCall)

        fileNames = [fn for _, _, fn in funcsInfo]
        return fileNames

    def gen_cycle(tasks_per_thread, gen, cycle_name, include_filename, type_name, var_to_ref):
        nonlocal G

        input_name = "input_vars"
        output_name = "output_vars"

        fileNames = []
        cycleNames = []
        for threadId, tasks in enumerate(tasks_per_thread):
            def get_args(t, callScope):
                args = []
                putAfterCall = []
                inout_temp_id = 0
                for direction, _, v in t.args:
                    ref      = var_to_ref[v]
                    if v.is_mem:
                        # Single memory location, doesn't matter
                        args.append(f"*{output_name}.{ref}")
                    elif direction in [LotusTask.ARG_DIR.IN, LotusTask.ARG_DIR.OUT]:
                        use_name = None
                        if v.is_same_cycle(G):
                            use_name = output_name
                        else:
                            use_name = input_name if direction == LotusTask.ARG_DIR.IN else output_name
                        args.append(f"{use_name}.{ref}")
                    else:
                        assert direction == LotusTask.ARG_DIR.INOUT
                        assert not v.is_same_cycle(G)
                        temp_name = f"inout_var_{inout_temp_id}"
                        inout_temp_id += 1

                        # 1. Define temp var, and let it take the inputs of the "in"
                        callScope.add(CppFileGenerator.Line(f"{v.typee} {temp_name} = {input_name}.{ref}; "))

                        # 2. Call function with temp variable
                        args.append(f"{temp_name}")

                        # 3. Put result in "out"
                        putAfterCall.append(CppFileGenerator.Line(f"{output_name}.{ref} = {temp_name};"))

                return args, putAfterCall
            funcCalls = []
            for t in tasks:
                callScope = CppFileGenerator.Scope()
                args, afterCall = get_args(t, callScope)
                callScope.add(CppFileGenerator.FunctionCall(t.fn, args))
                for a in afterCall:
                    callScope.add(a)
                funcCalls.append(callScope)
            #funcCalls = [CppFileGenerator.FunctionCall(t.fn, get_args(t)) for t in tasks]

            thread_cycle_name = f"{cycle_name}_thread_{threadId}"

            callsPerFile = 250
            callsParts = [funcCalls[i:i + callsPerFile] for i in range(0, len(funcCalls), callsPerFile)]

            funcsInfo = []
            for i, calls in enumerate(callsParts):
                funcName = f"{thread_cycle_name}_{i}"

                cppName  = get_filename(f"{funcName}.cpp")
                cppGen = CppFileGenerator(cppName)
                cppGen.add(CppFileGenerator.Line(f'#include "{include_filename}"'))

                funcArgs = [(f"const {type_name}&", input_name), (f"{type_name}&", output_name)]

                # This is for the implementation inside of this cpp file
                cppGen.add(CppFileGenerator.FunctionSignature("void", funcName, funcArgs, False))
                funcScope = CppFileGenerator.Scope()
                cppGen.add(funcScope)
                if True:
                    for call in calls:
                        funcScope.add(call)

                # This is for the forward declaration in the main cpp file
                funcCall = CppFileGenerator.FunctionCall(funcName, [input_name, output_name])
                funcDecl = CppFileGenerator.FunctionSignature("void", funcName, funcArgs, True)

                funcsInfo.append((funcDecl, funcCall, cppName))
                cppGen.flush()


            for funcDecl, _, _ in funcsInfo:
                gen.add(funcDecl)

            gen.add(CppFileGenerator.FunctionSignature("void", thread_cycle_name, [(f"const {type_name}&", input_name), (f"{type_name}&", output_name)], False))
            funcScope = CppFileGenerator.Scope()

            gen.add(funcScope)

            for _, funcCall, _ in funcsInfo:
                funcScope.add(funcCall)

            fileNames.extend([fn for _, _, fn in funcsInfo])
            cycleNames.append(thread_cycle_name)

        runSimulation = r"""
#include <barrier>
#include <cstddef>     // std::ptrdiff_t
#include <functional>
#include <thread>
#include <vector>

typedef struct {
   volatile int value;
   long _padding[15]; // to prevent false sharing
} tree_barrier_t;

tree_barrier_t* barrier_init(unsigned count) {
   //assert(0 < count && count <= MAX_NUM_CPUS);

   // add one to avoid false sharing
   tree_barrier_t* ptr = ((tree_barrier_t*) malloc((count + 1) * sizeof(tree_barrier_t))) + 1;
   for (unsigned i = 0; i < count; ++i) {
       ptr[i].value = 0;
   }
   return ptr;
}

void barrier_wait(tree_barrier_t* barrier_ptr, const unsigned num_threads, const unsigned self) {
    int const goal = 1 - barrier_ptr[self].value;

    int round_mask = 3;
    while ((self & round_mask) == 0 && round_mask < (num_threads << 2)) {
      int const spacing = (round_mask + 1) >> 2;
      for (int i = 1; i <= 3 && self + i*spacing < num_threads; ++i) {
        while (barrier_ptr[self + i*spacing].value != goal) {
          // spin
          __builtin_ia32_pause();
        }
      }
      round_mask = (round_mask << 2) + 3;
    }

    barrier_ptr[self].value = goal;
    while (barrier_ptr[0].value != goal) {
      // spin
      __builtin_ia32_pause();
    }
}

template <class Completion>
static inline void barrier_wait_with_completion(tree_barrier_t* barrier_ptr,
                                                const unsigned num_threads,
                                                const unsigned self,
                                                Completion&& completion)
{
    int const goal = 1 - barrier_ptr[self].value;

    int round_mask = 3;
    while ((self & round_mask) == 0 && round_mask < (int(num_threads) << 2)) {
      int const spacing = (round_mask + 1) >> 2;
      for (int i = 1; i <= 3 && self + i*spacing < (int)num_threads; ++i) {
        while (barrier_ptr[self + i*spacing].value != goal) {
          __builtin_ia32_pause();
        }
      }
      round_mask = (round_mask << 2) + 3;
    }

    if (self == 0) {
        // Root: all arrivals observed -> run completion -> release everyone
        completion();                 // callback
        barrier_ptr[0].value = goal;  // release
    } else {
        // Non-root: publish arrival then wait for root to release
        barrier_ptr[self].value = goal;
        while (barrier_ptr[0].value != goal) {
          __builtin_ia32_pause();
        }
    }
}


using WorkFn = std::function<void(const TYPE_NAME&, TYPE_NAME&)>;

void run_simulation(TYPE_NAME* vars0,
                    TYPE_NAME* vars1,
                    const std::vector<WorkFn>& workers,
                    uint32_t num_cycles)
{
    if (workers.empty() || num_cycles == 0) return;

    // Double buffers as pointers
    std::array<TYPE_NAME*, 2> buf{vars0, vars1};

    size_t cur = 0;
    auto end_cycle = [&]() {
        // NOTE(farese): No longer needed because of note in cpu_assign_task_ids
        // std::memcpy(buf[cur], buf[cur ^ 1], sizeof(TYPE_NAME));
        cur ^= 1;
    };

    if (workers.size() == 1) {
        for (uint32_t cycleId = 0; cycleId < num_cycles; ++cycleId) {
            // printf("================ cycleId=%u\n", cycleId);
            workers[0](*buf[cur], *buf[cur ^ 1]);
            end_cycle();
        }
        return;
    }

    // Multi-threaded
    const unsigned num_threads = static_cast<unsigned>(workers.size());
    tree_barrier_t* barrier = barrier_init(num_threads);

    std::vector<std::thread> threads;
    threads.reserve(workers.size());

    for (size_t tid = 0; tid < workers.size(); ++tid) {
        threads.emplace_back([&, tid] {
            for (uint32_t cycleId = 0; cycleId < num_cycles; ++cycleId) {
                // Read-only input, write-only output
                const TYPE_NAME& in  = *buf[cur];
                TYPE_NAME&       out = *buf[cur ^ 1];
                workers[tid](in, out);

                barrier_wait_with_completion(barrier, num_threads,
                                             static_cast<unsigned>(tid),
                                             [&]{
                                                 if (tid == 0) end_cycle();
                                             });
            }
        });
    }

    for (auto& t : threads) t.join();
}
        """
        runSimulation = runSimulation.replace("TYPE_NAME", type_name)

        gen.add(CppFileGenerator.Line(runSimulation))

        return (cycleNames, fileNames)

    def gen_main(gen, type_name, instance_name, init_name, cycleNames):
        gen.add(CppFileGenerator.Line(''))
        gen.add(CppFileGenerator.FunctionSignature("int", "main", [], False))
        mainScope = CppFileGenerator.Scope()
        gen.add(mainScope)

        mainScope.add(CppFileGenerator.Line(f"static {type_name} {instance_name}0;"))
        mainScope.add(CppFileGenerator.Line(f"static {type_name} {instance_name}1;"))
        mainScope.add(CppFileGenerator.FunctionCall(init_name, [f"{instance_name}0"]))
        mainScope.add(CppFileGenerator.FunctionCall(init_name, [f"{instance_name}1"]))

        N_CYCLES = 100000
        unroll = config['UNROLL_FACTOR']
        assert unroll >= 1, f"Unroll must be >= 1: {unroll}"
        N_CYCLES = N_CYCLES // unroll
        #N_CYCLES = 50
        cycleNames = ", ".join(cycleNames)
        mainScope.add(CppFileGenerator.Line(f"std::vector<WorkFn> workers = {{ {cycleNames} }};"))
        mainScope.add(CppFileGenerator.FunctionCall("run_simulation", [f"&{instance_name}0", f"&{instance_name}1", "workers", str(N_CYCLES)]))
        #mainScope.add(CppFileGenerator.Line(f"for (uint32_t cycleId = 0; cycleId < {N_CYCLES}; cycleId++)"))
        #loopScope = CppFileGenerator.Scope()
        #mainScope.add(loopScope)

        #loopScope.add(CppFileGenerator.Line("(void)cycleId;"))
        #loopScope.add(CppFileGenerator.FunctionCall(cycle_name, [instance_name]))


    def get_tasks_per_thread():
        numPartitions = config["CORES_PER_TILE"]
        tasks_per_thread = [[] for _ in range(numPartitions)]
        for task in G.nodes():
            tasks_per_thread[task.mappedTo[0]].append(task)

        for tasks in tasks_per_thread:
            tasks.sort(key=lambda t: t.task_id)

        return tasks_per_thread


    tasks_per_thread = get_tasks_per_thread()
    task_to_threadId = {}
    if True:
        for threadId, tasks in enumerate(tasks_per_thread):
            for t in tasks:
                task_to_threadId[t] = threadId


    main_cpp_filename = get_filename(f'{config["BENCH_NAME"]}.cpp')
    mainGen = CppFileGenerator(main_cpp_filename)

    include_filename = f'{config["BENCH_NAME"]}.h'
    include_path     = get_filename(include_filename)
    includeGen = CppFileGenerator(include_path)

    includeGen.add(CppFileGenerator.Line("#include <cstdint>"))
    includeGen.add(CppFileGenerator.Line("#include <array>"))
    includeGen.add(CppFileGenerator.Line("#include <tuple>"))
    includeGen.add(CppFileGenerator.Line("#include <utility>"))
    includeGen.add(CppFileGenerator.Line("#include <cstring>"))
    includeGen.add(CppFileGenerator.Line("#include <barrier>"))
    includeGen.add(CppFileGenerator.Line("#include <thread>"))
    includeGen.add(CppFileGenerator.Line("#include <vector>"))
    includeGen.add(CppFileGenerator.Line("#include <functional>"))

    includeGen.add(CppFileGenerator.Line(f'#include "{config["TASKS_INCLUDE"]}"'))
    for ih in config["GENERATED_FILES_TO_INCLUDE"]:
        includeGen.add(CppFileGenerator.Line(f'#include "{ih}"'))
    includeGen.add(CppFileGenerator.Line("\n\n"))

    mainGen.add(CppFileGenerator.Line(f'#include "{include_filename}"'))

    type_name = "VarsStruct_t"
    instance_name = "varsStruct"
    init_name = "initialize_vars_struct"
    cycle_name = "sim_cycle"

    var_to_ref = gen_struct(includeGen, type_name, task_to_threadId)
    includeGen.flush()

    initFiles = gen_init(mainGen, init_name, include_filename, type_name, instance_name, var_to_ref)
    cycleNames, cycleFiles = gen_cycle(tasks_per_thread, mainGen, cycle_name, include_filename, type_name, var_to_ref)
    gen_main(mainGen, type_name, instance_name, init_name, cycleNames)
    mainGen.flush()

    allCppFiles = [main_cpp_filename] + initFiles + cycleFiles
    makefile_path = get_filename(f'Makefile')
    write_makefile(allCppFiles, makefile_path, config["OUT_PATH"], get_filename("cpu.elf"), config["DEFINES"])

@timed
def cpu_backend(G, config):
    cpu_assign_task_ids(G)
    cpu_gen_cpp_main(G, config)

def apply_order_edges(G, config):
    if config["BACKEND"] == "lotus":
        add_order_edges(G)
        if config["GEN_DOT"]:
            generate_dot_graph("ordered_task_graph", G, config)
        remove_transitive_edges(G)

        ensure_no_cycles(G, config)
        #check_edges(G, config)
    elif config["BACKEND"] == "cpu":
        #
        pass
        #add_order_edges(G)
    else:
        assert False, "Unknown backend"

#timed
def main():
    timer = Timer()




    config = get_config()
    raw = ParseStdIn.get_tasks_and_vars(config)

    G = get_graph(raw)
    print(f"Number of tasks in the original dataflow graph: {len(G.nodes())}")
    if config["GEN_DOT"]:
        generate_dot_graph("og_task_graph", G, config)

    if config["ENABLE_COARSENING"] == "TRUE":
        raw = temporal_unrolling(G, raw, config)

    if config["ENABLE_COARSENING"] != "DONE":
        raw = unroll_raw(raw, config)

    for v in raw["vars"]:
        if v.is_unroll_var:
            uf = config["UNROLL_FACTOR"]
            v.init_val = list(uf.to_bytes(4, byteorder="little", signed=False))

    G = get_graph(raw)

    print(f"Number of tasks after unrolling: {len(G.nodes())} -- as a ratio with unroll factor ({config['UNROLL_FACTOR']}): {len(G.nodes()) / config['UNROLL_FACTOR']}")

    if config["GEN_DOT"]:
        generate_dot_graph("unrolled_task_graph", G, config)
    if config["ENABLE_COARSENING"] == "TRUE":
        coarsened_raw = coarsen_graph(G, config)
        G = get_graph(coarsened_raw)
        if config["GEN_DOT"]:
            generate_dot_graph("coarsened_task_graph", G, config)
    elif config["ENABLE_COARSENING"] == "FALSE":
        # still need to generate file because scons sucks
        name = "coarsenedTasks.h"
        header_filename = os.path.join(config["OUT_PATH"], name)
        config["GENERATED_FILES_TO_INCLUDE"].append(name)
        gen = CppFileGenerator(header_filename)
        gen.add(CppFileGenerator.Line(''))
        gen.add(CppFileGenerator.Line('// This file contains generated coarsend tasks, but is empty because coarsening disabled\n'))
        gen.flush()
    else:
        assert config["ENABLE_COARSENING"] == "DONE"

    if next(iter(G.nodes())).mappedTo == None:
        if config["BACKEND"] == "lotus":
            map_tasks(G, config)
        elif config["BACKEND"] == "cpu":
            map_tasks_cpu(G, config)
        else:
            assert False, "Unknown backend"


    apply_order_edges(G, config)

    if config["BACKEND"] == "lotus":
        lotus_backend(G, config)
    elif config["BACKEND"] == "cpu":
        cpu_backend(G, config)
    else:
        assert False, f"Unkown backend: {config['BACKEND']}"


if __name__ == "__main__":
    main()
