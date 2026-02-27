; =============================================================================
;  C64 Smooth Vertical Scroll — Lorem Ipsum
;  Assembler: ca65 (cc65 suite)
;
;  Scrolls Lorem Ipsum text smoothly upward using VIC-II hardware fine
;  scrolling ($D011 bits 0-2) with a raster interrupt.  Text enters from
;  the bottom of the screen and exits above the top, then loops.
; =============================================================================

        .setcpu "6502"

; ---------------------------------------------------------------------------
;  Hardware registers
; ---------------------------------------------------------------------------
VIC_CTRL1       = $D011
VIC_RASTER      = $D012
VIC_IRQ_STATUS  = $D019
VIC_IRQ_MASK    = $D01A
VIC_BORDER      = $D020
VIC_BG          = $D021

CIA1_ICR        = $DC0D

SCREEN          = $0400
COLRAM          = $D800

COLS            = 40
ROWS            = 25
TOTAL_BYTES     = ROWS * COLS       ; 1000

; ---------------------------------------------------------------------------
;  Zero page
; ---------------------------------------------------------------------------
.segment "ZEROPAGE"
zp_src:         .res 2              ; general purpose source pointer
zp_dst:         .res 2              ; general purpose dest pointer
fine_scroll:    .res 1              ; current fine-scroll value (7..0)
text_lo:        .res 1              ; pointer into text_data (low)
text_hi:        .res 1              ; pointer into text_data (high)

; ---------------------------------------------------------------------------
;  PRG load address (consumed by LOAD, not part of memory image)
; ---------------------------------------------------------------------------
.segment "LOADADDR"
        .word $0801                 ; Load address for .prg file

