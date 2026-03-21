OUTPUT_FORMAT ("elf32-bigmips", "elf32-bigmips", "elf32-littlemips")
OUTPUT_ARCH (mips)

ram_start_address = 0x80000000;

MEMORY {
    ROM : ORIGIN = 0x0, LENGTH = 0x100000 * 64 /* 64 MB of ROM */
    RAM : ORIGIN = ram_start_address, LENGTH = 0x100000 /* 1 MB of RAM for now */
}

SECTIONS {
    .interrup.text : {
	KEEP(*(.interrupt.text))
    } > RAM AT > ROM

    . = 0x400;
    .text : {
	*(.text.startup)
	*(.text*)
    } > RAM AT > ROM

    .data : ALIGN(8) {
	*(.data*)
	*(.sdata*)
	*(.rodata*)
    } > RAM AT > ROM

    .bss : ALIGN(8) {
	*(.bss*)
    } > RAM

    /DISCARD/ :
    {
	*(.eh_frame*)
	*(.reginfo)
	*(.MIPS.abiflags)
	*(.got)
    }
}

