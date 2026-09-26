; nvme.asm — NVMe (NVM Express) Storage Driver for x86 BIOS
; Implements controller init, Admin/IO queue setup, and sector reading via DMA.
; Uses Flat Real Mode (Unreal Mode with FS descriptor limit = 4GB) to access MMIO.

BITS 16

%include "contract.inc"

; =============================================================================
; nvme_init — Initialize NVMe Controller discovered by PCI scan
; Returns: CF = 0 on success (drive ready), CF = 1 if no NVMe drive found
; =============================================================================
nvme_init:
    pushad
    push    es

    xor     ax, ax
    mov     es, ax                          ; ES = 0x0000 (Scratch RAM)

    ; Check if NVMe was discovered by PCI scan
    cmp     byte [es:SCRATCH_NVME_FOUND], 1
    jne     .nvme_fail

    ; Enable 4GB access via FS
    call    ahci_enable_unreal_mode

    mov     esi, [es:SCRATCH_NVME_BAR0]     ; ESI = NVMe MMIO Base Address
    test    esi, esi
    jz      .nvme_fail

    ; -------------------------------------------------------------------------
    ; 1. Reset Controller: CC.EN = 0, wait for CSTS.RDY == 0
    ; -------------------------------------------------------------------------
    a32 mov eax, [fs:esi + 0x14]            ; Read CC (offset 0x14)
    and     eax, ~0x00000001                ; Clear bit 0 (EN = 0)
    a32 mov [fs:esi + 0x14], eax

    mov     cx, 0xFFFF
.wait_reset:
    a32 mov eax, [fs:esi + 0x1C]            ; Read CSTS (offset 0x1C)
    test    al, 0x01                        ; RDY bit
    jz      .controller_reset_ok
    dec     cx
    jnz     .wait_reset
    jmp     .nvme_fail

.controller_reset_ok:
    ; -------------------------------------------------------------------------
    ; 2. Zero 16KB Queue Memory (0x3000 - 0x6FFF)
    ; -------------------------------------------------------------------------
    push    di
    xor     di, di
    mov     ax, 0x3000 / 16                 ; Segment 0x0300
    mov     es, ax
    xor     eax, eax
    mov     cx, 4096                        ; 4096 dwords = 16 KB
    cld
    rep     stosd
    pop     di

    xor     ax, ax
    mov     es, ax                          ; Restore ES = 0x0000

    ; -------------------------------------------------------------------------
    ; 3. Program Admin Queue Attributes (AQA) and Addresses (ASQ, ACQ)
    ; -------------------------------------------------------------------------
    ; AQA (offset 0x24): ACQS (bits 27:16) = 15, ASQS (bits 11:0) = 15 (16 entries each)
    a32 mov dword [fs:esi + 0x24], 0x000F000F

    ; ASQ (offset 0x28): 64-bit base address = 0x3000
    a32 mov dword [fs:esi + 0x28], NVME_ADMIN_SQ_ADDR
    a32 mov dword [fs:esi + 0x2C], 0x00000000

    ; ACQ (offset 0x30): 64-bit base address = 0x4000
    a32 mov dword [fs:esi + 0x30], NVME_ADMIN_CQ_ADDR
    a32 mov dword [fs:esi + 0x34], 0x00000000

    ; -------------------------------------------------------------------------
    ; 4. Enable Controller: CC.IOCQES=4 (16B), CC.IOSQES=6 (64B), CC.EN=1
    ;    CC value = 0x00460001
    ; -------------------------------------------------------------------------
    a32 mov dword [fs:esi + 0x14], 0x00460001

    ; Wait for CSTS.RDY == 1
    mov     cx, 0xFFFF
.wait_ready:
    a32 mov eax, [fs:esi + 0x1C]
    test    al, 0x01
    jnz     .controller_enabled
    dec     cx
    jnz     .wait_ready
    jmp     .nvme_fail

