; INT 13h disk services (ATA PIO, SATA AHCI, NVMe, USB BOT)

BITS 16

int13h_handler:
    sti
    cmp     ah, 0x00
    je      .fn_reset
    cmp     ah, 0x02
    je      .fn_chs_read
    cmp     ah, 0x41
    je      .fn_extensions_check
    cmp     ah, 0x42
    je      .fn_extended_read
    cmp     ah, 0x08
    je      .fn_get_drive_params

    mov     ah, 0x01                        ; invalid function
    stc
    jmp     .exit

; AH=00h: reset disk
.fn_reset:
    xor     ah, ah
    clc
    jmp     .exit

; AH=41h: extensions check (BX=0x55AA -> BX=0xAA55, CX=1 DAP)
.fn_extensions_check:
    cmp     bx, 0x55AA
    jne     .ext_fail

    mov     bx, 0xAA55
    xor     ax, ax
    mov     cx, 0x0001                      ; extended disk access subset
    clc
    jmp     .exit

.ext_fail:
    stc
    jmp     .exit

; AH=08h: get drive geometry
.fn_get_drive_params:
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     dl, [ds:0x0475]                 ; BDA disk count
    pop     ds
    test    dl, dl
    jnz     .drives_ok
    mov     dl, 1
.drives_ok:
    xor     ah, ah
    mov     ch, 0xFF                        ; max cyl low (1023)
    mov     cl, 0xFF                        ; 63 sectors | cyl[9:8]
    mov     dh, 15                          ; 16 heads (0..15)
    clc
    jmp     .exit

; AH=02h: CHS sector read
; Input: AL=count (1..128), CH=cyl_lo, CL=sec[5:0]|cyl_hi[7:6], DH=head, DL=drv, ES:BX=buf
; Output: CF=0 AH=0 AL=sectors read, or CF=1 AH=err
.fn_chs_read:
    push    ds
    push    es
    push    bp
    push    si
    push    di
    push    dx
    push    cx
    push    bx

    mov     di, bx

    ; LBA = (cyl * 16 + head) * 63 + (sec - 1)
    push    ax
    movzx   eax, ch
    movzx   ebx, cl
    shr     ebx, 6
    shl     ebx, 8
    or      eax, ebx

    shl     eax, 4
    movzx   edx, dh
    add     eax, edx

    mov     edx, eax
    shl     eax, 6
    sub     eax, edx

    movzx   edx, cl
    and     edx, 0x3F
    dec     edx
    add     eax, edx

    mov     ebx, eax
    pop     ax
    movzx   cx, al

    ; Original DL sits in saved DX at [sp + 4]
    mov     bp, sp
    mov     dl, [bp + 4]

    push    ds
    xor     ax, ax
    mov     ds, ax
    movzx   bp, dl
    and     bp, 0x03
    mov     al, [ds:SCRATCH_DRV_TYPE_80 + bp]
    pop     ds

    cmp     al, DRV_TYPE_SATA_AHCI
    je      .chs_via_ahci
    cmp     al, DRV_TYPE_NVME
    je      .chs_via_nvme
    cmp     al, DRV_TYPE_USB_BOT
    je      .chs_via_usb

    mov     bp, ATA_PRI_DATA
.chs_ata_loop:
    push    cx
    call    ata_read_one_sector
    jc      .chs_fail
    test    di, di
    jnz     .chs_next_lba
    mov     ax, es
    add     ax, 0x1000
    mov     es, ax
.chs_next_lba:
    inc     ebx
    pop     cx
    loop    .chs_ata_loop
    jmp     .chs_ok

.chs_via_ahci:
    call    ahci_read_sectors
    jc      .chs_fail_simple
    jmp     .chs_ok

.chs_via_nvme:
    call    nvme_read_sectors
    jc      .chs_fail_simple
    jmp     .chs_ok

.chs_via_usb:
    call    usb_read_sectors
    jc      .chs_fail_simple
    jmp     .chs_ok

.chs_fail:
    pop     cx
.chs_fail_simple:
    pop     bx
    pop     cx
    pop     dx
    pop     di
    pop     si
    pop     bp
    pop     es
    pop     ds
    xor     al, al
    mov     ah, 0x04
    stc
    jmp     .exit

