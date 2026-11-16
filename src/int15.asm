; INT 15h services (E820h memory map, E801h memory size, 2401h A20).
; State and tables live in scratch RAM (0x0000); never writes to CS / shadow RAM.

BITS 16

%include "boot_constants.inc"

int15h_handler:
    sti
    cmp     ax, 0x2401
    je      .fn_enable_a20
    cmp     ax, 0xE801
    je      .fn_e801
    cmp     eax, 0x0000E820
    je      .fn_e820

    mov     ah, 0x86
    stc
    jmp     .exit

; AX=2401h: enable A20
.fn_enable_a20:
    call    a20_enable
    xor     ah, ah
    clc
    jmp     .exit

; AX=E801h: AX=CX = KiB in 1..16 MiB (max 15 MiB = 0x3C00), BX=DX = 64 KiB blocks above 16 MiB
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

; EAX=E820h: EDX='SMAP', EBX=cursor (0=first), ECX>=20, ES:DI=20 B buffer
.fn_e820:
    cmp     edx, 0x534D4150
    jne     .e820_fail
    cmp     ecx, 20
    jae     .e820_param_ok
.e820_fail:
    stc
    jmp     .exit

.e820_param_ok:
    push    ds
    push    si
    push    di
    push    ebx

    call    ensure_memory_detected

    pop     ebx

    xor     ax, ax
    mov     ds, ax

    movzx   edx, word [ds:SCRATCH_E820_COUNT]
    cmp     ebx, edx
    jae     short .e820_end_of_list

    imul    eax, ebx, 20
    mov     si, ax
    add     si, SCRATCH_E820_TABLE

    push    cx
    cld
    mov     cx, 10                          ; 20 B
    rep     movsw
    pop     cx

    inc     ebx
    cmp     ebx, edx
    jb      .e820_has_more
    xor     ebx, ebx

.e820_has_more:
    pop     di
    pop     si
    pop     ds

    mov     eax, 0x534D4150                 ; 'SMAP'
    mov     ecx, 20
    clc
    jmp     .exit

.e820_end_of_list:
    pop     di
    pop     si
    pop     ds
    stc
    jmp     .exit

.exit:
    push    bp
    mov     bp, sp
    jc      .set_cf
    and     byte [bp + 6], 0xFE             ; clear caller CF
    pop     bp
    iret
.set_cf:
    or      byte [bp + 6], 0x01             ; set caller CF
    pop     bp
    iret

; Probe RAM once and build E820 table in scratch RAM (0x0000:0x0500+)
ensure_memory_detected:
    push    eax
    push    edx
    push    bx
    push    cx
    push    di
    push    es

    xor     ax, ax
    mov     es, ax

    cmp     byte [es:SCRATCH_MEM_FLAG], 1
    je      .already_detected

    ; Reuse total RAM if stage-1 loader already stored it in scratch RAM
    mov     eax, [es:SCRATCH_TOTAL_RAM]
    test    eax, eax
    jnz     .have_ram_size

    ; CMOS 0x34/0x35: 64 KiB blocks above 16 MiB
    mov     al, 0x34
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bl, al

    mov     al, 0x35
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bh, al

    test    bx, bx
    jz      .try_cmos_base

    movzx   eax, bx
    shl     eax, 16
    add     eax, 16 * 1024 * 1024
    jmp     .have_ram_size

.try_cmos_base:
    ; Fallback: CMOS 0x30/0x31 (KiB between 1 MiB and 16 MiB)
    mov     al, 0x30
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bl, al

    mov     al, 0x31
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bh, al

    test    bx, bx
    jz      .default_ram

    movzx   eax, bx
    shl     eax, 10
    add     eax, 1024 * 1024
    jmp     .have_ram_size

.default_ram:
    mov     eax, 128 * 1024 * 1024          ; 128 MiB default

.have_ram_size:
    mov     [es:SCRATCH_TOTAL_RAM], eax

    ; 1..16 MiB in KiB (15 MiB max = 0x3C00)
    mov     word [es:SCRATCH_RAM_1_16M], 0x3C00

    ; Above 16 MiB in 64 KiB blocks
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
    mov     di, SCRATCH_E820_TABLE
    xor     cx, cx

    ; Entry 0: conventional RAM (0x00000..0x9FC00, 639 KiB)
    mov     dword [es:di + 0],  0x00000000
    mov     dword [es:di + 4],  0x00000000
    mov     dword [es:di + 8],  0x0009FC00
    mov     dword [es:di + 12], 0x00000000
    mov     dword [es:di + 16], 1            ; usable
    add     di, 20
    inc     cx

    ; Entry 1: EBDA + VRAM + ROM (0x9FC00..0x100000, 385 KiB)
    mov     dword [es:di + 0],  0x0009FC00
    mov     dword [es:di + 4],  0x00000000
    mov     dword [es:di + 8],  0x00060400
    mov     dword [es:di + 12], 0x00000000
    mov     dword [es:di + 16], 2            ; reserved
    add     di, 20
    inc     cx

    ; Clamp low RAM at TOLUD (0xE0000000) and reserve 128 KiB ACPI reclaim block
    mov     edx, eax
    cmp     edx, 0xE0000000
    jbe     .ram_clamped
    mov     edx, 0xE0000000
