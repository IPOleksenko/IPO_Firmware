; Runtime CPU/IOAPIC discovery (broadcast INIT-SIPI-SIPI + optional host config
; fast-exit hint) and ACPI table builder: RSDP in EBDA (0x9FC00), plus RSDT,
; MADT (local APICs, IOAPIC, ISOs), FACP, and DSDT in SCRATCH_ACPI_BASE.

BITS 16

%include "boot_constants.inc"

EBDA_SEG         equ 0x9FC0
EBDA_RSDP_OFF    equ 0x0000      ; phys 0x9FC00
EBDA_RSDT_OFF    equ 0x0040      ; fallback RSDT (< 4 MiB RAM)
EBDA_MADT_OFF    equ 0x0080      ; fallback MADT (< 4 MiB RAM)

SMP_PROBE_BASE       equ 0x2000  ; AP SIPI vector 0x02 -> 0x0200:0x0000
SMP_PROBE_LOCK       equ 0x2200  ; byte spinlock
SMP_PROBE_COUNT      equ 0x2204  ; dword CPU count
SMP_PROBE_LAPIC_BASE equ 0x2208  ; dword LAPIC base
SMP_PROBE_APIC_IDS   equ 0x2210  ; up to 255 byte hardware LAPIC IDs

ACPI_DSDT_OFF    equ 0x0000
ACPI_FACP_OFF    equ 0x0400
ACPI_MADT_OFF    equ 0x0500
ACPI_RSDT_OFF    equ 0x1000

; Emit an ACPI AML PNP device with optional I/O port and IRQ resources.
; %1=4-char NameSeg, %2=32-bit EISA ID, %3=IO base (0=none), %4=IO len, %5=IRQ (-1=none)
%macro ACPI_AML_DEV 5
%%dev_start:
    db 0x5B, 0x82                        ; ExtOp + DeviceOp
    db (%%dev_end - %%dev_start - 2)     ; single-byte PkgLength (< 64 B)
    db %1                                ; NameSeg
    db 0x08, "_HID", 0x0C
    dd %2                                ; compressed EISA ID
    db 0x08, "_STA", 0x0A, 0x0F          ; present + enabled + functional
    db 0x08, "_CRS", 0x11                ; BufferOp
    db (%%crs_end - %%crs_buf_len + 1)   ; buffer PkgLength (includes itself)
%%crs_buf_len:
    db 0x0A, (%%crs_end - %%crs_data)
%%crs_data:
%if %3 != 0
    db 0x47, 0x01                        ; 16-bit I/O port descriptor
    dw %3, %3                            ; min, max
    db 0x01, %4                          ; align=1, length
%endif
%if %5 >= 0
    db 0x22                              ; IRQ descriptor
    dw (1 << %5)
%endif
    db 0x79, 0x00                        ; EndTag
%%crs_end:
%%dev_end:
%endmacro

acpi_init_tables:
    pushad
    pushfd
    cli
    push    ds
    push    es

    ; Populate SCRATCH_ACPI_BASE if E820 detection has not run yet
    call    ensure_memory_detected

    ; Zero 1 KiB EBDA (0x9FC00..0x9FFFF)
    mov     ax, EBDA_SEG
    mov     es, ax
    xor     di, di
    mov     cx, 256
    xor     eax, eax
    cld
    rep     stosd

    ; Use 4 GiB flat ES limit for LAPIC/IOAPIC MMIO and high ACPI RAM
    call    acpi_enter_unreal

    call    acpi_discover_cpus_and_ioapic

    xor     ax, ax
    mov     es, ax
    mov     edi, [es:SCRATCH_ACPI_BASE]
    test    edi, edi
    jnz     .build_high_tables

    ; Low-memory (< 4 MiB) fallback inside EBDA
    call    acpi_build_ebda_fallback
    jmp     .acpi_cleanup

.build_high_tables:
    ; Zero first 8 KiB of high ACPI block
    push    edi
    mov     ecx, 2048
    xor     eax, eax
    cld
    a32 rep stosd
    pop     edi                          ; acpi_base

    ; DSDT at acpi_base + ACPI_DSDT_OFF
    mov     ebx, edi
    add     ebx, ACPI_DSDT_OFF
    mov     eax, dsdt_template_end - dsdt_template_start
    push    esi
    push    edi
    mov     si, dsdt_template_start
    mov     edi, ebx
    mov     ecx, eax
    cld
