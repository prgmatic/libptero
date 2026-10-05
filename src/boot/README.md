# Boot
This is Libptero's ipl3 bootloader

Before entering the application ELF, the loader initializes FCSR to `0x01000000`:
round to nearest, exceptions masked, and FS enabled. On VR4300, FS allows
subnormal arithmetic results to become signed zero instead of raising an
unimplemented-operation exception. This also applies to custom ELF entry points.
Subnormal input operands are still unsupported and must be sanitized before
arithmetic. Underflow and inexact exception enables must remain clear for FS to
work.
