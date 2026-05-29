OUTPUT_ARCH(mips)
ENTRY(_start)

MEMORY {
    IMEM : ORIGIN = 0, LENGTH = 0x1000
}

SECTIONS {
    .text 0 : {
        *(.text*)
    } > IMEM
}