.copy_dsdt:
    mov     dl, [cs:si]
    mov     [es:edi], dl
    inc     si
    inc     edi
    dec     ecx
    jnz     .copy_dsdt
    pop     edi
    pop     esi

    mov     [es:ebx + 0x04], eax         ; DSDT length
    mov     byte [es:ebx + 0x09], 0
    mov     esi, ebx
    mov     ecx, eax
    call    acpi_checksum_high
    mov     [es:ebx + 0x09], al

    ; FACP (FADT, 116 B) at acpi_base + ACPI_FACP_OFF
    mov     ebx, edi
    add     ebx, ACPI_FACP_OFF
    mov     dword [es:ebx + 0x00], 'FACP'
    mov     dword [es:ebx + 0x04], 116
    mov     byte  [es:ebx + 0x08], 0
    mov     byte  [es:ebx + 0x09], 0
    call    acpi_fill_oem_fields_high
    mov     eax, edi
    add     eax, ACPI_DSDT_OFF
    mov     dword [es:ebx + 0x24], 0     ; FIRMWARE_CTRL
    mov     dword [es:ebx + 0x28], eax   ; DSDT phys addr
    mov     byte  [es:ebx + 0x2D], 0     ; Preferred_PM_Profile = unspecified
    mov     word  [es:ebx + 0x2E], 9     ; SCI_INT = IRQ 9
    mov     dword [es:ebx + 0x38], 0x0600 ; PM1a_EVT_BLK
    mov     dword [es:ebx + 0x40], 0x0604 ; PM1a_CNT_BLK
    mov     dword [es:ebx + 0x4C], 0x0608 ; PM_TMR_BLK
    mov     byte  [es:ebx + 0x58], 4     ; PM1_EVT_LEN
    mov     byte  [es:ebx + 0x59], 2     ; PM1_CNT_LEN
    mov     byte  [es:ebx + 0x5B], 4     ; PM_TMR_LEN
    mov     dword [es:ebx + 0x70], 0x000000A5 ; WBINVD | PROC_C1 | SLP_BUTTON | FIX_RTC

    mov     esi, ebx
    mov     ecx, 116
    call    acpi_checksum_high
    mov     [es:ebx + 0x09], al

    ; MADT ('APIC') at acpi_base + ACPI_MADT_OFF
    mov     ebx, edi
    add     ebx, ACPI_MADT_OFF
    mov     dword [es:ebx + 0x00], 'APIC'
    mov     byte  [es:ebx + 0x08], 0
    mov     byte  [es:ebx + 0x09], 0
    call    acpi_fill_oem_fields_high

    mov     eax, [es:SCRATCH_LAPIC_BASE]
    test    eax, eax
    jnz     .madt_lapic_ok
    mov     eax, 0xFEE00000
.madt_lapic_ok:
    mov     dword [es:ebx + 0x24], eax   ; Local APIC address
    mov     dword [es:ebx + 0x28], 1     ; PCAT_COMPAT (dual PIC)

    ; Type 0 Local APIC entries
    mov     ebp, ebx
    add     ebp, 44
    movzx   ecx, word [es:SCRATCH_CPU_COUNT]
    test    ecx, ecx
    jnz     .madt_cnt_ok
    mov     ecx, 1
.madt_cnt_ok:
    xor     edx, edx                     ; ACPI Processor ID (0..N-1)
