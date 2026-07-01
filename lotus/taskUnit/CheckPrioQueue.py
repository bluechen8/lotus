# $lic$
# Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
#
# This file is part of Lotus. Lotus is free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, version 2.

import sys, re
from sortedcontainers import SortedDict

def parseHex(hexStr):
    return int(hexStr[2:], 16)

def parseElem(elem):
    return parseHex("'h" + elem)

pq = SortedDict()
for line in sys.stdin:
    if line[0] != "[":
        continue
    print(line.strip())
    if "min:" in line:
        minVal = parseHex(line.split(": ")[1].split("|")[0].strip())
        refMin = pq.peekitem(index=0)
        # We must tolerate some slop on repeats: they don't happen in the
        # implementation, but do in testing due to using random values...
        # We count the number of inserts of the same value, tolerate up to that
        # many pops, and if the value was already popped and there's a
        # mismatch on min, we discard it
        while refMin[0] != minVal and refMin[1][0]: # i.e., and "wasPopped"
            #(wasPopped, count) = refMin[1]
            pq.popitem(index=0)
            refMin = pq.peekitem(index=0)
        #print(minVal)
        #print(refMin)
        if minVal != refMin[0]:
            print("ERROR: Mismatched min %s != %s" % (hex(minVal), hex(refMin[0])))
            sys.exit(-1)

    if "popMin" in line:
        refMin = pq.popitem(index=0)
        (wasPopped, count) = refMin[1]
        if count > 1:
            pq[refMin[0]] = (True, count - 1)

    if "pushing:" in line:
        pushVal = parseHex(line.split(": ")[1].strip())
        if pushVal not in pq:
            pq[pushVal] = (False, 1)
        else:
            (wasPopped, prevCount) = pq[pushVal]
            pq[pushVal] = (False, prevCount + 1)

    #elems = line.split("'h")
    #pop = elems[2].strip()
    #push = elems[1].split()[0].strip()
    #isMin = "PULL_MIN" in line
    #print isMin, push, pop
    #pop = parseElem(pop)
    #push = parseElem(push)
    #print("isMin:", isMin)
    #print("Pop:", hex(pop))
    #print("Push:", hex(push))
    #print(pq)

    #if pop != invalid:
    #    assert(len(pq) != 0)
    #    if isMin:
    #        popped = pq.popitem(index=0)
    #    else:
    #        popped = pq.popitem(index=-1)
    #    if popped[0] != pop:
    #        print("ERROR: Mismatched popped %s != %s" %(hex(popped[0]), hex(pop)))
    #        print(pq)
    #        sys.exit(-1)
    #if push != invalid:
    #    pq[push] = push
    #print("Size: ", len(pq))
print("PASSED")
