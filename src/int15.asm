; int15.asm — BIOS System Services (INT 15h)
; Implements AX=E820h (Memory Map), AX=E801h (Memory Size), and AX=2401h (A20)

BITS 16

int15h_handler:
    sti
    cmp     eax, 0x0000E820
    je      .fn_e820
    cmp     ax, 0xE801
    je      .fn_e801
    cmp     ax, 0x2401
    je      .fn_enable_a20

    ; Unsupported function
    mov     ah, 0x86
    stc
    jmp     .exit

; -----------------------------------------------------------------------------
; EAX = 0xE820 — Query System Address Map
; Input:
;   EAX = 0xE820, EDX = 'SMAP' (0x534D4150)
;   EBX = Continuation handle (0 on first call)
;   ECX = Buffer size (at least 20 bytes)
;   ES:DI = Buffer for 20-byte AddressRangeDescriptor
; Output:
;   EAX = 'SMAP', ECX = 20, EBX = next handle (0 if last)
;   CF = 0 (success)
; -----------------------------------------------------------------------------
.fn_e820:
    cmp     edx, 0x534D4150                 ; Verify 'SMAP' signature
    jne     .e820_fail
    cmp     ecx, 20
    jb      .e820_fail

    push    ds
    push    si
    push    bx

    mov     ax, cs
    mov     ds, ax

    ; Ensure dynamic memory size has been detected
    call    ensure_memory_detected

    pop     bx                              ; Restore requested entry index (EBX)

    cmp     ebx, E820_TOTAL_ENTRIES
    jae     .e820_end_of_list

    ; Point SI to e820_table[ebx]
    ; Each entry is 20 bytes
    mov     ax, bx
    mov     cx, 20
    mul     cx
    mov     si, ax
    add     si, e820_table

    ; Copy 20 bytes to ES:DI
    push    cx
    cld
    mov     cx, 10                          ; 10 words = 20 bytes
    rep     movsw
    pop     cx

    ; Next EBX continuation value
    inc     bx
    cmp     bx, E820_TOTAL_ENTRIES
    jb      .e820_has_more
    xor     bx, bx                          ; 0 = done

.e820_has_more:
    pop     si
    pop     ds

    ; Success return
    mov     eax, 0x534D4150                 ; Return 'SMAP'
    mov     ecx, 20                         ; Return actual size written
    clc
    jmp     .exit

.e820_end_of_list:
    pop     si
    pop     ds
.e820_fail:
    stc
    jmp     .exit

; -----------------------------------------------------------------------------
; AX = 0xE801 — Get Memory Size for >64M Configurations
; Output:
;   AX = CX = Memory between 1MB and 16MB in KB (max 15MB = 15360 = 0x3C00)
;   BX = DX = Memory between 16MB and 4GB in 64KB blocks
;   CF = 0
; -----------------------------------------------------------------------------
.fn_e801:
    push    ds
    mov     bx, cs
    mov     ds, bx
    call    ensure_memory_detected

    ; AX = memory 1-16MB in KB (15360 KB = 0x3C00)
    mov     ax, [ram_kb_1_to_16m]
    mov     cx, ax

    ; BX = memory 16MB+ in 64KB blocks
    mov     bx, [ram_64k_above_16m]
    mov     dx, bx

    pop     ds
    clc
    jmp     .exit

; -----------------------------------------------------------------------------
; AX = 0x2401 — Enable A20 Gate
; -----------------------------------------------------------------------------
.fn_enable_a20:
    call    a20_enable
    xor     ah, ah
    clc
    jmp     .exit

.exit:
    push    bp
    mov     bp, sp
    jc      .set_cf
    and     byte [bp + 6], 0xFE             ; Clear caller's CF
    pop     bp
    iret
.set_cf:
    or      byte [bp + 6], 0x01             ; Set caller's CF
    pop     bp
    iret