.chs_ok:
    pop     bx
    pop     cx
    mov     al, cl
    pop     dx
    pop     di
    pop     si
    pop     bp
    pop     es
    pop     ds
    xor     ah, ah
    clc
    jmp     .exit

; AH=42h: extended read using DAP (DL=drive, DS:SI=DAP)
.fn_extended_read:
    push    ds
    push    es
    push    bp
    push    si
    push    di
    push    dx
    push    cx
    push    bx

    cmp     byte [ds:si], 16
    jb      .dap_err_param

    mov     cx, [ds:si + 2]
    test    cx, cx
    jz      .dap_success

    mov     di, [ds:si + 4]
    mov     ax, [ds:si + 6]
    mov     es, ax

    mov     ebx, [ds:si + 8]                ; starting LBA[31:0]

    push    ds
    xor     ax, ax
    mov     ds, ax
    movzx   bp, dl
    and     bp, 0x03
    mov     al, [ds:SCRATCH_DRV_TYPE_80 + bp]
    pop     ds

    cmp     al, DRV_TYPE_SATA_AHCI
    je      .read_via_ahci

    cmp     al, DRV_TYPE_NVME
    je      .read_via_nvme

    cmp     al, DRV_TYPE_USB_BOT
    je      .read_via_usb

    mov     bp, ATA_PRI_DATA                ; primary ATA channel (0x1F0)

.sector_read_loop:
    push    cx

    ; rep insw advances DI by 512 B
    call    ata_read_one_sector
    jc      .dap_read_fail

    ; Advance ES by 64 KiB (0x1000 paragraphs) when DI wraps
    test    di, di
    jnz     .next_lba
    mov     ax, es
    add     ax, 0x1000
    mov     es, ax

.next_lba:
    inc     ebx

    pop     cx
    loop    .sector_read_loop
    jmp     .dap_success

.read_via_ahci:
    call    ahci_read_sectors
    jc      .dap_read_fail_simple
    jmp     .dap_success

.read_via_nvme:
    call    nvme_read_sectors
    jc      .dap_read_fail_simple
    jmp     .dap_success

.read_via_usb:
.usb_loop:
    push    cx
    mov     cx, 1
    call    usb_read_sectors
    jc      .usb_fail
    inc     ebx
    add     di, 512
    jnc     .usb_no_wrap
    mov     ax, es
    add     ax, 0x1000
    mov     es, ax
.usb_no_wrap:
    pop     cx
    loop    .usb_loop
    jmp     .dap_success

.usb_fail:
    pop     cx
    jmp     .dap_read_fail_simple

.dap_read_fail_simple:
    pop     bx
    pop     cx
    pop     dx
    pop     di
    pop     si
    pop     bp
    pop     es
    pop     ds
    mov     ah, 0x04
    stc
    jmp     .exit

.dap_success:
    pop     bx
    pop     cx
    pop     dx
    pop     di
    pop     si
    pop     bp
    pop     es
    pop     ds
    xor     ah, ah
    clc
    jmp     .exit

.dap_read_fail:
    pop     cx
    pop     bx
    pop     cx
    pop     dx
    pop     di
    pop     si
    pop     bp
    pop     es
    pop     ds
    ; preserve AH from ata_read_one_sector
    stc
    jmp     .exit

.dap_err_param:
    pop     bx
    pop     cx
    pop     dx
    pop     di
    pop     si
    pop     bp
    pop     es
    pop     ds
    mov     ah, 0x01
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

; Read one LBA28 sector using primary ATA PIO.
; Inputs: EBX=LBA28, DL=drive (0x80 master / 0x81 slave), ES:DI=512 B buffer.
ata_read_one_sector:
    push    ebx
    push    dx
    push    ax
    push    cx
    push    bp
    mov     bp, sp

    mov     dx, ATA_PRI_STATUS
    call    ata_wait_not_busy
    jc      .ata_err_1

    ; Drive/Head: 0xE0 | ((drive & 1) << 4) | LBA[27:24]
    mov     eax, ebx
    shr     eax, 24
    and     al, 0x0F
    mov     ah, 0xE0
    test    byte [bp + 6], 0x01             ; saved DL on stack
    jz      .drive_select_ok
    mov     ah, 0xF0