.madt_cpu_loop:
    mov     byte  [es:ebp + 0], 0        ; Type 0 (Processor Local APIC)
    mov     byte  [es:ebp + 1], 8
    mov     [es:ebp + 2], dl             ; ACPI Processor ID
    mov     al, [es:SMP_PROBE_APIC_IDS + edx]
    mov     [es:ebp + 3], al             ; APIC ID
    mov     dword [es:ebp + 4], 1        ; Enabled
    add     ebp, 8
    inc     edx
    cmp     edx, ecx
    jb      .madt_cpu_loop

    ; Type 1 I/O APIC + Type 2 Interrupt Source Overrides
    cmp     byte [es:SCRATCH_IOAPIC_FOUND], 1
    jne     .madt_finalize

    mov     byte  [es:ebp + 0], 1        ; Type 1 (I/O APIC)
    mov     byte  [es:ebp + 1], 12
    mov     byte  [es:ebp + 2], 0        ; IOAPIC ID
    mov     byte  [es:ebp + 3], 0
    mov     dword [es:ebp + 4], 0xFEC00000
    mov     dword [es:ebp + 8], 0        ; GSI base = 0
    add     ebp, 12

    ; Type 2 ISO: ISA IRQ 0 (PIT) -> GSI 2
    mov     byte  [es:ebp + 0], 2
    mov     byte  [es:ebp + 1], 10
    mov     byte  [es:ebp + 2], 0        ; ISA
    mov     byte  [es:ebp + 3], 0        ; IRQ 0
    mov     dword [es:ebp + 4], 2        ; GSI 2
    mov     word  [es:ebp + 8], 0x0000
    add     ebp, 10

    ; Type 2 ISO: ISA IRQ 9 (ACPI SCI) -> GSI 9 (active low, level-triggered)
    mov     byte  [es:ebp + 0], 2
    mov     byte  [es:ebp + 1], 10
    mov     byte  [es:ebp + 2], 0        ; ISA
    mov     byte  [es:ebp + 3], 9        ; IRQ 9
    mov     dword [es:ebp + 4], 9        ; GSI 9
    mov     word  [es:ebp + 8], 0x000D
    add     ebp, 10

.madt_finalize:
    mov     eax, ebp
    sub     eax, ebx
    mov     dword [es:ebx + 0x04], eax
    mov     esi, ebx
    mov     ecx, eax
    call    acpi_checksum_high
    mov     [es:ebx + 0x09], al

    ; RSDT at acpi_base + ACPI_RSDT_OFF
    mov     ebx, edi
    add     ebx, ACPI_RSDT_OFF
    mov     dword [es:ebx + 0x00], 'RSDT'
    mov     dword [es:ebx + 0x04], 44    ; 36 + 2 * 4 (FACP + MADT)
    mov     byte  [es:ebx + 0x08], 0
    mov     byte  [es:ebx + 0x09], 0
    call    acpi_fill_oem_fields_high

    mov     eax, edi
    add     eax, ACPI_FACP_OFF
    mov     dword [es:ebx + 0x24], eax
    mov     eax, edi
    add     eax, ACPI_MADT_OFF
    mov     dword [es:ebx + 0x28], eax

    mov     esi, ebx
    mov     ecx, 44
    call    acpi_checksum_high
    mov     [es:ebx + 0x09], al

    ; RSDP in EBDA (0x9FC00) -> RSDT
    mov     eax, edi
    add     eax, ACPI_RSDT_OFF
    mov     ebx, (EBDA_SEG << 4) + EBDA_RSDP_OFF
    mov     dword [es:ebx + 0x00], 'RSD '
    mov     dword [es:ebx + 0x04], 'PTR '
    mov     byte  [es:ebx + 0x08], 0
    mov     dword [es:ebx + 0x09], 'IPO '
    mov     word  [es:ebx + 0x0D], '  '
    mov     byte  [es:ebx + 0x0F], 0
    mov     dword [es:ebx + 0x10], eax

    mov     esi, ebx
    mov     ecx, 20
    call    acpi_checksum_high
    mov     [es:ebx + 0x08], al

.acpi_cleanup:
    ; Zero temporary AP probe area (0x2000..0x23FF)
    mov     edi, SMP_PROBE_BASE
    mov     ecx, 256
    xor     eax, eax
    cld
    a32 rep stosd

    call    acpi_leave_unreal

    pop     es
    pop     ds
    popfd
    popad
    ret

