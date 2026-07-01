# Tile pairs listed sequentially, by reloc'd DCP. DCP format is X_Y; X is the pblock
# and Y is the Yoffset (in units of 60 CLBs, i.e., one clock region). For
# example, 1_0 is the non-reloc'd pblock1 (top of the device), and 1_2 is pblock 1
# relocated 2 clock regions down.
def getTileMap():
    return [f"pair0_{y}" for y in range(4)] + [f"pair0_{y}" for y in range(6, 10)] + ["pair0_10", "pair1_10"] +           [f"pair1_{y}" for y in range(10)] +           [f"pair2_{y}" for y in range(11)] +           [f"pair3_{y}" for y in [8, 0, 4]]#
def getHbmPorts(tilesPerMemChannel):
    if tilesPerMemChannel == 4:
        # Place ports vertically w.r.t.
        return [0, 2, 4, 5, 7, 8, 10, 11, 13, 14,
                16, 18, 20, 22, 24, 26, 28, 30]
    else:
        # This is 64 tiles or less, unlikely to be congested
        return []

def getPreMuxPipeLength(tileId, tilesPerMux):
    if tilesPerMux == 4 and tileId in [64, 65]:
        return 2
    else:
        return 0

def getMuxToSwitchPipeLengths(tilesPerMux):
    # Assuming 4:1 muxing
    s = [0] * 17
    # Laid out spatially: by column spaces between SLRs
    # SRL2
    s[0] = 4;  s[5] = 4;  s[10] = 5;
    s[1] = 3;  s[6] = 3;  s[11] = 5;
    # SRL1
    pass;      s[7] = 1;  s[12] = 3;  s[16] = 4;
    s[2] = 1;  s[8] = 2;  s[13] = 3;
    # SRL0
    s[3] = 3;  s[9] = 4;      s[14] = 5;
    s[4] = 4;  pass;      s[15] = 6;

    # Adapt to other muxing ratios by repeating the 4:1 latencies
    numMuxes = 68 // tilesPerMux
    assert 68 % tilesPerMux == 0
    return [s[m * 17 // numMuxes] for m in range(numMuxes)]

def getMuxToMemPipeLengths(tilesPerMux):
    # Assuming 4:1 muxing
    s = [0] * 17
    # Laid out spatially: by column spaces between SLRs
    # SRL2
    s[0] = 6;  s[5] = 6;  s[10] = 6;
    s[1] = 5;  s[6] = 5;  s[11] = 5;
    # SRL1
    pass;      s[7] = 4;  s[12] = 4;  s[16] = 4;
    s[2] = 3;  s[8] = 3;  s[13] = 3;
    # SRL0
    s[3] = 2;  s[9] = 2;      s[14] = 2;
    s[4] = 1;  pass;      s[15] = 1;

    # Adapt to other muxing ratios by repeating the 4:1 latencies
    numMuxes = 68 // tilesPerMux
    assert 68 % tilesPerMux == 0
    return [s[m * 17 // numMuxes] for m in range(numMuxes)]
