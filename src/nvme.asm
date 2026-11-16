; Real-mode NVMe driver (Admin/IO queue setup and polled DMA reads in FS unreal mode)

BITS 16

%include "boot_constants.inc"

; Initialize NVMe controller and create IO CQ/SQ pair; returns CF=0 on success.
nvme_init:
    pushad
    push    es

    xor     ax, ax
    mov     es, ax

    cmp     byte [es:SCRATCH_NVME_FOUND], 1
    jne     .nvme_fail

    call    enable_unreal_mode

    mov     esi, [es:SCRATCH_NVME_BAR0]
    test    esi, esi
    jz      .nvme_fail

    ; Disable controller (CC.EN = 0) and wait for CSTS.RDY == 0
    a32 mov eax, [fs:esi + 0x14]
    and     eax, ~0x00000001
    a32 mov [fs:esi + 0x14], eax

    mov     ecx, 0x001FFFFF
.wait_reset:
    a32 mov eax, [fs:esi + 0x1C]
    test    al, 0x01
    jz      .controller_reset_ok
    dec     ecx
    jnz     .wait_reset
    jmp     .nvme_fail

.controller_reset_ok:
    ; Zero 16 KiB queue region (0x3000..0x6FFF)
    push    di
    xor     di, di
    mov     ax, 0x3000 / 16
    mov     es, ax
    xor     eax, eax
    mov     cx, 4096
    cld
    rep     stosd
    pop     di

    xor     ax, ax
    mov     es, ax

    ; AQA (+0x24): 16-entry Admin CQ/SQ (ACQS=15, ASQS=15)
    a32 mov dword [fs:esi + 0x24], 0x000F000F

    a32 mov dword [fs:esi + 0x28], NVME_ADMIN_SQ_ADDR
    a32 mov dword [fs:esi + 0x2C], 0x00000000

    a32 mov dword [fs:esi + 0x30], NVME_ADMIN_CQ_ADDR
    a32 mov dword [fs:esi + 0x34], 0x00000000

    ; Enable controller: CC.IOCQES=4 (16 B), CC.IOSQES=6 (64 B), CC.EN=1
    a32 mov dword [fs:esi + 0x14], 0x00460001

    mov     ecx, 0x001FFFFF
.wait_ready:
    a32 mov eax, [fs:esi + 0x1C]
    test    al, 0x01
    jnz     .controller_enabled
    dec     ecx
    jnz     .wait_ready
    jmp     .nvme_fail

.controller_enabled:
    ; Create IO CQ (opcode 0x05, QID=1, QSIZE=15, PC=1) in Admin SQ slot 0
    mov     edi, NVME_ADMIN_SQ_ADDR
    a32 mov dword [fs:edi + 0x00], 0x00000005
    a32 mov dword [fs:edi + 0x04], 0x00000000
    a32 mov dword [fs:edi + 0x18], NVME_IO_CQ_ADDR
    a32 mov dword [fs:edi + 0x28], 0x000F0001
    a32 mov dword [fs:edi + 0x2C], 0x00000001

    a32 mov dword [fs:esi + 0x1000], 1      ; Admin SQ0 tail doorbell

    mov     ecx, 0x001FFFFF
.wait_admin_cq0:
    a32 mov ax, [fs:NVME_ADMIN_CQ_ADDR + 14]
    test    al, 0x01                        ; phase bit
    jnz     .admin_cq0_done
    dec     ecx
    jnz     .wait_admin_cq0
    jmp     .nvme_fail

.admin_cq0_done:
    test    ax, 0xFFFE
    jnz     .nvme_fail
    a32 mov dword [fs:esi + 0x1004], 1      ; Admin CQ0 head doorbell

    ; Create IO SQ (opcode 0x01, QID=1, CQID=1, QSIZE=15, PC=1) in Admin SQ slot 1
    mov     edi, NVME_ADMIN_SQ_ADDR + 64
    a32 mov dword [fs:edi + 0x00], 0x00010001
    a32 mov dword [fs:edi + 0x04], 0x00000000
    a32 mov dword [fs:edi + 0x18], NVME_IO_SQ_ADDR
    a32 mov dword [fs:edi + 0x28], 0x000F0001
    a32 mov dword [fs:edi + 0x2C], 0x00010001

    a32 mov dword [fs:esi + 0x1000], 2

    mov     ecx, 0x001FFFFF
.wait_admin_cq1:
    a32 mov ax, [fs:NVME_ADMIN_CQ_ADDR + 16 + 14]
    test    al, 0x01
    jnz     .admin_cq1_done
    dec     ecx
    jnz     .wait_admin_cq1
    jmp     .nvme_fail