.ram_clamped:
    mov     dword [es:SCRATCH_ACPI_TOP], edx
    mov     dword [es:SCRATCH_ACPI_BASE], 0

    cmp     edx, 0x00400000                  ; only reserve ACPI block if >= 4 MiB
    jb      .no_acpi_window
    sub     edx, 0x00020000                  ; 128 KiB ACPI reclaim
    mov     dword [es:SCRATCH_ACPI_BASE], edx
.no_acpi_window:

    ; Entry 2: extended usable RAM (1 MiB .. usable low top)
    cmp     edx, 0x00100000
    jbe     .skip_ext_usable
    sub     edx, 0x00100000
    mov     dword [es:di + 0],  0x00100000
    mov     dword [es:di + 4],  0x00000000
    mov     dword [es:di + 8],  edx
    mov     dword [es:di + 12], 0x00000000
    mov     dword [es:di + 16], 1            ; usable
    add     di, 20
    inc     cx
.skip_ext_usable:

    ; Entry 3: ACPI Reclaim (128 KiB at top of low RAM, e.g. 0x7FFE0000..0x80000000)
    mov     ebx, [es:SCRATCH_ACPI_BASE]
    test    ebx, ebx
    jz      .skip_acpi_entry
    mov     dword [es:di + 0],  ebx
    mov     dword [es:di + 4],  0x00000000
    mov     dword [es:di + 8],  0x00020000
    mov     dword [es:di + 12], 0x00000000
    mov     dword [es:di + 16], 3            ; ACPI reclaim
    add     di, 20
    inc     cx
.skip_acpi_entry:

    ; Entry 4: PCI MMIO / APIC / flash (0xE0000000..0xFFFFFFFF, 512 MiB)
    mov     dword [es:di + 0],  0xE0000000
    mov     dword [es:di + 4],  0x00000000
    mov     dword [es:di + 8],  0x20000000
    mov     dword [es:di + 12], 0x00000000
    mov     dword [es:di + 16], 2            ; reserved
    add     di, 20
    inc     cx

    ; Probe RAM > 4 GiB using host config interface + CMOS 0x5B..0x5D (64 KiB blocks)
    mov     dword [es:SCRATCH_RAM_ABOVE4G_LO], 0
    mov     dword [es:SCRATCH_RAM_ABOVE4G_HI], 0
    push    cx
    mov     dx, 0x0510
    xor     ax, ax
    out     dx, ax                           ; host config signature selector
    mov     dx, 0x0511
    in      al, dx
    cmp     al, 'Q'
    jne     .no_above4g_pop
    in      al, dx
    cmp     al, 'E'
    jne     .no_above4g_pop
    in      al, dx
    cmp     al, 'M'
    jne     .no_above4g_pop
    in      al, dx
    cmp     al, 'U'
    jne     .no_above4g_pop

    mov     al, 0x5D
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    movzx   ebx, al
    shl     ebx, 16
    mov     al, 0x5C
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bh, al
    mov     al, 0x5B
    out     CMOS_INDEX_PORT, al
    in      al, CMOS_DATA_PORT
    mov     bl, al
    test    ebx, ebx
    jz      .no_above4g_pop
    cmp     ebx, 0x00FFFFFF
    je      .no_above4g_pop

    ; Bytes above 4 GiB = EBX * 64 KiB
    mov     eax, ebx
    shl     eax, 16
    mov     edx, ebx
    shr     edx, 16
    mov     [es:SCRATCH_RAM_ABOVE4G_LO], eax
    mov     [es:SCRATCH_RAM_ABOVE4G_HI], edx

    pop     cx
    mov     dword [es:di + 0],  0x00000000
    mov     dword [es:di + 4],  0x00000001   ; 4 GiB base (0x1_00000000)
    mov     dword [es:di + 8],  eax
    mov     dword [es:di + 12], edx
    mov     dword [es:di + 16], 1            ; usable > 4 GiB
    add     di, 20
    inc     cx
    jmp     .e820_finish

.no_above4g_pop:
    pop     cx

.e820_finish:
    mov     word [es:SCRATCH_E820_COUNT], cx
    mov     byte [es:SCRATCH_MEM_FLAG], 1

.already_detected:
    pop     es
    pop     di
    pop     cx
    pop     bx
    pop     edx
    pop     eax
    ret