.controller_enabled:
    ; -------------------------------------------------------------------------
    ; 5. Create I/O Completion Queue (Admin Opcode 0x05)
    ;    Slot 0 in Admin SQ (0x3000)
    ; -------------------------------------------------------------------------
    mov     edi, NVME_ADMIN_SQ_ADDR
    a32 mov dword [fs:edi + 0x00], 0x00000005 ; CDW0: Opcode 0x05 (Create IO CQ), CID=0
    a32 mov dword [fs:edi + 0x04], 0x00000000 ; CDW1: NSID=0
    a32 mov dword [fs:edi + 0x18], NVME_IO_CQ_ADDR ; CDW6 (PRP1): 0x6000
    a32 mov dword [fs:edi + 0x28], 0x0001000F ; CDW10: QSIZE=15 (16 entries), QID=1
    a32 mov dword [fs:edi + 0x2C], 0x00000001 ; CDW11: Physically Contiguous (PC=1)

    ; Ring Admin SQ Tail Doorbell (offset 0x1000) = 1
    a32 mov dword [fs:esi + 0x1000], 1

    ; Poll Admin CQ Slot 0 (offset 0x4000) for Phase bit 1 at byte offset 15
    mov     cx, 0xFFFF
.wait_admin_cq0:
    a32 mov al, [fs:NVME_ADMIN_CQ_ADDR + 14]  ; Status / Phase byte
    test    al, 0x01                         ; Phase tag bit 0
    jnz     .admin_cq0_done
    dec     cx
    jnz     .wait_admin_cq0
    jmp     .nvme_fail

.admin_cq0_done:
    ; Ring Admin CQ Head Doorbell (offset 0x1004) = 1
    a32 mov dword [fs:esi + 0x1004], 1

    ; -------------------------------------------------------------------------
    ; 6. Create I/O Submission Queue (Admin Opcode 0x01)
    ;    Slot 1 in Admin SQ (0x3000 + 64 = 0x3040)
    ; -------------------------------------------------------------------------
    mov     edi, NVME_ADMIN_SQ_ADDR + 64
    a32 mov dword [fs:edi + 0x00], 0x00010001 ; CDW0: Opcode 0x01 (Create IO SQ), CID=1
    a32 mov dword [fs:edi + 0x04], 0x00000000 ; CDW1: NSID=0
    a32 mov dword [fs:edi + 0x18], NVME_IO_SQ_ADDR ; CDW6 (PRP1): 0x5000
    a32 mov dword [fs:edi + 0x28], 0x0001000F ; CDW10: QSIZE=15 (16 entries), QID=1
    a32 mov dword [fs:edi + 0x2C], 0x00010001 ; CDW11: CQID=1, PC=1

    ; Ring Admin SQ Tail Doorbell (offset 0x1000) = 2
    a32 mov dword [fs:esi + 0x1000], 2

    ; Poll Admin CQ Slot 1 (offset 0x4010) for Phase bit 1
    mov     cx, 0xFFFF
.wait_admin_cq1:
    a32 mov al, [fs:NVME_ADMIN_CQ_ADDR + 16 + 14]
    test    al, 0x01
    jnz     .admin_cq1_done
    dec     cx
    jnz     .wait_admin_cq1
    jmp     .nvme_fail

.admin_cq1_done:
    ; Ring Admin CQ Head Doorbell (offset 0x1004) = 2
    a32 mov dword [fs:esi + 0x1004], 2

    ; -------------------------------------------------------------------------
    ; 7. Save NVMe device parameters in Scratch RAM
    ; -------------------------------------------------------------------------
    mov     dword [es:SCRATCH_NVME_NSID], 1       ; Primary Namespace 1
    mov     word [es:SCRATCH_NVME_SEC_SIZE], 512  ; 512-byte logical sectors
    mov     byte [es:SCRATCH_NVME_SQ_TAIL], 0
    mov     byte [es:SCRATCH_NVME_CQ_HEAD], 0
    mov     byte [es:SCRATCH_NVME_CQ_PHASE], 1    ; Expected phase bit starts at 1

    pop     es
    popad
    clc
    ret

.nvme_fail:
    pop     es
    popad
    stc
    ret


