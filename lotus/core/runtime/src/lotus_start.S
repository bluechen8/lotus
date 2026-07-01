# This file defines the bare minimum needed for Lotus binaries to compile. Note this code is not actually run in Lotus.
.section .init, "ax"
.global _start
.type   _start, @function
_start:
  call    main
  tail    exit
  unimp
.size  _start, .-_start