; ---------------------------------------------------------------------------
;  BASIC SYS stub at $0801
;  Stub is 12 bytes: 2 (next ptr) + 2 (line#) + 1 (SYS) + 5 ("2061"\0) + 2 (end)
;  So CODE segment starts at $0801 + 12 = $080D = 2061 decimal.
; ---------------------------------------------------------------------------
.segment "STARTUP"
        .word @nextline
        .word 2024                  ; line number
        .byte $9E                   ; SYS token
        .byte "2061", 0            ; SYS 2061 ($080D)
@nextline:
        .word 0

; ---------------------------------------------------------------------------
;  Code
; ---------------------------------------------------------------------------
.segment "CODE"

; ---- entry point -----------------------------------------------------------
start:
        sei

        ; Black border and background
        lda #0
        sta VIC_BORDER
        sta VIC_BG

        ; Clear screen with spaces and set colour RAM to light green
        jsr clear_screen

        ; Initialise scroll state
        lda #7
        sta fine_scroll

        lda #<text_data
        sta text_lo
        lda #>text_data
        sta text_hi

        ; ---- Install raster IRQ ----
        lda #$7F
        sta CIA1_ICR                ; disable CIA timer IRQs
        lda CIA1_ICR                ; acknowledge pending

        lda #$01
        sta VIC_IRQ_MASK            ; enable VIC raster IRQ

        ; Raster line = 250 (in the lower border)
        lda VIC_CTRL1
        and #$7F                    ; clear raster bit 8
        sta VIC_CTRL1
        lda #250
        sta VIC_RASTER

        ; Point IRQ vector
        lda #<irq_handler
        sta $0314
        lda #>irq_handler
        sta $0315

        cli

        ; Idle loop — everything happens in the IRQ
@forever:
        jmp @forever


; ---- Clear screen -----------------------------------------------------------
clear_screen:
        lda #$20                    ; space screen code
        ldx #0
@cs1:   sta SCREEN, x
        sta SCREEN+256, x
        sta SCREEN+512, x
        sta SCREEN+744, x
        inx
        bne @cs1

        lda #$0D                    ; light green
        ldx #0
@cs2:   sta COLRAM, x
        sta COLRAM+256, x
        sta COLRAM+512, x
        sta COLRAM+744, x
        inx
        bne @cs2
        rts


; ---- Raster IRQ handler ----------------------------------------------------
; Key: $D011 is written FIRST, before any heavy work, so the VIC-II
; always has the correct fine-scroll value before the next visible frame.
irq_handler:
        lda #$01
        sta VIC_IRQ_STATUS          ; acknowledge raster IRQ

        ; Decrement fine scroll
        dec fine_scroll
        lda fine_scroll
        bpl @update                 ; still >= 0 → just update $D011

        ; Wrapped past 0 → reset to 7, update $D011 NOW, then coarse scroll
        lda #7
        sta fine_scroll

        ; Update $D011 immediately (before the slow coarse copy)
        ;   bit 3 = 0  → 24-row mode (hides row 25 used as buffer)
        ;   bit 4 = 1  → screen on (DEN)
        ;   bits 0-2   = fine_scroll (7)
        ora #%00010000
        sta VIC_CTRL1

        jsr scroll_screen_up
        jmp $EA31                   ; chain to Kernal IRQ epilogue

@update:
        ; Normal frame: just set $D011 with current fine_scroll
        lda fine_scroll
        ora #%00010000              ; DEN=1, RSEL=0 (24 rows)
        sta VIC_CTRL1

        jmp $EA31                   ; chain to Kernal IRQ epilogue


; ---- Coarse scroll: shift screen up 1 row, draw new bottom row -------------
scroll_screen_up:
        ; Copy screen RAM: row N+1 → row N (960 bytes)
        ; 4 pages: 3 full (256 bytes) + 1 partial (192 bytes)

        ldx #0
@p0:    lda SCREEN+COLS, x
        sta SCREEN, x
        inx
        bne @p0

        ldx #0
@p1:    lda SCREEN+COLS+256, x
        sta SCREEN+256, x
        inx
        bne @p1

        ldx #0
@p2:    lda SCREEN+COLS+512, x
        sta SCREEN+512, x
        inx
        bne @p2

        ldx #0
@p3:    lda SCREEN+COLS+768, x
        sta SCREEN+768, x
        inx
        cpx #(TOTAL_BYTES - 768 - COLS)
        bne @p3

        ; Colour RAM is NOT copied — all cells share the same colour,
        ; so only the new bottom row needs its colour set (done below).

        ; Fill bottom row (row 24 = offset 960) with next text line
        lda text_lo
        sta zp_src
        lda text_hi
        sta zp_src+1

        ldy #0
@fill:  lda (zp_src), y
        sta SCREEN + (ROWS-1)*COLS, y
        iny
        cpy #COLS
        bne @fill

        ; Colour for new row = light green
        lda #$0D
        ldy #0
@clr:   sta COLRAM + (ROWS-1)*COLS, y
        iny
        cpy #COLS
        bne @clr

        ; Advance text pointer by 40
        clc
        lda text_lo
        adc #COLS
        sta text_lo
        lda text_hi
        adc #0
        sta text_hi

        ; Wrap check
        lda text_hi
        cmp #>text_data_end
        bcc @no_wrap
        bne @wrap
        lda text_lo
        cmp #<text_data_end
        bcc @no_wrap
@wrap:
        lda #<text_data
        sta text_lo
        lda #>text_data
        sta text_hi
@no_wrap:
        rts


; =============================================================================
;  Text data — Lorem Ipsum in C64 screen codes
;  Screen codes: A-Z = $01-$1A, space=$20, comma=$2C, period=$2E
;  Constants use "sc_" prefix to avoid clashing with ca65 register names.
; =============================================================================
.segment "RODATA"

sc_A = $01
sc_B = $02
sc_C = $03
sc_D = $04
sc_E = $05
sc_F = $06
sc_G = $07
sc_H = $08
sc_I = $09
sc_J = $0A
sc_K = $0B
sc_L = $0C
sc_M = $0D
sc_N = $0E
sc_O = $0F
sc_P = $10
sc_Q = $11
sc_R = $12
sc_S = $13
sc_T = $14
sc_U = $15
sc_V = $16
sc_W = $17
sc_X = $18
sc_Y = $19
sc_Z = $1A
__ = $20       ; space
_c = $2C       ; comma
_d = $2E       ; period

; Blank row macro
.define BLK __,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__

text_data:
; --- 25 blank rows: text scrolls in from below the visible screen ---
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK

; --- Paragraph 1 ---
;         1234567890123456789012345678901234567890
; LINE:  "LOREM IPSUM DOLOR SIT AMET,             "
.byte sc_L,sc_O,sc_R,sc_E,sc_M,__,sc_I,sc_P,sc_S,sc_U,sc_M,__,sc_D,sc_O,sc_L,sc_O,sc_R,__,sc_S,sc_I,sc_T,__,sc_A,sc_M,sc_E,sc_T,_c,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "CONSECTETUR ADIPISCING ELIT.            "
.byte sc_C,sc_O,sc_N,sc_S,sc_E,sc_C,sc_T,sc_E,sc_T,sc_U,sc_R,__,sc_A,sc_D,sc_I,sc_P,sc_I,sc_S,sc_C,sc_I,sc_N,sc_G,__,sc_E,sc_L,sc_I,sc_T,_d,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "SED DO EIUSMOD TEMPOR                   "
.byte sc_S,sc_E,sc_D,__,sc_D,sc_O,__,sc_E,sc_I,sc_U,sc_S,sc_M,sc_O,sc_D,__,sc_T,sc_E,sc_M,sc_P,sc_O,sc_R,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "INCIDIDUNT UT LABORE ET DOLORE          "
.byte sc_I,sc_N,sc_C,sc_I,sc_D,sc_I,sc_D,sc_U,sc_N,sc_T,__,sc_U,sc_T,__,sc_L,sc_A,sc_B,sc_O,sc_R,sc_E,__,sc_E,sc_T,__,sc_D,sc_O,sc_L,sc_O,sc_R,sc_E,__,__,__,__,__,__,__,__,__,__
; LINE:  "MAGNA ALIQUA. UT ENIM AD MINIM         "
.byte sc_M,sc_A,sc_G,sc_N,sc_A,__,sc_A,sc_L,sc_I,sc_Q,sc_U,sc_A,_d,__,sc_U,sc_T,__,sc_E,sc_N,sc_I,sc_M,__,sc_A,sc_D,__,sc_M,sc_I,sc_N,sc_I,sc_M,__,__,__,__,__,__,__,__,__,__
; LINE:  "VENIAM, QUIS NOSTRUD                    "
.byte sc_V,sc_E,sc_N,sc_I,sc_A,sc_M,_c,__,sc_Q,sc_U,sc_I,sc_S,__,sc_N,sc_O,sc_S,sc_T,sc_R,sc_U,sc_D,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "EXERCITATION ULLAMCO                    "
.byte sc_E,sc_X,sc_E,sc_R,sc_C,sc_I,sc_T,sc_A,sc_T,sc_I,sc_O,sc_N,__,sc_U,sc_L,sc_L,sc_A,sc_M,sc_C,sc_O,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "LABORIS NISI UT ALIQUIP                 "
.byte sc_L,sc_A,sc_B,sc_O,sc_R,sc_I,sc_S,__,sc_N,sc_I,sc_S,sc_I,__,sc_U,sc_T,__,sc_A,sc_L,sc_I,sc_Q,sc_U,sc_I,sc_P,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "EX EA COMMODO CONSEQUAT.                "
.byte sc_E,sc_X,__,sc_E,sc_A,__,sc_C,sc_O,sc_M,sc_M,sc_O,sc_D,sc_O,__,sc_C,sc_O,sc_N,sc_S,sc_E,sc_Q,sc_U,sc_A,sc_T,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte BLK

; --- Paragraph 2 ---
; LINE:  "DUIS AUTE IRURE DOLOR IN                "
.byte sc_D,sc_U,sc_I,sc_S,__,sc_A,sc_U,sc_T,sc_E,__,sc_I,sc_R,sc_U,sc_R,sc_E,__,sc_D,sc_O,sc_L,sc_O,sc_R,__,sc_I,sc_N,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "REPREHENDERIT IN                        "
.byte sc_R,sc_E,sc_P,sc_R,sc_E,sc_H,sc_E,sc_N,sc_D,sc_E,sc_R,sc_I,sc_T,__,sc_I,sc_N,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "VOLUPTATE VELIT ESSE                    "
.byte sc_V,sc_O,sc_L,sc_U,sc_P,sc_T,sc_A,sc_T,sc_E,__,sc_V,sc_E,sc_L,sc_I,sc_T,__,sc_E,sc_S,sc_S,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "CILLUM DOLORE EU FUGIAT                 "
.byte sc_C,sc_I,sc_L,sc_L,sc_U,sc_M,__,sc_D,sc_O,sc_L,sc_O,sc_R,sc_E,__,sc_E,sc_U,__,sc_F,sc_U,sc_G,sc_I,sc_A,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "NULLA PARIATUR.                         "
.byte sc_N,sc_U,sc_L,sc_L,sc_A,__,sc_P,sc_A,sc_R,sc_I,sc_A,sc_T,sc_U,sc_R,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "EXCEPTEUR SINT OCCAECAT                 "
.byte sc_E,sc_X,sc_C,sc_E,sc_P,sc_T,sc_E,sc_U,sc_R,__,sc_S,sc_I,sc_N,sc_T,__,sc_O,sc_C,sc_C,sc_A,sc_E,sc_C,sc_A,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "CUPIDATAT NON PROIDENT,                 "
.byte sc_C,sc_U,sc_P,sc_I,sc_D,sc_A,sc_T,sc_A,sc_T,__,sc_N,sc_O,sc_N,__,sc_P,sc_R,sc_O,sc_I,sc_D,sc_E,sc_N,sc_T,_c,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "SUNT IN CULPA QUI                       "
.byte sc_S,sc_U,sc_N,sc_T,__,sc_I,sc_N,__,sc_C,sc_U,sc_L,sc_P,sc_A,__,sc_Q,sc_U,sc_I,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "OFFICIA DESERUNT                        "
.byte sc_O,sc_F,sc_F,sc_I,sc_C,sc_I,sc_A,__,sc_D,sc_E,sc_S,sc_E,sc_R,sc_U,sc_N,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "MOLLIT ANIM ID EST LABORUM.             "
.byte sc_M,sc_O,sc_L,sc_L,sc_I,sc_T,__,sc_A,sc_N,sc_I,sc_M,__,sc_I,sc_D,__,sc_E,sc_S,sc_T,__,sc_L,sc_A,sc_B,sc_O,sc_R,sc_U,sc_M,_d,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte BLK

; --- Paragraph 3 ---
; LINE:  "SED UT PERSPICIATIS UNDE                "
.byte sc_S,sc_E,sc_D,__,sc_U,sc_T,__,sc_P,sc_E,sc_R,sc_S,sc_P,sc_I,sc_C,sc_I,sc_A,sc_T,sc_I,sc_S,__,sc_U,sc_N,sc_D,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "OMNIS ISTE NATUS ERROR SIT              "
.byte sc_O,sc_M,sc_N,sc_I,sc_S,__,sc_I,sc_S,sc_T,sc_E,__,sc_N,sc_A,sc_T,sc_U,sc_S,__,sc_E,sc_R,sc_R,sc_O,sc_R,__,sc_S,sc_I,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "VOLUPTATEM ACCUSANTIUM                  "
.byte sc_V,sc_O,sc_L,sc_U,sc_P,sc_T,sc_A,sc_T,sc_E,sc_M,__,sc_A,sc_C,sc_C,sc_U,sc_S,sc_A,sc_N,sc_T,sc_I,sc_U,sc_M,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "DOLOREMQUE LAUDANTIUM,                  "
.byte sc_D,sc_O,sc_L,sc_O,sc_R,sc_E,sc_M,sc_Q,sc_U,sc_E,__,sc_L,sc_A,sc_U,sc_D,sc_A,sc_N,sc_T,sc_I,sc_U,sc_M,_c,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "TOTAM REM APERIAM, EAQUE                "
.byte sc_T,sc_O,sc_T,sc_A,sc_M,__,sc_R,sc_E,sc_M,__,sc_A,sc_P,sc_E,sc_R,sc_I,sc_A,sc_M,_c,__,sc_E,sc_A,sc_Q,sc_U,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "IPSA QUAE AB ILLO INVENTORE             "
.byte sc_I,sc_P,sc_S,sc_A,__,sc_Q,sc_U,sc_A,sc_E,__,sc_A,sc_B,__,sc_I,sc_L,sc_L,sc_O,__,sc_I,sc_N,sc_V,sc_E,sc_N,sc_T,sc_O,sc_R,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "VERITATIS ET QUASI                      "
.byte sc_V,sc_E,sc_R,sc_I,sc_T,sc_A,sc_T,sc_I,sc_S,__,sc_E,sc_T,__,sc_Q,sc_U,sc_A,sc_S,sc_I,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "ARCHITECTO BEATAE VITAE                 "
.byte sc_A,sc_R,sc_C,sc_H,sc_I,sc_T,sc_E,sc_C,sc_T,sc_O,__,sc_B,sc_E,sc_A,sc_T,sc_A,sc_E,__,sc_V,sc_I,sc_T,sc_A,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "DICTA SUNT EXPLICABO.                   "
.byte sc_D,sc_I,sc_C,sc_T,sc_A,__,sc_S,sc_U,sc_N,sc_T,__,sc_E,sc_X,sc_P,sc_L,sc_I,sc_C,sc_A,sc_B,sc_O,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte BLK

; --- Paragraph 4 ---
; LINE:  "NEMO ENIM IPSAM VOLUPTATEM              "
.byte sc_N,sc_E,sc_M,sc_O,__,sc_E,sc_N,sc_I,sc_M,__,sc_I,sc_P,sc_S,sc_A,sc_M,__,sc_V,sc_O,sc_L,sc_U,sc_P,sc_T,sc_A,sc_T,sc_E,sc_M,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "QUIA VOLUPTAS SIT                       "
.byte sc_Q,sc_U,sc_I,sc_A,__,sc_V,sc_O,sc_L,sc_U,sc_P,sc_T,sc_A,sc_S,__,sc_S,sc_I,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "ASPERNATUR AUT ODIT AUT                 "
.byte sc_A,sc_S,sc_P,sc_E,sc_R,sc_N,sc_A,sc_T,sc_U,sc_R,__,sc_A,sc_U,sc_T,__,sc_O,sc_D,sc_I,sc_T,__,sc_A,sc_U,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "FUGIT, SED QUIA                         "
.byte sc_F,sc_U,sc_G,sc_I,sc_T,_c,__,sc_S,sc_E,sc_D,__,sc_Q,sc_U,sc_I,sc_A,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "CONSEQUUNTUR MAGNI DOLORES              "
.byte sc_C,sc_O,sc_N,sc_S,sc_E,sc_Q,sc_U,sc_U,sc_N,sc_T,sc_U,sc_R,__,sc_M,sc_A,sc_G,sc_N,sc_I,__,sc_D,sc_O,sc_L,sc_O,sc_R,sc_E,sc_S,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "EOS QUI RATIONE VOLUPTATEM              "
.byte sc_E,sc_O,sc_S,__,sc_Q,sc_U,sc_I,__,sc_R,sc_A,sc_T,sc_I,sc_O,sc_N,sc_E,__,sc_V,sc_O,sc_L,sc_U,sc_P,sc_T,sc_A,sc_T,sc_E,sc_M,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; LINE:  "SEQUI NESCIUNT.                         "
.byte sc_S,sc_E,sc_Q,sc_U,sc_I,__,sc_N,sc_E,sc_S,sc_C,sc_I,sc_U,sc_N,sc_T,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__

; --- 25 trailing blank rows: text scrolls fully off the top ---
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK

text_data_end:
