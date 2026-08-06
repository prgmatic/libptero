OUTPUT_ARCH(mips)
ENTRY(_start)

MEMORY {
    DMEM : ORIGIN = 0x0000, LENGTH = 0x1000
    IMEM : ORIGIN = 0x1000, LENGTH = 0x1000
}

SECTIONS {
    .data 0x0000 : {
        KEEP(*(.data*))
        KEEP(*(.rodata*))
    } > DMEM

    .bss (NOLOAD) : SUBALIGN(1) {
        *(.bss*)
    } > DMEM

    .text 0x1000 : {
        *(.text*)
    } > IMEM

    /DISCARD/ : {
        *(.MIPS.abiflags)
        *(.got*)
    }
}
