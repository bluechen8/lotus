# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import os, sys

regDefs = []
body = []

def parse(n):
    res = {}
    for i in range(n):
        l = sys.stdin.readline().strip()
        (key, val) = l.split(": ")
        res[key] = val
    return res

while True:
    l = sys.stdin.readline()
    if l == "":
        break
    type = l.strip()
    if type == "Edge":
        e = parse(4)
        edgeDef = f'{e["type"]} edge_{e["edgeIdx"]} = {e["initValue"]};'
        if e["cycleDelta"] == "0":
            body.append(edgeDef)
        elif e["cycleDelta"] == "1":
            regDefs.append(edgeDef)
    elif type == "Task":
        t = parse(5)
        taskCall = f'std::tuple<{",".join(t["outTypes"].split(";"))}> taskOuts_{t["taskIdx"]} = {t["fn"]}({",".join(["cycleId"] + ["edge_" + edgeIdx for edgeIdx in t["inEdges"].split("; ")])});'
        body.append(taskCall)
    elif type == "Write":
        w = parse(3)
        writeStmt = f'edge_{w["edgeIdx"]} = std::get<{w["writerOutIdx"]}>(taskOuts_{w["writerTaskIdx"]});'
        body.append(writeStmt)
    else:
        print("ERROR, unknown type!!")
        sys.exit(-1)

print("\n".join(regDefs))
print("\nvoid simCycle(uint8_t cycleId) {")
print("    " + "\n    ".join(body))
print("}")

# Emit main (I'm guessing full compiler would have this in a separate file)
print('''
int main() {
    for (uint32_t cycle = 0; cycle < 1000*1000; cycle++) {
        simCycle((uint8_t) cycle);
    }
}''')