; Probe CPUs using Local APIC broadcast INIT-SIPI-SIPI and check IOAPIC at 0xFEC00000.
; Precondition: ES has 4 GiB flat limit (base 0), IF=0.
; Populates SCRATCH_CPU_COUNT, SCRATCH_LAPIC_BASE, SCRATCH_IOAPIC_FOUND, and
; sorted APIC IDs at SMP_PROBE_APIC_IDS[0..N-1].
acpi_discover_cpus_and_ioapic:
    pushad

    mov     edi, SMP_PROBE_BASE
    mov     ecx, 256
    xor     eax, eax
    cld
    a32 rep stosd

    mov     word [es:SCRATCH_CPU_COUNT], 1
    mov     byte [es:SCRATCH_IOAPIC_FOUND], 0
    mov     dword [es:SCRATCH_LAPIC_BASE], 0xFEE00000
    mov     byte [es:SMP_PROBE_APIC_IDS], 0
    mov     dword [es:SMP_PROBE_COUNT], 1

    ; Check CPUID support using EFLAGS.ID (bit 21)
    pushfd
    pop     eax
    mov     ecx, eax
    xor     eax, (1 << 21)
    push    eax
    popfd
    pushfd
    pop     eax
    push    ecx
    popfd
    xor     eax, ecx
    test    eax, (1 << 21)
    jz      .discover_done

    xor     eax, eax
    cpuid
    cmp     eax, 1
    jb      .discover_done
    mov     eax, 1
    cpuid
    test    edx, (1 << 9)                ; APIC feature bit
    jz      .discover_done

    ; Enable LAPIC in IA32_APIC_BASE MSR (0x1B bit 11)
    mov     ecx, 0x1B
    rdmsr
    or      eax, (1 << 11)
    wrmsr
    and     eax, 0xFFFFF000
    test    eax, eax
    jnz     .lapic_addr_ok
    mov     eax, 0xFEE00000
.lapic_addr_ok:
    mov     [es:SCRATCH_LAPIC_BASE], eax
    mov     [es:SMP_PROBE_LAPIC_BASE], eax
    mov     edi, eax

    ; Enable LAPIC in SVR (0x1FF) and clear ESR
    mov     eax, [es:edi + 0xF0]
    or      eax, 0x01FF
    mov     [es:edi + 0xF0], eax
    mov     dword [es:edi + 0x280], 0

    ; Record BSP APIC ID
    mov     eax, [es:edi + 0x20]
    shr     eax, 24
    mov     [es:SMP_PROBE_APIC_IDS], al
    mov     dword [es:SMP_PROBE_COUNT], 1

    ; Copy 16-bit AP probe stub to 0x2000
    push    edi
    mov     si, ap_probe_stub
    mov     edi, SMP_PROBE_BASE
    mov     ecx, ap_probe_stub_end - ap_probe_stub
.copy_ap_stub:
    mov     al, [cs:si]
    mov     [es:edi], al
    inc     si
    inc     edi
    dec     ecx
    jnz     .copy_ap_stub
    pop     edi

    ; Probe host config interface NB_CPUS (selector 0x0005) as a fast-exit hint
    xor     ebp, ebp                     ; EBP = expected count (0 if unavailable)
    mov     dx, 0x0510
    xor     ax, ax
    out     dx, ax
    mov     dx, 0x0511
    in      al, dx
    cmp     al, 'Q'
    jne     .no_fwcfg_hint
    in      al, dx
    cmp     al, 'E'
    jne     .no_fwcfg_hint
    in      al, dx
    cmp     al, 'M'
    jne     .no_fwcfg_hint
    in      al, dx
    cmp     al, 'U'
    jne     .no_fwcfg_hint
    mov     dx, 0x0510
    mov     ax, 0x0005                   ; host config NB_CPUS selector
    out     dx, ax
    mov     dx, 0x0511
    in      al, dx
    mov     cl, al
    in      al, dx
    mov     ch, al
    movzx   ebp, cx
.no_fwcfg_hint:

    ; Broadcast INIT Assert (all-excluding-self)
    cmp     ebp, 1
    je      .wait_aps_done
    call    acpi_wait_icr_idle
    mov     dword [es:edi + 0x300], 0x000C4500
    mov     cx, 667                      ; ~10 ms
    call    acpi_delay_15us_ticks

    ; Broadcast INIT De-assert
    call    acpi_wait_icr_idle
    mov     dword [es:edi + 0x300], 0x000C8500
    mov     cx, 20                       ; ~300 us
    call    acpi_delay_15us_ticks

    ; Broadcast SIPI #1 (vector 0x02 -> 0x2000)
    call    acpi_wait_icr_idle
    mov     dword [es:edi + 0x300], 0x000C4602
    mov     cx, 35                       ; ~500 us
    call    acpi_delay_15us_ticks

    ; Send SIPI #2 unless expected count already checked in
    test    ebp, ebp
    jz      .send_sipi2
    cmp     [es:SMP_PROBE_COUNT], ebp
    jae     .wait_aps_done
.send_sipi2:
    call    acpi_wait_icr_idle
    mov     dword [es:edi + 0x300], 0x000C4602

    ; Poll up to ~90 ms until expected count arrives or count settles for ~6 ms
    mov     cx, 6000
    mov     ebx, [es:SMP_PROBE_COUNT]
    xor     edx, edx
