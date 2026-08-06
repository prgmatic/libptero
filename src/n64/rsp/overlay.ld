OUTPUT_ARCH(mips)
ENTRY(_start)

MEMORY {
    DMEM : ORIGIN = 0x0800, LENGTH = 0x0800
    IMEM : ORIGIN = 0x1800, LENGTH = 0x0800
}

SECTIONS {
    .data 0x0800 : {
        *(.data*)
        *(.rodata*)
    } > DMEM

    .bss (NOLOAD) : {
        *(.bss*)
    } > DMEM

    .text 0x1800 : {
        *(.text*)
    } > IMEM

    /DISCARD/ : {
        *(.MIPS.abiflags)
    }
}
