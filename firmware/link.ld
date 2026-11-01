/*
 * Link.ld - CH32V305 链接脚本
 * 适用于 CH32V305RBT6 (192KB Flash, 32KB SRAM)
 */

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 192K
    RAM   (xrw) : ORIGIN = 0x20000000, LENGTH = 32K
}

SECTIONS
{
    .text :
    {
        . = ALIGN(4);
        KEEP(*(.init))
        KEEP(*(.vector))
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata.*)
        . = ALIGN(4);
        _etext = .;
    } > FLASH

    .data :
    {
        . = ALIGN(4);
        _sidata = LOADADDR(.data);
        _sdata = .;
        *(.data)
        *(.data.*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > FLASH

    .bss :
    {
        . = ALIGN(4);
        _sbss = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    _end = .;

    .stack (NOLOAD) :
    {
        . = ALIGN(4);
        . = . + 0x800;
        _estack = .;
    } > RAM

    /DISCARD/ :
    {
        *(.eh_frame)
        *(.comment)
    }
}

PROVIDE(_stack = ORIGIN(RAM) + LENGTH(RAM));
PROVIDE(_heap_start = _ebss);
PROVIDE(_heap_end = ORIGIN(RAM) + LENGTH(RAM) - 0x800);
PROVIDE(__global_pointer$ = _ebss + 0x800);
PROVIDE(__bss_start = _sbss);
PROVIDE(_end = .);
PROVIDE(_eusrstack = _estack);
PROVIDE(_data_lma = _sidata);
PROVIDE(_data_vma = _sdata);