; int13.asm — BIOS Disk Services (INT 13h) implementation
; Features: AH=00h (Reset), AH=41h (Extensions Check), AH=42h (DAP Extended Read)
; Supports ATA/IDE PIO Mode for Drive 0x80 (Master) and 0x81 (Slave)

BITS 16

int13h_handler:
    sti
    cmp     ah, 0x00
    je      .fn_reset
    cmp     ah, 0x41
    je      .fn_extensions_check
    cmp     ah, 0x42
    je      .fn_extended_read
    cmp     ah, 0x08
    je      .fn_get_drive_params

    ; Unsupported function
    mov     ah, 0x01                        ; AH = 0x01 (Invalid function)
    stc
    jmp     .exit

; -----------------------------------------------------------------------------
; AH = 0x00 — Reset Disk System
; -----------------------------------------------------------------------------
.fn_reset:
    xor     ah, ah
    clc
    jmp     .exit

; -----------------------------------------------------------------------------
; AH = 0x41 — Installation Check (Extensions check)
; Input: AH = 0x41, BX = 0x55AA, DL = Drive (0x80..0xFF)
; Output:
;   CF = 0 (Supported), BX = 0xAA55, AH = 0x21 (v1.x), CX = 0x0001 (DAP supported)
; -----------------------------------------------------------------------------
.fn_extensions_check:
    cmp     bx, 0x55AA
    jne     .ext_fail

    mov     bx, 0xAA55                      ; Extension signature
    mov     ah, 0x21                        ; Version 2.1
    mov     al, 0x00
    mov     cx, 0x0001                      ; Subset 1: Extended disk access (42h-44h, 47h, 48h)
    clc
    jmp     .exit

.ext_fail:
    stc
    jmp     .exit

; -----------------------------------------------------------------------------
; AH = 0x08 — Get Drive Parameters
; -----------------------------------------------------------------------------
.fn_get_drive_params:
    mov     ah, 0x00
    mov     ch, 0x00                        ; Cylinders low
    mov     cl, 0x3F                        ; Max sector (63), cylinder high (0)
    mov     dh, 0x0F                        ; Max head (15)
    mov     dl, 0x01                        ; 1 drive attached
    clc
    jmp     .exit

; -----------------------------------------------------------------------------
; AH = 0x42 — Extended Read Sectors from Drive (via DAP)
; Input:
;   AH = 0x42, DL = Drive (0x80..0x83), DS:SI = Pointer to Disk Address Packet
;
; DAP format (16 bytes):
;   offset 0: byte  dap_size (>= 16)
;   offset 1: byte  reserved (0)
;   offset 2: word  sector_count
;   offset 4: word  buffer_offset
;   offset 6: word  buffer_segment
;   offset 8: dword lba_start_low
;   offset 12: dword lba_start_high
; -----------------------------------------------------------------------------
.fn_extended_read:
    push    ds
    push    es
    push    bp
    push    si
    push    di
    push    dx
    push    cx
    push    bx

    ; Validate DAP size
    cmp     byte [ds:si], 16
    jb      .dap_err_param

    ; Read DAP fields
    mov     cx, [ds:si + 2]                 ; Sector count
    test    cx, cx
    jz      .dap_success                    ; 0 sectors = nothing to do

    mov     di, [ds:si + 4]                 ; Buffer offset
    mov     ax, [ds:si + 6]                 ; Buffer segment
    mov     es, ax                          ; ES:DI = destination buffer

    mov     ebx, [ds:si + 8]                ; Starting LBA (low 32 bits)

    ; DL is the drive number (0x80 = Master, 0x81 = Slave)
    ; Determine base I/O port
    mov     bp, ATA_PRI_DATA                ; Default: Primary ATA channel (0x1F0)

.sector_read_loop:
    push    cx                              ; Save remaining sector count

    ; Read single sector at LBA in EBX to ES:DI
    ; NOTE: rep insw automatically advances DI by 512 bytes (256 words * 2)
    call    ata_read_one_sector
    jc      .dap_read_fail

    ; If DI wrapped to 0, advance ES by 64KB (0x1000 paragraphs)
    test    di, di
    jnz     .next_lba
    mov     ax, es
    add     ax, 0x1000
    mov     es, ax

