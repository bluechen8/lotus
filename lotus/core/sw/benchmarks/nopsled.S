// This tests performance on a very long, serial stream of code
.text
start:
.rept 2048
nop
.endr
// PASS exit sequence
li a0, 0x40001000
li x28, 0
sw x28, 0(a0)
// This should not be reached
unimp
