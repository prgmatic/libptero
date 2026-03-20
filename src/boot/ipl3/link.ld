OUTPUT_FORMAT ("elf32-bigmips", "elf32-bigmips", "elf32-littlemips")
OUTPUT_ARCH (mips)

MEMORY
{
    ROM  : ORIGIN =  0xB0000000, LENGTH = 65536
    DMEM : ORIGIN =  0xA4000000, LENGTH = 4096
}

SECTIONS {
    .text.prologue : {
	__start = .;
        KEEP(*(.header))
        KEEP(*(.text.boot_trampoline))
        KEEP(*(.text.ique_trampoline))
    } > ROM

    .text.dmem ORIGIN(DMEM) + 0x40 : AT(ORIGIN(ROM) + 0x1040) {
	_dmem_start = .;
	KEEP(*(.stage1.pre))
	KEEP(*(.stage1))
	*(.text*)
	*(.rodata*)
	*(.bss)
        . = ALIGN(8);
	_dmem_end = .;
    } > DMEM

    .data.rom 0xB0001040 + SIZEOF ( .text.dmem ) : {
	KEEP(*(.loader))
    } > ROM

    /DISCARD/ :
    {
	*(.eh_frame*)
	*(.reginfo)
	*(.MIPS.abiflags)
	*(.got)
    }
}
