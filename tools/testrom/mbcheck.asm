; Multiboot 動作確認用 ROM (fasmarm)
;
; 画面 (Mode 3 ビットマップ) に次を表示する:
;   y=  0.. 15 : 8 本のカラーバー (表示の確認)
;   y= 24.. 35 : 白い四角 × ブートモード値 (0xC4 に BIOS が書く値。Normal mode なら 2 個)
;   y= 44.. 53 : 16 個の四角 = 本体 (0xE0 以降) の 32bit 和の下位 16bit (黄=1 / 暗=0)。build.py が期待パターンを表示する
;   y=100..111 : 10 個の四角 = A, B, Select, Start, →, ←, ↑, ↓, R, L を押すと緑になる
;   y=130..137 : 左右に動くマーカー (プログラムが動き続けている確認)
;
; ビルド: python3 build.py  (fasmarm で組み立て → ヘッダチェックサム付与 → 16 バイト境界へパディング)

format binary as 'gba'
org 0x02000000          ; Multiboot イメージは EWRAM 先頭で動く
code32

VRAM     = 0x06000000
IO_BASE  = 0x04000000

rom_start:
        b       main                    ; 0x00 カートリッジ起動時のエントリ
        ; 0x04 Nintendo ロゴ (156 バイト)
        db 0x24,0xFF,0xAE,0x51,0x69,0x9A,0xA2,0x21,0x3D,0x84,0x82,0x0A,0x84,0xE4,0x09,0xAD
        db 0x11,0x24,0x8B,0x98,0xC0,0x81,0x7F,0x21,0xA3,0x52,0xBE,0x19,0x93,0x09,0xCE,0x20
        db 0x10,0x46,0x4A,0x4A,0xF8,0x27,0x31,0xEC,0x58,0xC7,0xE8,0x33,0x82,0xE3,0xCE,0xBF
        db 0x85,0xF4,0xDF,0x94,0xCE,0x4B,0x09,0xC1,0x94,0x56,0x8A,0xC0,0x13,0x72,0xA7,0xFC
        db 0x9F,0x84,0x4D,0x73,0xA3,0xCA,0x9A,0x61,0x58,0x97,0xA3,0x27,0xFC,0x03,0x98,0x76
        db 0x23,0x1D,0xC7,0x61,0x03,0x04,0xAE,0x56,0xBF,0x38,0x84,0x00,0x40,0xA7,0x0E,0xFD
        db 0xFF,0x52,0xFE,0x03,0x6F,0x95,0x30,0xF1,0x97,0xFB,0xC0,0x85,0x60,0xD6,0x80,0x25
        db 0xA9,0x63,0xBE,0x03,0x01,0x4E,0x38,0xE2,0xF9,0xA2,0x34,0xFF,0xBB,0x3E,0x03,0x44
        db 0x78,0x00,0x90,0xCB,0x88,0x11,0x3A,0x94,0x65,0xC0,0x7C,0x63,0x87,0xF0,0x3C,0xAF
        db 0xD6,0x25,0xE4,0x8B,0x38,0x0A,0xAC,0x72,0x21,0xD4,0xF8,0x07
        db 'MBCHECK     '                ; 0xA0 タイトル (12)
        db 'MBCK'                        ; 0xAC ゲームコード
        db '01'                          ; 0xB0 メーカーコード
        db 0x96                          ; 0xB2 固定値
        db 0x00                          ; 0xB3 ユニットコード
        db 0x00                          ; 0xB4 デバイスタイプ
        db 0,0,0,0,0,0,0                 ; 0xB5 予約
        db 0x00                          ; 0xBC バージョン
        db 0x00                          ; 0xBD ヘッダチェックサム (build.py が書く)
        db 0,0                           ; 0xBE 予約
        ; ---- 0xC0: Multiboot 拡張ヘッダ ----
        b       main                    ; 0xC0 Multiboot エントリ
        db 0                            ; 0xC4 ブートモード (BIOS が書く: 1=JoyBus 2=Normal 3=MultiPlay)
        db 0                            ; 0xC5 スレーブ ID (BIOS が書く)
        times 26 db 0                   ; 0xC6..0xDF 予約
        b       main                    ; 0xE0 JoyBus エントリ

; ---------------------------------------------------------------------------
main:
        ldr     sp, [stack_top]
        ; DISPCNT = Mode 3 | BG2
        mov     r0, IO_BASE
        mov     r1, 0x400
        orr     r1, r1, 3
        strh    r1, [r0]

        ; 背景を塗る (19200 ワード)
        mov     r0, VRAM
        ldr     r1, [col_bg]
        orr     r1, r1, r1, lsl 16
        mov     r2, 19200
.fill:  str     r1, [r0], 4
        subs    r2, r2, 1
        bne     .fill

        ; カラーバー: 8 本 × 30px, y=0..15
        mov     r11, 0
