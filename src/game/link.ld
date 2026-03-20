OUTPUT_FORMAT ("elf32-bigmips", "elf32-bigmips", "elf32-littlemips")
OUTPUT_ARCH (mips)

ram_start_address = 0x80000000;
bank_size = 0x100000;

MEMORY {
    ROM : ORIGIN = 0x0, LENGTH = bank_size * 64
    RAM_BANK_0 : ORIGIN = ram_start_address + 0x400, LENGTH = bank_size - 0x400
    RAM_BANK_1 : ORIGIN = ram_start_address + bank_size * 1, LENGTH = bank_size
    RAM_BANK_2 : ORIGIN = ram_start_address + bank_size * 2, LENGTH = bank_size
    RAM_BANK_3 : ORIGIN = ram_start_address + bank_size * 3, LENGTH = bank_size
}

SECTIONS {
    .bank0.text : {
	*(.text.startup)
	*(.text*)
    } > RAM_BANK_0 AT > ROM

    .bank0.data : ALIGN(8) {
	*(.data*)
	*(.sdata*)
	*(.rodata*)
    } > RAM_BANK_0 AT > ROM

    .bank0.bss : ALIGN(8) {
	*(.bss*)
    } > RAM_BANK_0

    /DISCARD/ :
    {
	*(.eh_frame*)
	*(.reginfo)
	*(.MIPS.abiflags)
	*(.got)
    }
}