.next_lba:
    inc     ebx                             ; Next LBA

    pop     cx
    loop    .sector_read_loop

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
    ; Keep AH as set by ata_read_one_sector
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
    mov     ah, 0x01                        ; Invalid parameter
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
; ATA PIO Single Sector Reader
; Inputs:
;   EBX = LBA28
;   DL  = Drive (0x80=Master, 0x81=Slave)
;   ES:DI = Destination buffer (512 bytes)
; Output: CF = 0 on success, CF = 1 on error
; =============================================================================
ata_read_one_sector:
    push    ebx                             ; Save original 32-bit LBA
    push    dx
    push    ax
    push    cx

    ; 1. Wait until drive is not busy (BSY=0)
    mov     dx, ATA_PRI_STATUS
    call    ata_wait_not_busy
    jc      .ata_err_1

    ; 2. Select Drive and top 4 bits of LBA
    ; Format: 0xE0 | ((drive & 1) << 4) | (LBA[27:24] & 0x0F)
    mov     eax, ebx
    shr     eax, 24
    and     al, 0x0F
    mov     ah, 0xE0                        ; Master (0xE0)
    test    byte [esp + 4], 0x01            ; Test original drive passed in DL on stack
    jz      .drive_select_ok
    mov     ah, 0xF0                        ; Slave (0xF0)
.drive_select_ok:
    or      al, ah
    mov     dx, ATA_PRI_DRIVE_HEAD
    out     dx, al

    ; 3. Small delay (400ns) by reading alternate status
    mov     dx, ATA_PRI_CTRL
    in      al, dx
    in      al, dx
    in      al, dx
    in      al, dx

    ; 4. Wait for BSY to clear and DRDY to set
    mov     dx, ATA_PRI_STATUS
    call    ata_wait_ready
    jc      .ata_err_4

    ; 5. Set Sector Count = 1
    mov     dx, ATA_PRI_SEC_CNT
    mov     al, 1
    out     dx, al

    ; 6. Set LBA low, mid, high from original EBX
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

    ; 7. Issue Command: 0x20 (READ SECTORS)
    mov     dx, ATA_PRI_STATUS
    mov     al, 0x20
    out     dx, al

    ; 8. Wait for Data Request (DRQ=1)
    call    ata_wait_drq
    jc      .ata_err_8

    ; 9. Transfer 256 words (512 bytes) from Data port (0x1F0) to ES:DI
    mov     dx, ATA_PRI_DATA
    mov     cx, 256
    cld
    rep     insw

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
    pop     cx
    pop     dx                          ; Discard saved AX
    pop     dx                          ; Restore saved DX
    pop     ebx                         ; Restore saved EBX
    mov     ah, al                      ; Restore error code in AH
    stc
    ret

ata_wait_not_busy:
    mov     cx, 0xFFFF
.loop_bsy:
    in      al, dx
    test    al, 0x80                        ; BSY bit
    jz      .ready
    loop    .loop_bsy
    stc
    ret
.ready:
    clc
    ret

ata_wait_ready:
    mov     cx, 0xFFFF
.loop_rdy:
    in      al, dx
    test    al, 0x80                        ; BSY bit
    jnz     .next_rdy
    test    al, 0x40                        ; DRDY bit
    jnz     .rdy_ok
.next_rdy:
    loop    .loop_rdy
    stc
    ret
.rdy_ok:
    clc
    ret

ata_wait_drq:
    mov     cx, 0xFFFF
.loop_drq:
    in      al, dx
    test    al, 0x80                        ; BSY bit
    jnz     .next_drq
    test    al, 0x01                        ; ERR bit
    jnz     .drq_err
    test    al, 0x08                        ; DRQ bit
    jnz     .drq_ok
.next_drq:
    loop    .loop_drq
.drq_err:
    stc
    ret
.drq_ok:
    clc
    ret
