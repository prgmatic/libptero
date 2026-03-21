#include "regs.S"

#define EXC_STACK_SIZE (544)
#define STACK_GPR      0
#define STACK_HI     (STACK_GPR+(32*8))
#define STACK_LO     (STACK_HI+8)
#define STACK_SR     (STACK_LO+8)
#define STACK_CR     (STACK_SR+4)
#define STACK_EPC    (STACK_CR+4)
#define STACK_FC31   (STACK_EPC+4)
#define STACK_FPR    (STACK_FC31+4)

.section .interrupt.text, "ax"
.set noreorder
.set noat

    .org 0
    j interrupt_handler

    .org 0x80
    j interrupt_handler

    .org 0x100
    j interrupt_handler

.org 0x180
interrupt_handler: 
    addiu sp, -EXC_STACK_SIZE

    # Save caller-saved GPRs only. These are the only
    # ones required to call a C function from assembly, as the
    # others (callee-saved) would be preserved by the function 
    # itself, if modified.
    li t0, 0x11111111
    sd $1, (STACK_GPR+ 1*8)(sp) # AT
    .set at
    sd $2, (STACK_GPR+ 2*8)(sp) # V0
    sd $3, (STACK_GPR+ 3*8)(sp) # V1
    sd $4, (STACK_GPR+ 4*8)(sp) # A0
    sd $5, (STACK_GPR+ 5*8)(sp) # A1
    sd $6, (STACK_GPR+ 6*8)(sp) # A2
    sd $7, (STACK_GPR+ 7*8)(sp) # A3
    sd $8, (STACK_GPR+ 8*8)(sp) # T0
    sd $9, (STACK_GPR+ 9*8)(sp) # T1
    sd $10,(STACK_GPR+10*8)(sp) # T2
    sd $11,(STACK_GPR+11*8)(sp) # T3 
    sd $12,(STACK_GPR+12*8)(sp) # T4
    sd $13,(STACK_GPR+13*8)(sp) # T5
    sd $14,(STACK_GPR+14*8)(sp) # T6
    sd $15,(STACK_GPR+15*8)(sp) # T7
    sd $24,(STACK_GPR+24*8)(sp) # T8
    sd $25,(STACK_GPR+25*8)(sp) # T9
    sd $31,(STACK_GPR+31*8)(sp) # RA

    mflo t0
    mfhi t1
    sd t0,STACK_LO(sp)
    sd t1,STACK_HI(sp)
    
    mfc0 t0, C0_EPC
    mfc0 t1, C0_SR
    sw t0, STACK_EPC(sp)
    sw t1, STACK_SR(sp)

    # Since all critical information about current exception has been saved,
    # we can now turn off EXL. This allows a reentrant exception to save its
    # own full context for operating. At the same time, it is better to keep
    # interrupts disabled so that we don't risk triggering recursive interrupts,
    # so disable IE as well. If the triggering code was running in a non-kernel
    # mode, we also need to re-enter kernel mode.
    and t1, ~(SR_IE | SR_EXL | SR_KSU)
    mtc0 t1, C0_SR

    mfc0 t7, C0_CAUSE
    sw t7, STACK_CR(sp)


    sd $0, (STACK_GPR+ 0*8)(sp)   # ZR (this is mostly for register dumps)
    sd $16,(STACK_GPR+16*8)(sp)   # S0
    sd $17,(STACK_GPR+17*8)(sp)   # S1
    sd $18,(STACK_GPR+18*8)(sp)   # S2
    sd $19,(STACK_GPR+19*8)(sp)   # S3
    sd $20,(STACK_GPR+20*8)(sp)   # S4
    sd $21,(STACK_GPR+21*8)(sp)   # S5
    sd $22,(STACK_GPR+22*8)(sp)   # S6
    sd $23,(STACK_GPR+23*8)(sp)   # S7
    sd $28,(STACK_GPR+28*8)(sp)   # GP
    # SP has been modified to make space for the exception frame,
    # but we want to save the previous value in the exception frame itself.
    addiu $1, sp, EXC_STACK_SIZE
    sd $1, (STACK_GPR+29*8)(sp)   # SP
    sd $30,(STACK_GPR+30*8)(sp)   # FP
    sdc1 $f20,(STACK_FPR+20*8)(sp)
    sdc1 $f21,(STACK_FPR+21*8)(sp)
    sdc1 $f22,(STACK_FPR+22*8)(sp)
    sdc1 $f23,(STACK_FPR+23*8)(sp)
    sdc1 $f24,(STACK_FPR+24*8)(sp)
    sdc1 $f25,(STACK_FPR+25*8)(sp)
    sdc1 $f26,(STACK_FPR+26*8)(sp)
    sdc1 $f27,(STACK_FPR+27*8)(sp)
    sdc1 $f28,(STACK_FPR+28*8)(sp)
    sdc1 $f29,(STACK_FPR+29*8)(sp)
    sdc1 $f30,(STACK_FPR+30*8)(sp)
    sdc1 $f31,(STACK_FPR+31*8)(sp)

    move a0, sp
    j interruptHandler


# Pad out section so main program starts at 0x400
.org 0x400 - 0x4
nop
