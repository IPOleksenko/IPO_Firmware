; int15.asm — BIOS System Services (INT 15h)
; Implements AX=E820h (Memory Map), AX=E801h (Memory Size), and AX=2401h (A20)
; Strictly stores all state and dynamic tables in conventional Scratch RAM (0x0000)
; ZERO writes to CS / Shadow RAM!

BITS 16

%include "contract.inc"

int15h_handler:
    sti
    cmp     ax, 0x2401
    je      .fn_enable_a20
    cmp     ax, 0xE801
    je      .fn_e801
    cmp     eax, 0x0000E820
    je      .fn_e820

    ; Unsupported function
    mov     ah, 0x86
    stc
    jmp     .exit

; -----------------------------------------------------------------------------
; AX = 0x2401 — Enable A20 Gate
; -----------------------------------------------------------------------------
.fn_enable_a20:
    call    a20_enable
    xor     ah, ah
    clc
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
    xor     bx, bx
    mov     ds, bx
    call    ensure_memory_detected

    mov     ax, [ds:SCRATCH_RAM_1_16M]
    mov     cx, ax

    mov     bx, [ds:SCRATCH_RAM_ABOVE16]
    mov     dx, bx

    pop     ds
    clc
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
    jae     .e820_param_ok
.e820_fail:
    stc
    jmp     .exit

.e820_param_ok:
    push    ds
    push    si
    push    bx

    ; Ensure dynamic memory map has been generated in Scratch RAM
    call    ensure_memory_detected

    pop     bx                              ; Restore requested entry index (EBX)

    ; Validate EBX index (< 4 entries)
    cmp     ebx, 4
    jae     short .e820_end_of_list

    ; Point DS:SI to SCRATCH_E820_TABLE + (EBX * 20)
    xor     ax, ax
    mov     ds, ax                          ; DS = 0x0000 (Scratch RAM)
    mov     ax, bx
    mov     cx, 20
    mul     cx
    mov     si, ax
    add     si, SCRATCH_E820_TABLE

    ; Copy 20 bytes to caller's ES:DI
    push    cx
    cld
    mov     cx, 10                          ; 10 words = 20 bytes
    rep     movsw
    pop     cx

    ; Next EBX continuation value
    inc     bx
    cmp     bx, 4
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
    stc
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
; Memory Detection & Dynamic E820 Table Generator
; Strictly writes only to Scratch RAM (0x0000:0x0500+)
; =============================================================================
ensure_memory_detected:
    push    eax
    push    edx
    push    bx
    push    cx
    push    di
    push    es

    xor     ax, ax
    mov     es, ax                          ; ES = 0x0000 (Scratch RAM)

    ; Only detect once
    cmp     byte [es:SCRATCH_MEM_FLAG], 1
    je      .already_detected

    ; Check if Boot_ROM already populated total RAM in Scratch RAM
    mov     eax, [es:SCRATCH_TOTAL_RAM]
    test    eax, eax
    jnz     .have_ram_size

    ; 1. Try CMOS registers 0x34/0x35 (standard on physical ATX PCs)
    mov     al, 0x34
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bl, al

    mov     al, 0x35
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bh, al                          ; BX = blocks above 16MB in 64KB units

    test    bx, bx
    jz      .try_cmos_base

    movzx   eax, bx
    shl     eax, 16                         ; * 65536 = bytes above 16MB
    add     eax, 16 * 1024 * 1024           ; + 16MB base
    jmp     .have_ram_size

.try_cmos_base:
    ; 2. Fallback: CMOS registers 0x30/0x31 (1-16MB memory in KB)
    mov     al, 0x30
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bl, al

    mov     al, 0x31
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bh, al                          ; BX = KB between 1MB and 16MB

    test    bx, bx
    jz      .default_ram

    movzx   eax, bx
    shl     eax, 10                         ; * 1024 = bytes
    add     eax, 1024 * 1024                ; + 1MB base
    jmp     .have_ram_size

.default_ram:
    mov     eax, 128 * 1024 * 1024          ; 128 MB default

.have_ram_size:
    ; Store total RAM in Scratch RAM
    mov     [es:SCRATCH_TOTAL_RAM], eax

    ; 1-16MB in KB (max 15MB = 15360 = 0x3C00)
    mov     word [es:SCRATCH_RAM_1_16M], 0x3C00

    ; Above 16MB in 64KB blocks
    mov     edx, eax
    cmp     edx, 16 * 1024 * 1024
    jbe     .no_above_16m
    sub     edx, 16 * 1024 * 1024
    shr     edx, 16
    mov     [es:SCRATCH_RAM_ABOVE16], dx
    jmp     .build_e820

.no_above_16m:
    mov     word [es:SCRATCH_RAM_ABOVE16], 0

.build_e820:
    ; =========================================================================
    ; Construct Dynamic E820 Table in Scratch RAM at SCRATCH_E820_TABLE (0x0598)
    ; =========================================================================
    mov     di, SCRATCH_E820_TABLE

    ; Entry 0: Usable Conventional RAM (0x00000 - 0x9FC00, 639 KB)
    mov     dword [es:di + 0],  0x00000000   ; Base low
    mov     dword [es:di + 4],  0x00000000   ; Base high
    mov     dword [es:di + 8],  0x0009FC00   ; Length low (639 KB)
    mov     dword [es:di + 12], 0x00000000   ; Length high
    mov     dword [es:di + 16], 1            ; Type 1 = Usable

    ; Entry 1: Reserved EBDA + Video RAM + BIOS ROM (0x9FC00 - 0x100000, 385 KB)
    mov     dword [es:di + 20], 0x0009FC00   ; Base low
    mov     dword [es:di + 24], 0x00000000   ; Base high
    mov     dword [es:di + 28], 0x00060400   ; Length low (385 KB)
    mov     dword [es:di + 32], 0x00000000   ; Length high
    mov     dword [es:di + 36], 2            ; Type 2 = Reserved

    ; Entry 2: Usable Extended RAM above 1MB (0x100000 onwards, clamped to TOLUD 0xE0000000)
    mov     dword [es:di + 40], 0x00100000   ; Base low (1 MB)
    mov     dword [es:di + 44], 0x00000000   ; Base high
    mov     edx, eax
    cmp     edx, 0xE0000000                  ; Clamp to TOLUD (0xE0000000 PCI MMIO hole)
    jbe     .ram_clamped
    mov     edx, 0xE0000000
.ram_clamped:
    cmp     edx, 0x00100000
    jae     .ram_has_extended
    xor     edx, edx
    jmp     .store_entry2_len
.ram_has_extended:
    sub     edx, 0x00100000                  ; Length = Clamped RAM - 1MB
.store_entry2_len:
    mov     dword [es:di + 48], edx          ; Length low
    mov     dword [es:di + 52], 0x00000000   ; Length high
    mov     dword [es:di + 56], 1            ; Type 1 = Usable

    ; Entry 3: Reserved PCI MMIO / APIC / SPI Flash (0xE0000000 - 0xFFFFFFFF, 512 MB)
    mov     dword [es:di + 60], 0xE0000000   ; Base low
    mov     dword [es:di + 64], 0x00000000   ; Base high
    mov     dword [es:di + 68], 0x20000000   ; Length low (512 MB)
    mov     dword [es:di + 72], 0x00000000   ; Length high
    mov     dword [es:di + 76], 2            ; Type 2 = Reserved

    mov     word [es:SCRATCH_E820_COUNT], 4
    mov     byte [es:SCRATCH_MEM_FLAG], 1

.already_detected:
    pop     es
    pop     di
    pop     cx
    pop     bx
    pop     edx
    pop     eax
    ret