.admin_cq1_done:
    test    ax, 0xFFFE
    jnz     .nvme_fail
    a32 mov dword [fs:esi + 0x1004], 2

    mov     dword [es:SCRATCH_NVME_NSID], 1
    mov     word [es:SCRATCH_NVME_SEC_SIZE], 512
    mov     byte [es:SCRATCH_NVME_SQ_TAIL], 0
    mov     byte [es:SCRATCH_NVME_CQ_HEAD], 0
    mov     byte [es:SCRATCH_NVME_CQ_PHASE], 1

    pop     es
    popad
    clc
    ret

.nvme_fail:
    pop     es
    popad
    stc
    ret


; Read sectors using NVMe IO SQ 1 (opcode 0x02).
; Inputs: EBX=LBA32, CX=count (1..64), ES:DI=dst buffer.
nvme_read_sectors:
    pushad
    push    ds
    push    es

    call    enable_unreal_mode

    mov     ax, es
    movzx   eax, ax
    shl     eax, 4
    movzx   edx, di
    add     eax, edx
    mov     ebp, eax                        ; physical PRP1

    xor     ax, ax
    mov     ds, ax

    mov     esi, [ds:SCRATCH_NVME_BAR0]
    test    esi, esi
    jz      .read_error

    ; Issue 1 sector (512 B) per command to avoid needing a PRP list
.sector_loop:
    push    cx
    push    ebx

    movzx   edx, byte [ds:SCRATCH_NVME_SQ_TAIL]
    mov     edi, edx
    shl     edi, 6
    add     edi, NVME_IO_SQ_ADDR

    a32 mov dword [fs:edi + 0x00], 0x00000002 ; Read (0x02)
    mov     eax, [ds:SCRATCH_NVME_NSID]
    a32 mov dword [fs:edi + 0x04], eax
    a32 mov dword [fs:edi + 0x08], 0
    a32 mov dword [fs:edi + 0x0C], 0
    a32 mov dword [fs:edi + 0x10], 0
    a32 mov dword [fs:edi + 0x14], 0
    a32 mov dword [fs:edi + 0x18], ebp        ; PRP1
    a32 mov dword [fs:edi + 0x1C], 0

    ; PRP2 = next 4 KiB page in case the 512 B buffer straddles a page boundary
    mov     eax, ebp
    add     eax, 0x1000
    and     eax, 0xFFFFF000
    a32 mov dword [fs:edi + 0x20], eax        ; PRP2
    a32 mov dword [fs:edi + 0x24], 0
    a32 mov dword [fs:edi + 0x28], ebx        ; SLBA low
    a32 mov dword [fs:edi + 0x2C], 0
    a32 mov dword [fs:edi + 0x30], 0          ; NLB=0 (1 sector)
    a32 mov dword [fs:edi + 0x34], 0
    a32 mov dword [fs:edi + 0x38], 0
    a32 mov dword [fs:edi + 0x3C], 0

    inc     edx
    and     edx, 0x0F
    mov     [ds:SCRATCH_NVME_SQ_TAIL], dl

    a32 mov dword [fs:esi + 0x1008], edx      ; IO SQ1 tail doorbell

    movzx   ebx, byte [ds:SCRATCH_NVME_CQ_HEAD]
    mov     edi, ebx
    shl     edi, 4
    add     edi, NVME_IO_CQ_ADDR

    mov     bl, [ds:SCRATCH_NVME_CQ_PHASE]
    mov     ecx, 0x001FFFFF
.poll_io_cq:
    a32 mov ax, [fs:edi + 14]
    mov     dl, al
    and     dl, 0x01
    cmp     dl, bl
    je      .cq_completed
    dec     ecx
    jnz     .poll_io_cq
    pop     ebx
    pop     cx
    jmp     .read_error

.cq_completed:
    mov     dx, ax
    and     dx, 0xFFFE                        ; status bits[15:1]

    movzx   eax, byte [ds:SCRATCH_NVME_CQ_HEAD]
    inc     eax
    cmp     eax, 16
    jb      .cq_head_ok
    xor     eax, eax
    xor     byte [ds:SCRATCH_NVME_CQ_PHASE], 1 ; invert phase on wrap

.cq_head_ok:
    mov     [ds:SCRATCH_NVME_CQ_HEAD], al

    a32 mov dword [fs:esi + 0x100C], eax      ; IO CQ1 head doorbell

    test    dx, dx
    pop     ebx
    pop     cx
    jnz     .read_error

    inc     ebx
    add     ebp, 512
    dec     cx
    jnz     .sector_loop

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
