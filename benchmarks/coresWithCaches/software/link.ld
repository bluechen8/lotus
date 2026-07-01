ENTRY(core_entry)

SECTIONS
{
  . = 0x00000000;

  .text : {
    *(.text.core_entry)
    *(.text*)
  }

  .rodata : {
    *(.rodata*)
  }

  .data : {
    *(.data*)
  }

  .bss : {
    *(.bss*)
    *(COMMON)
  }
}
