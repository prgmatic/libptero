OUTPUT_FORMAT ("elf32-bigmips", "elf32-bigmips", "elf32-littlemips")
OUTPUT_ARCH (mips)

MEMORY
{
    RAM  : ORIGIN =  0x80000000, LENGTH = 65536
}

SECTIONS {

    .text : {
        KEEP(*(.loader))
	*(.text)
    } > RAM

    .data : {
	*(.data*)
    } > RAM

    .rodata : {
	*(.rodata*)
    } > RAM

    .got : {
	_gp = . + 0x7ff0;
	*(.got)
    } > RAM

    /DISCARD/ :
    {
	*(.eh_frame*)
	*(.reginfo)
	*(.MIPS.abiflags)
    } > RAM
}