; =============================================================================
; Memory Detection Routine (Standard CMOS primary + QEMU fw_cfg fallback)
; =============================================================================
ensure_memory_detected:
    push    eax
    push    edx
    push    bx
    push    cx

    ; Only detect once
    cmp     byte [mem_detected_flag], 1
    je      .already_detected

    ; 1. Try standard AT/ATX CMOS registers first (works on physical silicon)
    ; Read CMOS 0x34 (low), 0x35 (high) = 64KB blocks above 16MB
    mov     al, 0x34
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bl, al

    mov     al, 0x35
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bh, al                          ; BX = blocks above 16MB (64KB blocks)

    test    bx, bx
    jz      .try_fw_cfg

    movzx   eax, bx
    shl     eax, 16                         ; * 65536 = bytes above 16MB
    add     eax, 16 * 1024 * 1024           ; Add base 16 MB
    jmp     .store_and_compute

.try_fw_cfg:
    ; 2. Fallback to QEMU fw_cfg port 0x510 (selector) / 0x511 (data)
    ; Selector 0x0001 = FW_CFG_RAM_SIZE (64-bit total RAM in bytes)
    mov     dx, FW_CFG_PORT_SEL
    mov     ax, FW_CFG_ID_RAM_SIZE
    out     dx, ax

    mov     dx, FW_CFG_PORT_DATA
    in      al, dx
    mov     bl, al
    in      al, dx
    mov     bh, al
    in      al, dx
    mov     cl, al
    in      al, dx
    mov     ch, al                          ; CX:BX = low 32 bits of RAM size in bytes

    ; Assemble low 32-bit RAM size
    push    cx
    push    bx
    pop     eax                             ; EAX = total RAM in bytes

    ; Validate fw_cfg result (if missing, reads 0xFFFFFFFF or 0)
    test    eax, eax
    jz      .use_default_ram
    cmp     eax, 0xFFFFFFFF
    je      .use_default_ram
    jmp     .store_and_compute

.use_default_ram:
    ; Default: 128 MB
    mov     eax, 128 * 1024 * 1024

.store_and_compute:
    mov     [total_ram_bytes], eax

    ; Extended RAM above 1MB (Base 0x100000):
    ; Length = total_ram_bytes - 1MB (0x100000)
    mov     edx, eax
    sub     edx, 0x100000
    mov     [e820_entry2_len], edx

    ; Compute 1-16MB in KB (max 15MB = 15360 KB = 0x3C00)
    mov     word [ram_kb_1_to_16m], 0x3C00

    ; Compute 16MB+ in 64KB blocks
    mov     edx, eax
    cmp     edx, 16 * 1024 * 1024
    jbe     .no_above_16m
    sub     edx, 16 * 1024 * 1024
    shr     edx, 16                         ; Divide by 65536
    mov     [ram_64k_above_16m], dx
    jmp     .mark_done

.no_above_16m:
    mov     word [ram_64k_above_16m], 0

.mark_done:
    mov     byte [mem_detected_flag], 1

.already_detected:
    pop     cx
    pop     bx
    pop     edx
    pop     eax
    ret

; =============================================================================
; E820 Address Map Data
; =============================================================================
E820_TOTAL_ENTRIES  equ 3

align 4
mem_detected_flag   db 0
total_ram_bytes     dd 0
ram_kb_1_to_16m     dw 0x3C00
ram_64k_above_16m   dw 0

align 4
e820_table:
    ; Entry 0: Usable Conventional RAM (0x00000 - 0x9FC00, 639 KB)
    dq      0x0000000000000000              ; Base address = 0
    dq      0x000000000009FC00              ; Length = 639 KB
    dd      1                               ; Type 1 = Usable RAM

    ; Entry 1: Reserved EBDA + Video RAM + BIOS ROM (0x9FC00 - 0x100000)
    dq      0x000000000009FC00              ; Base address = 0x9FC00
    dq      0x0000000000060400              ; Length = 385 KB
    dd      2                               ; Type 2 = Reserved

    ; Entry 2: Usable Extended RAM above 1MB (0x100000 onwards)
    dq      0x0000000000100000              ; Base address = 1 MB (0x100000)
e820_entry2_len:
    dq      0x0000000007F00000              ; Default 127 MB (dynamically patched)
    dd      1                               ; Type 1 = Usable RAM