; =============================================================================
; nvme_read_sectors — Read Sectors via NVMe I/O Queue (Opcode 0x02: Read)
; Inputs:
;   EBX   = Starting LBA (32-bit)
;   CX    = Sector count (1..64)
;   ES:DI = Destination buffer
; Returns:
;   CF = 0 on success, CF = 1 on error
; =============================================================================
nvme_read_sectors:
    pushad
    push    ds
    push    es

    ; Save destination ES:DI for DMA linear address computation
    mov     ax, es
    movzx   eax, ax
    shl     eax, 4
    movzx   edx, di
    add     eax, edx                        ; EAX = Physical Linear Target Address
    mov     ebp, eax                        ; EBP = Target Buffer PRP1

    xor     ax, ax
    mov     ds, ax                          ; DS = 0x0000 (Scratch RAM)

    mov     esi, [ds:SCRATCH_NVME_BAR0]     ; ESI = MMIO Base
    test    esi, esi
    jz      .read_error

    ; Get current IO SQ Tail (0..15)
    movzx   edx, byte [ds:SCRATCH_NVME_SQ_TAIL]
    mov     edi, edx
    shl     edi, 6                          ; edi = tail * 64
    add     edi, NVME_IO_SQ_ADDR            ; EDI = slot address in IO SQ

    ; Construct NVM Read Command (Opcode 0x02)
    a32 mov dword [fs:edi + 0x00], 0x00000002 ; CDW0: Opcode 0x02 (Read)
    mov     eax, [ds:SCRATCH_NVME_NSID]
    a32 mov dword [fs:edi + 0x04], eax        ; CDW1: NSID = 1
    a32 mov dword [fs:edi + 0x08], 0          ; CDW2
    a32 mov dword [fs:edi + 0x0C], 0          ; CDW3
    a32 mov dword [fs:edi + 0x10], 0          ; CDW4
    a32 mov dword [fs:edi + 0x14], 0          ; CDW5
    a32 mov dword [fs:edi + 0x18], ebp        ; CDW6 (PRP1): Target Address
    a32 mov dword [fs:edi + 0x1C], 0          ; CDW7 (PRP1 high)
    a32 mov dword [fs:edi + 0x20], 0          ; CDW8 (PRP2)
    a32 mov dword [fs:edi + 0x24], 0          ; CDW9 (PRP2 high)
    a32 mov dword [fs:edi + 0x28], ebx        ; CDW10: Starting LBA low 32 bits
    a32 mov dword [fs:edi + 0x2C], 0          ; CDW11: Starting LBA high 32 bits
    movzx   eax, cx
    dec     eax                             ; Number of blocks - 1 (0-based)
    and     eax, 0xFFFF
    a32 mov dword [fs:edi + 0x30], eax        ; CDW12: NLB (count - 1)
    a32 mov dword [fs:edi + 0x34], 0          ; CDW13
    a32 mov dword [fs:edi + 0x38], 0          ; CDW14
    a32 mov dword [fs:edi + 0x3C], 0          ; CDW15

    ; Advance SQ Tail (modulo 16)
    inc     edx
    and     edx, 0x0F
    mov     [ds:SCRATCH_NVME_SQ_TAIL], dl

    ; Ring IO SQ 1 Tail Doorbell (offset 0x1008)
    a32 mov dword [fs:esi + 0x1008], edx

    ; Poll IO CQ 1 Head (0..15) for completion
    movzx   ebx, byte [ds:SCRATCH_NVME_CQ_HEAD]
    mov     edi, ebx
    shl     edi, 4                          ; edi = head * 16
    add     edi, NVME_IO_CQ_ADDR            ; EDI = slot address in IO CQ

    mov     bl, [ds:SCRATCH_NVME_CQ_PHASE]  ; Expected phase bit
    mov     cx, 0xFFFF
.poll_io_cq:
    a32 mov al, [fs:edi + 14]               ; Status / Phase byte at offset +14
    and     al, 0x01                        ; Phase bit
    cmp     al, bl
    je      .cq_completed
    dec     cx
    jnz     .poll_io_cq
    jmp     .read_error

.cq_completed:
    ; Advance CQ Head (modulo 16)
    movzx   eax, byte [ds:SCRATCH_NVME_CQ_HEAD]
    inc     eax
    cmp     eax, 16
    jb      .cq_head_ok
    xor     eax, eax
    ; Flip phase bit on wrap
    xor     byte [ds:SCRATCH_NVME_CQ_PHASE], 1

.cq_head_ok:
    mov     [ds:SCRATCH_NVME_CQ_HEAD], al

    ; Ring IO CQ 1 Head Doorbell (offset 0x100C)
    a32 mov dword [fs:esi + 0x100C], eax

    pop     es
    pop     ds
    popad
    clc
    ret

.read_error:
    pop     es
    pop     ds
    popad
    stc
    ret
