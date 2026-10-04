/* 把 gk3probe-child.efi 原样嵌进探针（路径由 Makefile 的 -DCHILD_PE=… 给） */
    .section .rodata
    .balign 16
    .global gk3_child_pe
gk3_child_pe:
    .incbin CHILD_PE
    .global gk3_child_pe_end
gk3_child_pe_end:
    .byte 0
    .section .note.GNU-stack,"",%progbits
