OUTPUT_ARCH(mips)
ENTRY(_start)

MEMORY {
    DMEM : ORIGIN = 0x0000, LENGTH = 0x1000
    IMEM : ORIGIN = 0x1000, LENGTH = 0x0800
}

SECTIONS {
    .data 0x0000 : {
        KEEP(*(.data*))
        KEEP(*(.rodata*))
    } > DMEM

    .bss (NOLOAD) : SUBALIGN(1) {
        *(.bss*)
    } > DMEM

    ASSERT(. <= 0x01f8, "resident DMEM overlaps the overlay header")

    .text 0x1000 : {
        *(.text*)
    } > IMEM

    /DISCARD/ : {
        *(.MIPS.abiflags)
        *(.got*)
    }
}