.wait_aps_loop:
    test    ebp, ebp
    jz      .check_stable
    cmp     [es:SMP_PROBE_COUNT], ebp
    jae     .wait_aps_done
    jmp     .wait_step

.check_stable:
    mov     eax, [es:SMP_PROBE_COUNT]
    cmp     eax, ebx
    je      .same_count
    mov     ebx, eax
    xor     edx, edx
    jmp     .wait_step
.same_count:
    cmp     ebx, 1
    jbe     .wait_step                   ; wait full window if only BSP seen
    inc     edx
    cmp     edx, 400                     ; ~6 ms after last AP check-in
    jae     .wait_aps_done

.wait_step:
    push    cx
    mov     cx, 1
    call    acpi_delay_15us_ticks
    pop     cx
    loop    .wait_aps_loop

.wait_aps_done:
    ; APs remain parked in cli/hlt; the OS wakes them with its own INIT-SIPI-SIPI.
    mov     eax, [es:SMP_PROBE_COUNT]
    cmp     eax, 255
    jbe     .cnt_bounded
    mov     eax, 255
.cnt_bounded:
    test    eax, eax
    jnz     .cnt_nonzero
    mov     eax, 1
.cnt_nonzero:
    mov     word [es:SCRATCH_CPU_COUNT], ax

    ; Sort APIC IDs ascending
    cmp     eax, 2
    jb      .check_ioapic
    mov     ecx, eax
    dec     ecx
.sort_outer:
    xor     esi, esi
.sort_inner:
    mov     al, [es:SMP_PROBE_APIC_IDS + esi]
    mov     bl, [es:SMP_PROBE_APIC_IDS + esi + 1]
    cmp     al, bl
    jbe     .sort_next
    mov     [es:SMP_PROBE_APIC_IDS + esi], bl
    mov     [es:SMP_PROBE_APIC_IDS + esi + 1], al
.sort_next:
    inc     esi
    cmp     esi, ecx
    jb      .sort_inner
    loop    .sort_outer

.check_ioapic:
    ; Probe IOAPIC at 0xFEC00000 (reg 0x01 = IOAPICVER)
    mov     edi, 0xFEC00000
    mov     dword [es:edi], 0x01
    mov     eax, [es:edi + 0x10]
    cmp     eax, 0xFFFFFFFF
    je      .discover_done
    test    eax, eax
    jz      .discover_done
    mov     byte [es:SCRATCH_IOAPIC_FOUND], 1

.discover_done:
    popad
    ret

; Wait for ICR Delivery Status (bit 12) to clear (EDI = LAPIC base)
acpi_wait_icr_idle:
    push    ecx
    mov     ecx, 100000
.wait:
    test    dword [es:edi + 0x300], (1 << 12)
    jz      .done
    pause
    dec     ecx
    jnz     .wait
.done:
    pop     ecx
    ret

; Delay CX * ~15.085 us using port 0x61 refresh toggle (bit 4)
acpi_delay_15us_ticks:
    push    ax
    push    cx
.tick:
    in      al, 0x61
    and     al, 0x10
    mov     ah, al
.edge:
    in      al, 0x61
    and     al, 0x10
    cmp     al, ah
    je      .edge
    loop    .tick
    pop     cx
    pop     ax
    ret

; Fill OEM/Creator IDs in ACPI header at EBX (ES = 4 GiB flat)
acpi_fill_oem_fields_high:
    mov     dword [es:ebx + 0x0A], 'IPO '
    mov     word  [es:ebx + 0x0E], '  '
    mov     dword [es:ebx + 0x10], 'IPO '
    mov     dword [es:ebx + 0x14], '    '
    mov     dword [es:ebx + 0x18], 0
    mov     dword [es:ebx + 0x1C], 'IPO '
    mov     dword [es:ebx + 0x20], 0
    ret

; 8-bit two's complement checksum over ECX bytes at ESI (ES = 4 GiB flat)
acpi_checksum_high:
    push    ecx
    push    esi
    xor     al, al
.loop:
    add     al, [es:esi]
    inc     esi
    dec     ecx
    jnz     .loop
    neg     al
    pop     esi
    pop     ecx
    ret