.drive_select_ok:
    or      al, ah
    mov     dx, ATA_PRI_DRIVE_HEAD
    out     dx, al

    ; 400 ns settle delay after drive select
    mov     dx, ATA_PRI_CTRL
    in      al, dx
    in      al, dx
    in      al, dx
    in      al, dx

    mov     dx, ATA_PRI_STATUS
    call    ata_wait_ready
    jc      .ata_err_4

    mov     dx, ATA_PRI_SEC_CNT
    mov     al, 1
    out     dx, al

    mov     dx, ATA_PRI_LBA_LO
    mov     al, bl
    out     dx, al

    mov     dx, ATA_PRI_LBA_MID
    mov     al, bh
    out     dx, al

    mov     dx, ATA_PRI_LBA_HI
    shr     ebx, 16
    mov     al, bl
    out     dx, al

    mov     dx, ATA_PRI_STATUS
    mov     al, 0x20                        ; READ SECTORS
    out     dx, al

    call    ata_wait_drq
    jc      .ata_err_8

    mov     dx, ATA_PRI_DATA
    mov     cx, 256
    cld
    rep     insw

    pop     bp
    pop     cx
    pop     ax
    pop     dx
    pop     ebx
    clc
    ret

.ata_err_1:
    mov     ah, 0x11
    jmp     .ata_err
.ata_err_4:
    mov     ah, 0x14
    jmp     .ata_err
.ata_err_8:
    mov     ah, 0x18
    jmp     .ata_err

.ata_err:
    mov     al, ah
    pop     bp
    pop     cx
    pop     dx                              ; drop saved AX
    pop     dx
    pop     ebx
    mov     ah, al
    stc
    ret

ata_wait_not_busy:
    push    cx
    mov     cx, 0xFFFF
.loop_bsy:
    in      al, dx
    test    al, 0x80                        ; BSY
    jz      .not_busy_ok
    loop    .loop_bsy
    pop     cx
    stc
    ret
.not_busy_ok:
    pop     cx
    clc
    ret

ata_wait_ready:
    push    ebx
    push    ecx
    push    es

    ; Short poll (~100 ms) for SSD/CF/already-spun-up drives
    mov     cx, 0x8000
.fast_loop:
    in      al, dx
    test    al, 0x80                        ; BSY
    jnz     .fast_next
    test    al, 0x40                        ; DRDY
    jnz     .rdy_ok
.fast_next:
    dec     cx
    jnz     .fast_loop

    ; Only enter long spin-up wait if BSY is set (ignore 0x00/0xFF floating bus)
    cmp     al, 0xFF
    je      .timeout_early
    test    al, 0x80
    jnz     .spinup_wait
.timeout_early:
    pop     es
    pop     ecx
    pop     ebx
    stc
    ret

.spinup_wait:
    ; Wait up to ~15 s (273 ticks at 18.2 Hz) for mechanical HDD spin-up
    mov     al, POST_DISK_SPINUP_WAIT
    out     POST_PORT, al

    sti
    xor     ax, ax
    mov     es, ax
    mov     ebx, [es:0x046C]
    add     ebx, 273

    mov     ecx, 5000000                    ; fallback loop guard if PIT halted

.spinup_loop:
    in      al, dx
    test    al, 0x80
    jnz     .check_deadline
    test    al, 0x40
    jnz     .rdy_ok

.check_deadline:
    push    eax
    mov     eax, [es:0x046C]
    cmp     eax, ebx
    pop     eax
    jae     .timeout

    dec     ecx
    jnz     .spinup_loop

.timeout:
    pop     es
    pop     ecx
    pop     ebx
    stc
    ret

.rdy_ok:
    pop     es
    pop     ecx
    pop     ebx
    clc
    ret

ata_wait_drq:
    mov     cx, 0xFFFF
.loop_drq:
    in      al, dx
    test    al, 0x80                        ; BSY
    jnz     .next_drq
    test    al, 0x01                        ; ERR
    jnz     .drq_err
    test    al, 0x08                        ; DRQ
    jnz     .drq_ok
.next_drq:
    loop    .loop_drq
.drq_err:
    stc
    ret
.drq_ok:
    clc
    ret