.bars:  mov     r0, 30
        mul     r0, r11, r0             ; x = i*30
        mov     r1, 0
        mov     r2, 30
        mov     r3, 16
        adr     r4, bar_colors
        add     r4, r4, r11, lsl 1
        ldrh    r4, [r4]
        bl      fill_rect
        add     r11, r11, 1
        cmp     r11, 8
        blt     .bars

        ; ブートモード: 0x020000C4 の値ぶん白い四角
        mov     r0, 0x02000000
        ldrb    r12, [r0, 0xC4]
        cmp     r12, 8
        movhi   r12, 8
        mov     r11, 0
.boot:  cmp     r11, r12
        bge     .boot_done
        mov     r0, 8
        add     r0, r0, r11, lsl 4      ; x = 8 + i*16
        mov     r1, 24
        mov     r2, 12
        mov     r3, 12
        ldr     r4, [col_white]
        bl      fill_rect
        add     r11, r11, 1
        b       .boot
.boot_done:

        ; 本体チェックサム: 0xE0 .. rom_end の 32bit 和
        mov     r5, 0
        mov     r6, 0x02000000
        add     r6, r6, 0xE0
        ldr     r7, [rom_end_addr]
.sum:   ldr     r8, [r6], 4
        add     r5, r5, r8
        cmp     r6, r7
        blo     .sum
        ; 下位 16bit を 16 個の四角で表示 (bit0 が左)
        mov     r11, 0
.bits:  mov     r0, 8
        add     r0, r0, r11, lsl 3
        add     r0, r0, r11, lsl 2      ; x = 8 + i*12
        mov     r1, 44
        mov     r2, 10
        mov     r3, 10
        mov     r4, 1
        tst     r5, r4, lsl r11
        ldrne   r4, [col_yellow]
        ldreq   r4, [col_dim]
        bl      fill_rect
        add     r11, r11, 1
        cmp     r11, 16
        blt     .bits

        mov     r10, 0                  ; フレームカウンタ
loop:
        ; VBlank 待ち (VCOUNT == 160 になるまで)
        mov     r0, IO_BASE
.vb1:   ldrh    r1, [r0, 6]
        cmp     r1, 160
        bne     .vb1

        ; キー入力 (active low) KEYINPUT = 0x04000130
        add     r1, r0, 0x130
        ldrh    r9, [r1]
        mov     r11, 0
.keys:  mov     r0, 8
        add     r0, r0, r11, lsl 4      ; x = 8 + i*16
        mov     r1, 100
        mov     r2, 12
        mov     r3, 12
        mov     r4, 1
        tst     r9, r4, lsl r11
        ldreq   r4, [col_green]         ; bit=0 → 押されている
        ldrne   r4, [col_dim]
        bl      fill_rect
        add     r11, r11, 1
        cmp     r11, 10
        blt     .keys

        ; 動くマーカー (y=130..137): 前回位置を消して新しい位置に描く
        and     r0, r10, 0xFF           ; 0..255
        cmp     r0, 232
        movhs   r0, 232
        mov     r1, 130
        mov     r2, 8
        mov     r3, 8
        ldr     r4, [col_bg]
        bl      fill_rect
        add     r10, r10, 1
        and     r0, r10, 0xFF
        cmp     r0, 232
        movhs   r0, 232
        mov     r1, 130
        mov     r2, 8
        mov     r3, 8
        ldr     r4, [col_cyan]
        bl      fill_rect

        ; VBlank 終了待ち
        mov     r0, IO_BASE
.vb2:   ldrh    r1, [r0, 6]
        cmp     r1, 160
        beq     .vb2
        b       loop

; ---------------------------------------------------------------------------
; fill_rect: r0=x r1=y r2=w r3=h r4=color(15bit)
fill_rect:
        stmfd   sp!, {r5-r8, lr}
        mov     r5, 240
        mul     r6, r1, r5
        add     r6, r6, r0
        mov     r6, r6, lsl 1
        add     r6, r6, VRAM
        mov     r5, 480
.row:   mov     r7, r6
        mov     r8, r2
.px:    strh    r4, [r7], 2
        subs    r8, r8, 1
        bne     .px
        add     r6, r6, r5
        subs    r3, r3, 1
        bne     .row
        ldmfd   sp!, {r5-r8, pc}

; ---------------------------------------------------------------------------
align 4
; fasmarm のデータ幅: db=8bit, dh=16bit, dw=32bit (dd は 64bit)
stack_top:      dw 0x03007F00
rom_end_addr:   dw rom_end
col_bg:         dw 0x1084            ; 暗い青灰
col_dim:        dw 0x294A            ; 暗い灰
col_white:      dw 0x7FFF
col_yellow:     dw 0x03FF
col_green:      dw 0x03E0
col_cyan:       dw 0x7FE0
bar_colors:     dh 0x001F, 0x03E0, 0x7C00, 0x03FF, 0x7FE0, 0x7C1F, 0x7FFF, 0x4210
align 4
rom_end:
