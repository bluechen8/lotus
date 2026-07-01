
li t0, 0xfffffffa
li t1, 0x00000000
lw t2, 0(t0)
lw t2, 0(t1)
.insn r 0x0B, 0, 0, x0, x0, x0
lw t2, 0(t0)
lw t2, 0(t1)
nop
nop
nop
nop
nop
nop
nop
nop
nop
unimp