; Low-RAM (< 4 MiB) fallback keeping MADT + RSDT + RSDP in EBDA
acpi_build_ebda_fallback:
    pushad
    mov     ebx, (EBDA_SEG << 4) + EBDA_MADT_OFF
    mov     dword [es:ebx + 0x00], 'APIC'
    mov     byte  [es:ebx + 0x08], 0
    mov     byte  [es:ebx + 0x09], 0
    call    acpi_fill_oem_fields_high
    mov     eax, [es:SCRATCH_LAPIC_BASE]
    test    eax, eax
    jnz     .fb_lapic_ok
    mov     eax, 0xFEE00000
.fb_lapic_ok:
    mov     dword [es:ebx + 0x24], eax
    mov     dword [es:ebx + 0x28], 1

    mov     ebp, ebx
    add     ebp, 44
    movzx   ecx, word [es:SCRATCH_CPU_COUNT]
    test    ecx, ecx
    jnz     .fb_cnt_ok
    mov     ecx, 1
.fb_cnt_ok:
    cmp     ecx, 64
    jbe     .fb_cnt_cap
    mov     ecx, 64
.fb_cnt_cap:
    xor     edx, edx
.fb_cpu_loop:
    mov     byte  [es:ebp + 0], 0
    mov     byte  [es:ebp + 1], 8
    mov     [es:ebp + 2], dl
    mov     al, [es:SMP_PROBE_APIC_IDS + edx]
    mov     [es:ebp + 3], al
    mov     dword [es:ebp + 4], 1
    add     ebp, 8
    inc     edx
    cmp     edx, ecx
    jb      .fb_cpu_loop

    mov     eax, ebp
    sub     eax, ebx
    mov     dword [es:ebx + 0x04], eax
    mov     esi, ebx
    mov     ecx, eax
    call    acpi_checksum_high
    mov     [es:ebx + 0x09], al

    mov     ebx, (EBDA_SEG << 4) + EBDA_RSDT_OFF
    mov     dword [es:ebx + 0x00], 'RSDT'
    mov     dword [es:ebx + 0x04], 40
    mov     byte  [es:ebx + 0x08], 0
    mov     byte  [es:ebx + 0x09], 0
    call    acpi_fill_oem_fields_high
    mov     dword [es:ebx + 0x24], (EBDA_SEG << 4) + EBDA_MADT_OFF
    mov     esi, ebx
    mov     ecx, 40
    call    acpi_checksum_high
    mov     [es:ebx + 0x09], al

    mov     ebx, (EBDA_SEG << 4) + EBDA_RSDP_OFF
    mov     dword [es:ebx + 0x00], 'RSD '
    mov     dword [es:ebx + 0x04], 'PTR '
    mov     byte  [es:ebx + 0x08], 0
    mov     dword [es:ebx + 0x09], 'IPO '
    mov     word  [es:ebx + 0x0D], '  '
    mov     byte  [es:ebx + 0x0F], 0
    mov     dword [es:ebx + 0x10], (EBDA_SEG << 4) + EBDA_RSDT_OFF
    mov     esi, ebx
    mov     ecx, 20
    call    acpi_checksum_high
    mov     [es:ebx + 0x08], al
    popad
    ret

; Switch ES between 4 GiB flat unreal mode and 64 KiB real-mode limit
acpi_enter_unreal:
    push    eax
    push    bx
    lgdt    [cs:acpi_unreal_gdt_desc]
    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax
    jmp     short .pm1
.pm1:
    mov     bx, 0x08
    mov     es, bx
    and     eax, ~1
    mov     cr0, eax
    xor     bx, bx
    mov     es, bx
    pop     bx
    pop     eax
    ret

acpi_leave_unreal:
    push    eax
    push    bx
    lgdt    [cs:acpi_unreal_gdt_desc]
    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax
    jmp     short .pm2
.pm2:
    mov     bx, 0x10
    mov     es, bx
    and     eax, ~1
    mov     cr0, eax
    xor     bx, bx
    mov     es, bx
    pop     bx
    pop     eax
    ret

align 8
acpi_unreal_gdt:
    dq 0x0000000000000000                ; 0x00: null
    dq 0x00CF92000000FFFF                ; 0x08: 4 GiB data
    dq 0x000092000000FFFF                ; 0x10: 64 KiB data
acpi_unreal_gdt_desc:
    dw 23
    dd 0xF0000 + acpi_unreal_gdt

