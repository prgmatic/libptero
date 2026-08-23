OUTPUT_ARCH (mips)

ram_start_address = 0x80000000;

MEMORY {
    ROM : ORIGIN = 0x0, LENGTH = 0x100000 * 64 /* 64 MB of ROM */
    RAM : ORIGIN = ram_start_address, LENGTH = 0x100000 /* 1 MB of RAM for now */
}

SECTIONS {
    .interrupt.text : {
	KEEP(*(.interrupt.text))
    } > RAM AT > ROM

    . = 0x400;
    .text : {
	__text_start = .;
	*(.text.startup)
	*(.text*)
	__text_end = .;
    } > RAM AT > ROM

    .data : ALIGN(8) {
	*(.data*)
	*(.sdata*)
	*(.rodata*)
    } > RAM AT > ROM

    .bss : ALIGN(8) {
	__bss_start = .;
	*(.bss*)
	__bss_end = .;
    } > RAM
 
    /DISCARD/ :
    {
    }
}
