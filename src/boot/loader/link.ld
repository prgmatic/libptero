OUTPUT_FORMAT ("elf32-bigmips", "elf32-bigmips", "elf32-littlemips")
OUTPUT_ARCH (mips)

MEMORY
{
    RAM  : ORIGIN =  0x80000000, LENGTH = 65536
}

SECTIONS {

    .text : {
        KEEP(*(.loader))
	*(.text*)
	*(.data*)
	*(.rodata*)
	*(.bss*)
    } > RAM

    .got : ALIGN(8) {
	__got_start = .;
	*(.got)
	. = ALIGN(8);
    } > RAM

    .got_idx : {

	LONG(0);
	__got_end = .;
	LONG(__got_end - __got_start);
    } > RAM

    /DISCARD/ :
    {
	*(.eh_frame*)
	*(.reginfo)
	*(.MIPS.abiflags)
    } > RAM
}