; 16-bit AP probe stub copied to 0x2000 (SIPI enters at CS:IP = 0x0200:0x0000).
; Records hardware APIC ID under lock and halts.
align 4
ap_probe_stub:
    cli
    cld
    xor     ax, ax
    mov     ds, ax
    lgdt    [SMP_PROBE_BASE + (ap_stub_gdt_desc - ap_probe_stub)]
    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax
    jmp     short .ap_pm
.ap_pm:
    mov     bx, 0x08
    mov     es, bx
    and     eax, ~1
    mov     cr0, eax
    xor     bx, bx
    mov     es, bx                       ; ES limit = 4 GiB, DS = 0

    mov     ecx, 0x1B
    rdmsr
    or      eax, (1 << 11)
    wrmsr
    and     eax, 0xFFFFF000
    test    eax, eax
    jnz     .ap_lapic_ok
    mov     eax, [ds:SMP_PROBE_LAPIC_BASE]
.ap_lapic_ok:
    mov     ebx, [es:eax + 0x20]
    shr     ebx, 24                      ; hardware APIC ID

.ap_lock:
    mov     al, 1
    xchg    al, [ds:SMP_PROBE_LOCK]
    test    al, al
    jz      .ap_locked
    pause
    jmp     .ap_lock

.ap_locked:
    mov     ecx, [ds:SMP_PROBE_COUNT]
    xor     esi, esi
.ap_dedup:
    cmp     esi, ecx
    jae     .ap_append
    cmp     bl, [ds:SMP_PROBE_APIC_IDS + esi]
    je      .ap_unlock
    inc     esi
    jmp     .ap_dedup

.ap_append:
    cmp     ecx, 255
    jae     .ap_unlock
    mov     [ds:SMP_PROBE_APIC_IDS + ecx], bl
    inc     dword [ds:SMP_PROBE_COUNT]

.ap_unlock:
    mov     byte [ds:SMP_PROBE_LOCK], 0
.ap_halt:
    cli
    hlt
    jmp     .ap_halt

align 8
ap_stub_gdt:
    dq 0x0000000000000000
    dq 0x00CF92000000FFFF                ; 0x08: 4 GiB data
ap_stub_gdt_desc:
    dw 15
    dd SMP_PROBE_BASE + (ap_stub_gdt - ap_probe_stub)
ap_probe_stub_end:

; Minimal DSDT template (AML) exposing PCI0 and ISA platform devices
dsdt_template_start:
    db "DSDT"
    dd 0                                 ; length patched at runtime
    db 0                                 ; revision
    db 0                                 ; checksum patched at runtime
    db "IPO   "                          ; OEMID (6)
    db "IPO     "                        ; OEM Table ID (8)
    dd 0                                 ; OEM Revision
    db "IPO "                            ; Creator ID (4)
    dd 0                                 ; Creator Revision

    ; Scope (\_SB_)
    db 0x10                              ; ScopeOp
    db (0x40 | ((dsdt_sb_end - dsdt_sb_start + 2) & 0x0F)), (((dsdt_sb_end - dsdt_sb_start + 2) >> 4) & 0xFF)
dsdt_sb_start:
    db "\_SB_"

    ; PCI0 root complex
    ACPI_AML_DEV "PCI0", 0x030AD041, 0x0CF8, 0x08, -1

    ; Legacy PIC
    ACPI_AML_DEV "PIC_", 0x0000D041, 0x0020, 0x02, 2

    ; ISA DMA controller
    ACPI_AML_DEV "DMA1", 0x0002D041, 0x0000, 0x10, 4

    ; System timer (PIT)
    ACPI_AML_DEV "TMR_", 0x0001D041, 0x0040, 0x04, 0

    ; CMOS / RTC
    ACPI_AML_DEV "RTC_", 0x000BD041, 0x0070, 0x02, 8

    ; PC speaker
    ACPI_AML_DEV "SPKR", 0x0008D041, 0x0061, 0x01, -1

    ; PS/2 keyboard
    ACPI_AML_DEV "PS2K", 0x0303D041, 0x0060, 0x01, 1

    ; PS/2 mouse
    ACPI_AML_DEV "PS2M", 0x130FD041, 0x0064, 0x01, 12

    ; COM1 UART
    ACPI_AML_DEV "COM1", 0x0105D041, 0x03F8, 0x08, 4

dsdt_sb_end:
dsdt_template_end:
