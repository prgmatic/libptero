OUTPUT_ARCH(mips)
ENTRY(_start)

MEMORY {
    DMEM : ORIGIN = 0x0800, LENGTH = 0x0800
    IMEM : ORIGIN = 0x1800, LENGTH = 0x0800
}

SECTIONS {
    /* Leave room for the CPU-created overlay header and command table. */
    .data 0x0820 : {
        KEEP(*(.data*))
        KEEP(*(.rodata*))
    } > DMEM

    .bss (NOLOAD) : SUBALIGN(1) {
        *(.bss*)
    } > DMEM

    .text 0x1800 : {
        *(.text*)
    } > IMEM

    /DISCARD/ : {
        *(.MIPS.abiflags)
        *(.got*)
    }
}
