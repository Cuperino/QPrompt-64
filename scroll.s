; =============================================================================
;  C64 Smooth Vertical Scroll — Lorem Ipsum
;  Assembler: ca65 (cc65 suite)
;
;  Scrolls Lorem Ipsum text smoothly upward using VIC-II hardware fine
;  scrolling ($D011 bits 0-2) with a raster interrupt.  Text enters from
;  the bottom of the screen and exits above the top, then loops.
;
;  LEFT BORDER OPEN via right-border-dodge (CSEL trick):
;  To keep sprite 0 visible at X=0, we prevent the border flip-flop from
;  being SET at the right edge of lines 139-159.  This keeps the border off
;  for lines 140-160 (the 21 sprite pixel rows).
;
;  Technique per sprite line:
;    end of previous line — dodge right border comparison by switching
;    CSEL 1→0 between the two comparison cycles (53 and 56 on PAL).
;    The VIC misses both checks → border FF stays LOW → no left border.
;    Then early in the sprite line, restore CSEL=1 for 40-col display.
;
;  Double-IRQ stabilisation: first IRQ at raster 137 re-arms to 138.
;  Second IRQ fires with ≤2-cycle jitter (main loop = 3-cycle instrs).
;  The 3-cycle dodge window absorbs this jitter.
; =============================================================================

        .setcpu "6502"

; ---------------------------------------------------------------------------
;  Hardware registers
; ---------------------------------------------------------------------------
VIC_CTRL1       = $D011
VIC_RASTER      = $D012
VIC_CTRL2       = $D016
VIC_IRQ_STATUS  = $D019
VIC_IRQ_MASK    = $D01A
VIC_BORDER      = $D020
VIC_BG          = $D021

VIC_SPR0_X      = $D000
VIC_SPR0_Y      = $D001
VIC_SPR1_X      = $D002
VIC_SPR1_Y      = $D003
VIC_SPR_XMSB    = $D010
VIC_SPR_EN      = $D015
VIC_SPR_PRI     = $D01B
VIC_SPR0_COL    = $D027
VIC_SPR1_COL    = $D028

CIA1_ICR        = $DC0D
SHIFT_FLAG      = $028D             ; KERNAL shift key status (bit 0 = SHIFT)
CURR_KEY        = $CB               ; KERNAL current key matrix code ($40 = none)

; BASIC ROM floating-point routines
GIVAYF          = $B391             ; signed int A(hi)/Y(lo) → FAC
MOVFM           = $BBA2             ; load 5-byte float at A(lo)/Y(hi) → FAC
MOVFA           = $BC0C             ; copy FAC → ARG
FPWRT           = $BF7B             ; FAC = ARG ^ FAC
FMULT           = $BA28             ; FAC = FAC * float at A(lo)/Y(hi)
GETADR          = $B7F7             ; FAC → unsigned 16-bit in $14(lo)/$15(hi)
FOUT            = $BDDD             ; FAC → PETSCII string at $0100
MOVMF           = $BBD4             ; store FAC → 5-byte float at X(lo)/Y(hi)

SCREEN          = $0400
COLRAM          = $D800
SPR_PTR         = SCREEN + $03F8

COLS            = 40                ; visible columns (38-col mode)
SCREEN_COLS     = 40                ; screen memory stride (always 40)
ROWS            = 25
; TOTAL_BYTES     = ROWS * COLS

SPR_Y_CENTER    = 140
LIGHT_BLUE      = $0E
DARK_GRAY       = $0B
LIGHT_GRAY      = $01
WHITE           = $0F

; Raster positions
RASTER_ZONE_ON  = 119
RASTER_ZONE_OFF = 175
RASTER_SCROLL   = 250

; Double-IRQ: first fires at 137, re-arms to 138 for stable second pass
RASTER_CSEL_1ST = 137
RASTER_CSEL_2ND = 138

SPR_HEIGHT      = 21

; CTRL2 values
CTRL2_38COL     = $00               ; CSEL=0, XSCROLL=0  (38 cols)
CTRL2_40COL     = $08               ; CSEL=1, XSCROLL=0  (40 cols)

; ---------------------------------------------------------------------------
;  Zero page
; ---------------------------------------------------------------------------
.segment "ZEROPAGE"
zp_src:         .res 2              ; general purpose source pointer
zp_dst:         .res 2              ; general purpose dest pointer
fine_scroll:    .res 1              ; current fine-scroll value (7..0)
text_lo:        .res 1              ; pointer into text_data (low)
text_hi:        .res 1              ; pointer into text_data (high)
irq_state:      .res 1              ; 0=zone_on, 1=zone_off, 2=scroll
do_coarse:      .res 1              ; pending forward coarse scroll count
csel_pass:      .res 1              ; 0 = first IRQ (re-arm), 1 = second (do work)
current_step:   .res 1              ; current velocity step (0-9)
direction:      .res 1              ; 1=forward (up), $FF=reverse (down)
scroll_accum:   .res 1              ; fractional accumulator (8.8 low byte)
do_coarse_down: .res 1              ; pending reverse coarse scroll count
enter_config:   .res 1              ; flag: 1 = F1 pressed, enter config

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
        ; --- Config screen (runs with KERNAL IRQs still active) ---
        jsr config_screen_init
        jsr build_velocity_table

        sei

        ; Black border and background
        lda #0
        sta VIC_BORDER
        sta VIC_BG

        ; Clear screen with spaces and set colour RAM
        jsr clear_screen

        ; Initialise scroll state
        lda #7
        sta fine_scroll
        lda #3                      ; default step 3 (moderate speed)
        sta current_step
        lda #1                      ; forward direction
        sta direction
        lda #0
        sta scroll_accum
        sta do_coarse
        sta do_coarse_down
        sta enter_config

        lda #<text_data
        sta text_lo
        lda #>text_data
        sta text_hi

        ; --- Horizontal scroll: 40-col mode (CSEL trick steady state) ---
        lda #CTRL2_40COL            ; CSEL=1, XSCROLL=0
        sta VIC_CTRL2

        ; --- Set up sprites ---
        ; Sprite data pointers: sprite 0 at $2000/64=$80, sprite 1 at $2040/64=$81
        lda #$80
        sta SPR_PTR                 ; Sprite 0 = right-pointing triangle
        lda #$81
        sta SPR_PTR+1               ; Sprite 1 = left-pointing triangle

        ; Sprite positions — vertically centered
        lda #00                     ; X = left edge of visible area
        sta VIC_SPR0_X
        lda #88                     ; X = 344 (256+88), right edge
        sta VIC_SPR1_X
        lda #$02                    ; MSB bit 1 set for sprite 1 (X>255)
        sta VIC_SPR_XMSB
        lda #SPR_Y_CENTER
        sta VIC_SPR0_Y
        sta VIC_SPR1_Y

        ; Sprite colours = light blue
        lda #LIGHT_BLUE
        sta VIC_SPR0_COL
        sta VIC_SPR1_COL

        ; Priority: sprites behind foreground (text draws on top)
        lda #$03
        sta VIC_SPR_PRI

        ; Enable sprites 0 and 1
        lda #$03
        sta VIC_SPR_EN

        ; Disable KERNAL cursor blink (prevents $EA31 from modifying screen RAM)
        lda #$01
        sta $CC                     ; $CC != 0 → cursor blink disabled

        ; ---- Install raster IRQ chain ----
        lda #$7F
        sta CIA1_ICR                ; disable CIA timer IRQs
        lda CIA1_ICR                ; acknowledge pending

        lda #$01
        sta VIC_IRQ_MASK            ; enable VIC raster IRQ

        ; Start with zone-on IRQ at raster 119
        lda #0
        sta irq_state
        sta csel_pass

        lda VIC_CTRL1
        and #$7F                    ; clear raster bit 8
        sta VIC_CTRL1
        lda #RASTER_ZONE_ON
        sta VIC_RASTER

        ; Point IRQ vector
        lda #<irq_handler
        sta $0314
        lda #>irq_handler
        sta $0315

        cli

; Main idle loop — all instructions ≤3 cycles, bounding IRQ jitter to ≤2 cy.
@forever:
        lda enter_config            ; 3 cy
        bne @go_config              ; 2 cy (not taken)
        lda do_coarse               ; 3 cy
        bne @do_up                  ; 2 cy (not taken)
        lda do_coarse_down          ; 3 cy
        bne @do_down                ; 2 cy (not taken)
        jmp @forever                ; 3 cy
@do_up:
        dec do_coarse
        jsr scroll_screen_up
        jmp @forever
@do_down:
        dec do_coarse_down
        jsr scroll_screen_down
        jmp @forever
@go_config:
        lda #0
        sta enter_config
        jsr switch_to_config
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

        ; Colour RAM: rows 0-8 = white (bytes 0-359)
        ;            rows 9-14 = light gray (bytes 360-599)
        ;            rows 15-24 = white (bytes 600-999)
        ; Split across pages since X is 8-bit only.

        ; Bytes 0-255: rows 0-6 (all white)
        lda #WHITE
        ldx #0
@cr0:   sta COLRAM, x
        inx
        bne @cr0

        ; Bytes 256-359: rest of rows 7-8 (still white), 0-103 past page 1
        lda #WHITE
        ldx #0
@cr1a:  sta COLRAM+256, x
        inx
        cpx #104
        bne @cr1a

        ; Bytes 360-511: rows 9-12 within page 1+2 overlap
        ;   (360-511 = page 1 offsets 104-255 = bytes 360..511 → light gray)
        lda #LIGHT_GRAY
        ldx #104
@cr1b:  sta COLRAM+256, x
        inx
        bne @cr1b              ; wraps at 256, covers 64-255 = bytes 320-511

        ; Bytes 512-599: top of page 2 (offsets 0-87) = rows 12-14 (light gray)
        lda #LIGHT_GRAY
        ldx #0
@cr2a:  sta COLRAM+512, x
        inx
        cpx #88
        bne @cr2a

        ; Bytes 600-767: offsets 88-255 in page2 = rows 15-19 (white)
        lda #WHITE
        ldx #88
@cr2b:  sta COLRAM+512, x
        inx
        bne @cr2b              ; wraps at 256

        ; Bytes 768-999: page 3 offsets 0-231 = rows 19-24 (white)
        lda #WHITE
        ldx #0
@cr3:   sta COLRAM+744, x
        inx
        cpx #232               ; 1000-768=232
        bne @cr3
        rts


; ---- Config screen ---------------------------------------------------------
; Displays baseSpeed and accelerationCurvature, lets user adjust with
; cursor keys, and starts scrolling on RETURN.
;   UP/DOWN    = baseSpeed ± 0.25
;   LEFT/RIGHT = curvature ± 0.05
;   RETURN     = start scrolling
; ---------------------------------------------------------------------------
KERNAL_GETIN    = $FFE4
KERNAL_CHROUT   = $FFD2
PETSCII_RETURN  = $0D
PETSCII_UP      = $91
PETSCII_DOWN    = $11
PETSCII_LEFT    = $9D
PETSCII_RIGHT   = $1D
PETSCII_F5      = $87

config_screen_init:
        ; Initialize config floats from ROM defaults
        ldx #4
@cp_bs: lda fp_0_15, x
        sta cfg_base_speed, x
        dex
        bpl @cp_bs
        ldx #4
@cp_ac: lda fp_1_10, x
        sta cfg_accel_curv, x
        dex
        bpl @cp_ac
        ; Fall through to config_screen

config_screen:
        ; Flush KERNAL keyboard buffer to prevent queued keys from
        ; being read as immediate input (e.g. F3 pressed during scroll)
        lda #0
        sta $C6                     ; keyboard buffer count
        jsr @draw_config
@cfg_loop:
        jsr KERNAL_GETIN
        beq @cfg_loop               ; no key → keep waiting

        cmp #PETSCII_RETURN
        beq @is_return
        cmp #$8D                    ; SHIFT+RETURN
        bne @not_return
@is_return:
        jmp @cfg_done
@not_return:
        cmp #PETSCII_F5
        beq @is_f5
        cmp #PETSCII_F5+4           ; SHIFT+F5 = F6 = $8B
        bne @not_f5
@is_f5: jmp @cfg_done
@not_f5:
        cmp #PETSCII_UP
        beq @inc_speed
        cmp #PETSCII_DOWN
        beq @dec_speed
        cmp #PETSCII_RIGHT
        bne @not_right
        jmp @inc_curv
@not_right:
        cmp #PETSCII_LEFT
        bne @not_left
        jmp @dec_curv
@not_left:
        jmp @cfg_loop

@inc_speed:
        ; cfg_base_speed += 0.01
        lda #<cfg_base_speed
        ldy #>cfg_base_speed
        jsr MOVFM
        lda #<fp_0_01
        ldy #>fp_0_01
        jsr $B867                   ; FADD: FAC = speed + 0.01
        ldx #<cfg_base_speed
        ldy #>cfg_base_speed
        jsr MOVMF                   ; store tentatively
        ; Check max: FAC = 4.0 - result (FSUB: (A/Y) - FAC)
        lda #<fp_4_0
        ldy #>fp_4_0
        jsr $B850                   ; FAC = 4.0 - result
        lda $61
        beq @speed_inc_ok           ; zero → at max → OK
        lda $66
        bmi @clamp_speed_hi         ; negative → over max → clamp
@speed_inc_ok:
        jsr @draw_config
        jmp @cfg_loop
@clamp_speed_hi:
        ldx #4
@csh:   lda fp_4_0, x
        sta cfg_base_speed, x
        dex
        bpl @csh
        jsr @draw_config
        jmp @cfg_loop

@dec_speed:
        ; cfg_base_speed -= 0.01
        lda #<fp_0_01
        ldy #>fp_0_01
        jsr MOVFM                   ; FAC = 0.01
        lda #<cfg_base_speed
        ldy #>cfg_base_speed
        jsr $B850                   ; FSUB: FAC = speed - 0.01
        ldx #<cfg_base_speed
        ldy #>cfg_base_speed
        jsr MOVMF                   ; store tentatively
        ; Check min: FAC = 0.01 - result
        lda #<fp_0_01
        ldy #>fp_0_01
        jsr $B850                   ; FAC = 0.01 - (speed-0.01)
        lda $61
        beq @speed_dec_ok           ; zero → at min → OK
        lda $66
        bmi @speed_dec_ok           ; negative → above min → OK
        ; positive → below min → clamp
        ldx #4
@csl:   lda fp_0_01, x
        sta cfg_base_speed, x
        dex
        bpl @csl
@speed_dec_ok:
        jsr @draw_config
        jmp @cfg_loop

@inc_curv:
        ; cfg_accel_curv += 0.05
        lda #<cfg_accel_curv
        ldy #>cfg_accel_curv
        jsr MOVFM
        lda #<fp_0_05
        ldy #>fp_0_05
        jsr $B867                   ; FADD: FAC = curv + 0.05
        ldx #<cfg_accel_curv
        ldy #>cfg_accel_curv
        jsr MOVMF                   ; store tentatively
        ; Check max: FAC = 2.0 - result
        lda #<fp_2_0
        ldy #>fp_2_0
        jsr $B850                   ; FAC = 2.0 - result
        lda $61
        beq @curv_inc_ok            ; zero → at max → OK
        lda $66
        bmi @clamp_curv_hi          ; negative → over max → clamp
@curv_inc_ok:
        jsr @draw_config
        jmp @cfg_loop
@clamp_curv_hi:
        ldx #4
@cch:   lda fp_2_0, x
        sta cfg_accel_curv, x
        dex
        bpl @cch
        jsr @draw_config
        jmp @cfg_loop

@dec_curv:
        ; cfg_accel_curv -= 0.05
        lda #<fp_0_05
        ldy #>fp_0_05
        jsr MOVFM
        lda #<cfg_accel_curv
        ldy #>cfg_accel_curv
        jsr $B850                   ; FSUB: FAC = curv - 0.05
        ldx #<cfg_accel_curv
        ldy #>cfg_accel_curv
        jsr MOVMF                   ; store tentatively
        ; Check min: FAC = 0.50 - result
        lda #<fp_0_50
        ldy #>fp_0_50
        jsr $B850                   ; FAC = 0.50 - result
        lda $61
        beq @curv_dec_ok            ; zero → at min → OK
        lda $66
        bmi @curv_dec_ok            ; negative → above min → OK
        ; positive → below min → clamp
        ldx #4
@ccl:   lda fp_0_50, x
        sta cfg_accel_curv, x
        dex
        bpl @ccl
@curv_dec_ok:
        jsr @draw_config
        jmp @cfg_loop

@cfg_done:
        rts

; --- Draw config screen ---
@draw_config:
        ; Clear screen
        lda #$20
        ldx #0
@dcs:   sta SCREEN, x
        sta SCREEN+256, x
        sta SCREEN+512, x
        sta SCREEN+744, x
        inx
        bne @dcs

        ; Row 2: "BASE SPEED:"
        ldx #0
@bs_l:  lda @str_base_speed, x
        beq @bs_done
        sta SCREEN + 2*40 + 2, x
        inx
        bne @bs_l
@bs_done:
        ; Display baseSpeed value at row 2, col 20
        lda #<(SCREEN + 2*40 + 20)
        sta zp_dst
        lda #>(SCREEN + 2*40 + 20)
        sta zp_dst+1
        lda #<cfg_base_speed
        ldy #>cfg_base_speed
        jsr display_fixed2

        ; Row 4: "ACCEL CURVE:"
        ldx #0
@ac_l:  lda @str_accel_curv, x
        beq @ac_done
        sta SCREEN + 4*40 + 2, x
        inx
        bne @ac_l
@ac_done:
        ; Display curvature value at row 4, col 20
        lda #<(SCREEN + 4*40 + 20)
        sta zp_dst
        lda #>(SCREEN + 4*40 + 20)
        sta zp_dst+1
        lda #<cfg_accel_curv
        ldy #>cfg_accel_curv
        jsr display_fixed2

        ; Row 8: instructions
        ldx #0
@in1:   lda @str_instr1, x
        beq @in1d
        sta SCREEN + 8*40 + 2, x
        inx
        bne @in1
@in1d:
        ldx #0
@in2:   lda @str_instr2, x
        beq @in2d
        sta SCREEN + 9*40 + 2, x
        inx
        bne @in2
@in2d:
        ldx #0
@in3:   lda @str_instr3, x
        beq @in3d
        sta SCREEN + 10*40 + 2, x
        inx
        bne @in3
@in3d:

        ; Set all color RAM to white
        lda #WHITE
        ldx #0
@ccr:   sta COLRAM, x
        sta COLRAM+256, x
        sta COLRAM+512, x
        sta COLRAM+744, x
        inx
        bne @ccr
        rts

; Convert PETSCII character in A to screen code (simple subset)
@petscii_to_screen:
        cmp #$30                    ; '0'-'9' ($30-$39)
        bcc @pts_other
        cmp #$3A
        bcs @pts_alpha
        sec
        sbc #$30                    ; screen code for digits = $30-$39 → $00-$09
        ora #$30                    ; actually digits are same: PETSCII $30=$30 screen
        rts
@pts_alpha:
        cmp #$41                    ; 'A'-'Z' ($41-$5A)
        bcc @pts_other
        cmp #$5B
        bcs @pts_other
        sec
        sbc #$40                    ; PETSCII $41 → screen code $01
        rts
@pts_other:
        cmp #$20                    ; space
        beq @pts_ret
        cmp #$2E                    ; '.'
        beq @pts_ret
        cmp #$2D                    ; '-' (minus sign, PETSCII $2D)
        bne @pts_space
        rts
@pts_space:
        lda #$20                    ; default to space
@pts_ret:
        rts

; Config screen strings (screen codes, null-terminated)
@str_base_speed:
        .byte sc_B,sc_A,sc_S,sc_E,__,sc_S,sc_P,sc_E,sc_E,sc_D,$3A,0
@str_accel_curv:
        .byte sc_A,sc_C,sc_C,sc_E,sc_L,__,sc_C,sc_U,sc_R,sc_V,sc_E,$3A,0
@str_instr1:
        .byte sc_U,sc_P,$2F,sc_D,sc_O,sc_W,sc_N,__,$3D,__,sc_B,sc_A,sc_S,sc_E,__,sc_S,sc_P,sc_E,sc_E,sc_D,0
@str_instr2:
        .byte sc_L,sc_E,sc_F,sc_T,$2F,sc_R,sc_I,sc_G,sc_H,sc_T,__,$3D,__,sc_C,sc_U,sc_R,sc_V,sc_A,sc_T,sc_U,sc_R,sc_E,0
@str_instr3:
        .byte sc_R,sc_E,sc_T,sc_U,sc_R,sc_N,$2F,sc_F,$35,__,$3D,__,sc_S,sc_T,sc_A,sc_R,sc_T,0


; ---- Display float as "N.NN" -----------------------------------------------
; Input: A(lo)/Y(hi) = pointer to 5-byte float
;        zp_dst = screen address to write 4 chars
; Clobbers: A, X, Y, FAC, $14/$15
; ---------------------------------------------------------------------------
display_fixed2:
        jsr MOVFM               ; FAC = float value
        lda #<fp_100
        ldy #>fp_100
        jsr FMULT               ; FAC *= 100
        lda #<fp_0_50
        ldy #>fp_0_50
        jsr $B867               ; FAC += 0.5 (round to nearest)
        jsr GETADR              ; $14/$15 = integer

        ; Extract hundreds digit (integer part, 0-9)
        ldx #0
@df_h:  sec
        lda $14
        sbc #100
        tay
        lda $15
        sbc #0
        bcc @df_hd
        sta $15
        sty $14
        inx
        jmp @df_h
@df_hd:
        ; X = integer part digit
        txa
        ora #$30                ; screen code for digit
        ldy #0
        sta (zp_dst), y

        ; Decimal point
        lda #$2E
        iny
        sta (zp_dst), y

        ; Extract tens from remainder ($14 < 100)
        lda $14
        ldx #0
@df_t:  cmp #10
        bcc @df_td
        sbc #10
        inx
        jmp @df_t
@df_td:
        ; X = tens digit, A = ones digit
        pha
        txa
        ora #$30
        iny                     ; Y=2
        sta (zp_dst), y

        pla
        ora #$30
        iny                     ; Y=3
        sta (zp_dst), y
        rts


; =============================================================================
; Raster IRQ handler — 5-point chain (including double-IRQ for CSEL)
;
; Per-frame order (ascending raster values):
;   State 0 → raster 119  : zone on  (dark gray bg)
;   State 3 → raster 137  : CSEL pass 1 (re-arm to 138, exit fast)
;   State 3 → raster 138  : CSEL pass 2 (stable; unrolled border-open)
;   State 1 → raster 175  : zone off (black bg)
;   State 2 → raster 250  : scroll update
;
; Chain: 0 → 3 → (3) → 1 → 2 → 0
; =============================================================================
irq_handler:
        lda #$01
        sta VIC_IRQ_STATUS          ; ack

        lda irq_state
        cmp #3
        bne @not_state3
        jmp @state3                 ; most time-critical
@not_state3:
        cmp #1
        beq @state1
        cmp #2
        bne @state0
        jmp @state2
@state0:

        ; --- State 0: zone start (raster 119) ---
        lda #DARK_GRAY
        sta VIC_BG
        sta VIC_BORDER              ; border matches bg — appears transparent

        ; Next: CSEL first pass at raster 137
        lda #RASTER_CSEL_1ST
        sta VIC_RASTER
        lda #3
        sta irq_state
        lda #0
        sta csel_pass
        jmp $EA81                   ; quick RTI — no KERNAL handler;
                                    ; $EA31 would run keyboard scan (~1000 cy
                                    ; with key pressed) and risk overshooting
                                    ; raster 137 (CSEL first pass)

@state1:
        ; --- State 1: zone end (raster 175) ---
        lda #0
        sta VIC_BG
        sta VIC_BORDER              ; border back to black
        lda #RASTER_SCROLL
        sta VIC_RASTER
        lda #2
        sta irq_state
        jmp $EA81                   ; quick RTI — KERNAL handler only runs
                                    ; from State 2 (raster 250, bottom border)
                                    ; to avoid any side effects during visible area

@state2:
        ; --- State 2: scroll update (raster 250) ---
        lda #RASTER_ZONE_ON
        sta VIC_RASTER
        lda #0
        sta irq_state

        ; --- Read keyboard and update step/direction ---
        jsr read_keyboard

        ; --- Accumulate velocity ---
        ldx current_step
        clc
        lda scroll_accum
        adc velocity_lo, x
        sta scroll_accum
        lda velocity_hi, x
        adc #0                      ; A = integer pixels to scroll
        beq @s2_done                ; 0 pixels → skip

        tax                         ; X = pixel count
        lda direction
        bmi @s2_reverse

        ; --- Forward: decrement fine_scroll, coarse up on underflow ---
@s2_fwd:
        dec fine_scroll
        lda fine_scroll
        bpl @s2_fwd_next
        lda #7
        sta fine_scroll
        inc do_coarse
@s2_fwd_next:
        dex
        bne @s2_fwd
        jmp @s2_update_vic

        ; --- Reverse: increment fine_scroll, coarse down on overflow ---
@s2_reverse:
@s2_rev:
        inc fine_scroll
        lda fine_scroll
        cmp #8
        bcc @s2_rev_next
        lda #0
        sta fine_scroll
        inc do_coarse_down
@s2_rev_next:
        dex
        bne @s2_rev

@s2_update_vic:
        lda fine_scroll
        ora #%00010000
        sta VIC_CTRL1
@s2_done:
        jmp $EA31

; ---------------------------------------------------------------------------
; State 3: CSEL border-open
; ---------------------------------------------------------------------------
; The border main flip-flop is SET when X matches the right-border compare:
;   CSEL=0 → x=$14F → cycle 53 (phi1)
;   CSEL=1 → x=$158 → cycle 56 (phi1)
; To dodge: have CSEL=1 at cycle 53, write CSEL=0 between cycle 53-56.
; 6502 writes on phi2; VIC reads on phi1 of the NEXT cycle.
; So a STA that completes at cycle 53 phi2 → VIC sees CSEL=0 from cycle 54.
; Window: STA write at cycle 53, 54, or 55 (VIC sees change at 54, 55, 56).
;   cycle 53: VIC@53 sees old CSEL=1 → no match for $14F. VIC@54 sees CSEL=0
;             → $14F comparison: x@54 ≠ $14F. VIC@56 CSEL=0 → checks $14F
;             not $158. OK, dodge works.
;   cycle 55: VIC@55 still sees CSEL=1. VIC@56 sees CSEL=0 → checks $14F
;             not $158. Still OK.
;   cycle 56: VIC@56 still sees CSEL=1 → checks $158, x=$158 → MATCH → BAD!
; So write must complete at cycle 53, 54, or 55. Window = 3 cycles.
; With ≤2-cycle jitter from double-IRQ + 3-cycle main-loop instructions,
; we can reliably hit this window.
;
@state3:
        lda csel_pass
        bne @csel_pass2

        ; --- Pass 1 (raster 137): re-arm for raster 138, exit FAST ---
        ; MUST use $EA81 (quick RTI), NOT $EA31 (full KERNAL handler).
        ; $EA31 runs keyboard scan/jiffy clock (~300 cy), pushing pass 2
        ; into raster 142+ and completely missing the dodge window.
        lda #1
        sta csel_pass
        lda #RASTER_CSEL_2ND
        sta VIC_RASTER
        ; Stay in state 3
        jmp $EA81               ; quick exit: PLA/TAY/PLA/TAX/PLA/RTI

@csel_pass2:
        ; --- Pass 2 (raster 138): stable entry, ≤2-cycle jitter ---
        ;
        ; Cycle accounting:
        ;   Pass 1 total: 36(KERNAL entry) + 19(dispatch) + 14(pass1+JMP)
        ;     + 22($EA81 exit) = 91 cy.  Overflows raster 137 by 91-63 = 28.
        ;   RTI at cycle 28 of raster 138.  Raster 138 IRQ is already pending
        ;   → fires immediately (no main-loop jitter added).
        ;   Pass 2: 36(KERNAL entry) + 20(dispatch to here) = 56 cy from
        ;     cycle 28 = cycle 84 = cycle 21 of raster 139.
        ;   Jitter: ±0-2 from pass 1's initial trigger.
        ;
        ; We're at cycle ~21 of raster 139.
        ;
        ; Set CSEL=1 so VIC sees 40-col mode at cycle 53.
        lda #CTRL2_40COL            ; 2 cy
        sta VIC_CTRL2               ; 4 cy (CSEL now 1)
        ; Reset pass for next frame
        lda #0                      ; 2 cy
        sta csel_pass               ; 3 cy
        ;   Setup total: 11 cy → now at cycle ~32 of raster 139.
        ;
        ; Target dodge write at cycle 53:
        ;   LDA(2)+STA(write at +3) = 5 cy from LDA start.
        ;   LDA starts at 53 - 5 = 48.  Waste: 48 - 32 = 16 cy = 8 NOPs.
        ;
        ; Jitter check: entry 21/22/23 → write at 53/54/55.  All in window. ✓

        ; -- 8 NOPs = 16 cycles --
        .repeat 8
        nop
        .endrepeat

        ; First dodge: writes CSEL=0 at cycle 53 of raster 139 (±0-2 jitter).
        ; VIC saw CSEL=1 at cycle 53 → skipped $14F check.
        ; VIC sees CSEL=0 at cycle 56 → checks $14F (already passed) → no match.
        ; Border flip-flop stays LOW → no left border on line 140.
        lda #CTRL2_38COL            ; 2 cy
        sta VIC_CTRL2               ; 4 cy → write on 4th cy (the dodge)

        ; ---------------------------------------------------------------
        ; Now unroll 21 iterations (for rasters 140-160).
        ; Each iteration = 63 cycles (one PAL line) and does:
        ;   1. Waste until ~cycle 17 → restore CSEL=1 (40-col display)
        ;   2. Waste until ~cycle 48 → write CSEL=0 (dodge right border)
        ;
        ; The first iteration's cycle 0 is right after the previous STA
        ; completed.  We ended the dodge STA at cycle ~58 of raster 139,
        ; so the next instruction starts at cycle ~58.
        ; Remaining in raster 139: 63-58 = 5 cycles → that's cycles 58-62.
        ; These 5 cycles are the "head" of the first iteration.
        ; The iteration nominally goes from cycle 58 of line N to cycle 58
        ; of line N+1 = 63 cycles total.
        ;
        ; Layout (63 cycles per iteration):
        ;   From start (prev-line cycle 58):
        ;     waste to reach restore point: need STA write at ~cycle 17
        ;       of next line. Cycles available: (63-58) + 17 = 22 cycles
        ;       to the STA write. STA write = 5 cy from LDA start.
        ;       So LDA starts at 22-5 = 17 cycles from iter start.
        ;       17/2 = 8 NOPs + 1 extra → 8 NOPs(16) + bit $EA(3) = 19. No.
        ;       Actually 17 cycles: 8 NOPs(16) + ??? (1 cy) = impossible
        ;       with standard instructions.  Let's use 7 NOPs (14) +
        ;       BIT zp (3) = 17. ✓
        ;
        ;     lda #CTRL2_40COL      2 cy
        ;     sta VIC_CTRL2         4 cy → write at cycle 17 (restore)
        ;
        ;     waste to reach dodge point: need STA write at ~cycle 54.
        ;       From cycle 23 (after restore STA) to LDA start for dodge.
        ;       STA write at cycle 54 → LDA starts at 54-5 = 49.
        ;       Waste: 49-23 = 26 cycles = 13 NOPs. ✓
        ;
        ;     lda #CTRL2_38COL      2 cy
        ;     sta VIC_CTRL2         4 cy → write at cycle 54 (dodge)
        ;
        ;     After dodge STA: cycle 55. Next iter starts at cycle 58.
        ;     Remaining waste: 58-55 = 3 cycles = 1 NOP(2)+... no.
        ;       3 cycles: BIT zp = 3 cycles. ✓
        ;
        ;   Verify total: 17 + 2 + 4 + 26 + 2 + 4 + 3 = 58.
        ;   Hmm, that's only 58 not 63. Let me recount.
        ;
        ;   Start of iter = cycle 58 of raster N.
        ;   End of iter = cycle 58 of raster N+1 = 63 cycles later.
        ;   Available: 63 cycles.
        ;
        ;   7 NOPs(14) + BIT zp(3) = 17 cycles → at cycle 58+17 = 75 → line wrap: 75-63 = cycle 12 of next line
        ;   LDA(2) → cycle 14.  STA(4) → write at cycle 14+3=17. Restore at cycle 17. ✓
        ;   13 NOPs(26) → cycle 17+6+26 = cycle 49. Hmm wait.
        ;
        ;   Let me just do it sequentially. Iter starts at cycle X of line N.
        ;   Line N has 63-X cycles remaining. Then full line N+1.
        ;   X = 58 for this layout.
        ;   Remaining in line N: 63-58 = 5 cycles.
        ;   Into line N+1: cycle 0.
        ;   Goal: STA write at cycle 17 of line N+1.
        ;   From iter start to STA write: 5 + 17 = 22 cycles.
        ;   LDA+STA = 6 cycles, write at cycle 5 from LDA start.
        ;   Waste before LDA: 22 - 5 = 17. (LDA starts at cy 17, write at cy 22.)
        ;   Hmm, that puts write at cycle 22 from start = 5 + 17 = cy 22 of
        ;   line N+1.  That's too late for the restore — 40-col display starts
        ;   at cycle ~14. But actually the display start is when the border
        ;   turns off, which we've prevented. The border is OFF already due to
        ;   the dodge. The char display starts regardless at the normal column.
        ;   CSEL just changes the comparison value; the display runs from the
        ;   character generator regardless. With CSEL=0, the display area is
        ;   8 pixels narrower (4 on each side). So we want CSEL=1 as early as
        ;   possible to show 40 columns.
        ;
        ;   The left-border-OFF comparison (when border FF would be RESET):
        ;     CSEL=0 → cycle 15;  CSEL=1 → cycle 12
        ;   But the FF is already LOW (we dodged), so neither comparison
        ;   matters for the border. However, CSEL affects the display width.
        ;   To get 40-col display we just need CSEL=1 before the first
        ;   character pixel is fetched (~cycle 14-15). So restore at cycle 12.
        ;
        ;   Updated: restore write at cycle 12 of next line.
        ;   From iter start: 5 + 12 = 17 cycles to STA write.
        ;   LDA write = cycle 5 from LDA start → LDA starts at 17-5 = 12.
        ;   Waste before LDA: 12 cycles = 6 NOPs.
        ;
        ;   After restore STA: we're at cycle 12 + 1 = 13 of line N+1.
        ;   (STA takes 4 cycles, started at cy 5+7=12... let me redo this.)
        ;
        ; OK - I'm going to simplify. Let me define the iteration as
        ; starting right after the dodge STA completes (= cycle D+4 where
        ; D is the cycle the STA started). I'll aim for:
        ;   dodge STA writes at cycle 54 → STA starts at cycle 51
        ;     (STA abs: 4 cycles, write on cycle 4 = STA_start+3)
        ;     wait: STA_start(51) + 4 = done at cycle 55.
        ;   Hmm, let me be very explicit about STA timing.
        ;   STA $D016:
        ;     cycle 1: read opcode
        ;     cycle 2: read addr low
        ;     cycle 3: read addr high
        ;     cycle 4: write value to address  ← this is the "write"
        ;   If STA starts at cycle 51: write at cycle 54. Done at end of cy 54.
        ;   Next instruction begins at cycle 55.
        ;
        ; Iteration: from cycle 55 of line N to cycle 55 of line N+1 = 63 cy.
        ;
        ; Sub-segments:
        ;   A) cycle 55 → end of line N: 63 - 55 = 8 cycles
        ;   B) line N+1:
        ;      - restore: we want LDA to start such that STA writes at cy ~15.
        ;        STA starts at cy 12 (write at cy 15).
        ;        LDA starts at cy 10.
        ;        So from cy 0 to cy 10: 10 cycles of waste.
        ;   Total waste before LDA: 8 + 10 = 18 cycles = 9 NOPs. ✓
        ;   LDA #CTRL2_40COL: 2 cy (cy 10-11)
        ;   STA VIC_CTRL2: 4 cy (cy 12-15, write at 15). Next at cy 16.
        ;
        ;   C) dodge: STA writes at cycle 54 → STA starts at cy 51.
        ;      LDA starts at cy 49.
        ;      From cy 16 to cy 49: 33 cycles.
        ;      33/2 = 16 NOPs(32) + 1 leftover → 16 NOPs + ??? 
        ;      33 = 16 NOPs(32) + BIT $EA(3) - too much. 
        ;      33 = 15 NOPs(30) + BIT zp(3) = 33. ✓
        ;
        ;   LDA #CTRL2_38COL: 2 cy (cy 49-50)
        ;   STA VIC_CTRL2: 4 cy (cy 51-54, write at 54). Next at cy 55.
        ;
        ;   Total: 18 + 2 + 4 + 33 + 2 + 4 = 63. ✓ !!!
        ; ---------------------------------------------------------------

; First we have the initial dodge already done above.
; It wrote at ~cycle 54 of raster 139, completing at cycle 55.
; Now do 21 unrolled iterations for rasters 140-160.
; The LAST iteration (raster 160) should NOT dodge again (no sprite on 161),
; so we do 20 full iterations + 1 final (restore only, no dodge).

.macro BORDER_LINE
        ; 9 NOPs = 18 cycles (fills end of prev line + start of this line)
        .repeat 9
        nop
        .endrepeat
        ; Restore 40-col mode — STA writes at ~cycle 15
        lda #CTRL2_40COL            ; 2 cy
        sta VIC_CTRL2               ; 4 cy (write at cycle 15)
        ; 15 NOPs(30) + BIT zp(3) = 33 cycles
        .repeat 15
        nop
        .endrepeat
        bit $EA                     ; 3 cy (BIT zp, reads $00EA, harmless)
        ; Dodge right border — STA writes at ~cycle 54
        lda #CTRL2_38COL            ; 2 cy
        sta VIC_CTRL2               ; 4 cy (write at cycle 54)
.endmacro

        ; 20 full iterations (rasters 140-159: restore + dodge)
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE
        BORDER_LINE

        ; 21st iteration (raster 160): restore only, no dodge
        .repeat 9
        nop
        .endrepeat
        lda #CTRL2_40COL
        sta VIC_CTRL2               ; restore 40-col on last sprite line

        ; Done — advance to state 1 (zone off at raster 175)
        lda #RASTER_ZONE_OFF
        sta VIC_RASTER
        lda #1
        sta irq_state

        jmp $EA81                   ; quick RTI — no KERNAL handler;
                                    ; CSEL loop ends at ~raster 160, and
                                    ; $EA31 keyboard scan (~1000 cy with key
                                    ; pressed) would overshoot raster 175
                                    ; (State 1 zone-off), growing the gray zone


; ---- Coarse scroll ----------------------------------------------------------
scroll_screen_up:
        ldx #0
@p0:    lda SCREEN+SCREEN_COLS, x
        sta SCREEN, x
        inx
        bne @p0

        ldx #0
@p1:    lda SCREEN+SCREEN_COLS+256, x
        sta SCREEN+256, x
        inx
        bne @p1

        ldx #0
@p2:    lda SCREEN+SCREEN_COLS+512, x
        sta SCREEN+512, x
        inx
        bne @p2

        ldx #0
@p3:    lda SCREEN+SCREEN_COLS+768, x
        sta SCREEN+768, x
        inx
        cpx #((ROWS-1)*SCREEN_COLS - 768)
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
        sta SCREEN + (ROWS-1)*SCREEN_COLS, y
        iny
        cpy #COLS
        bne @fill

        ; Colour for new row = white
        lda #$0F
        ldy #0
@clr:   sta COLRAM + (ROWS-1)*SCREEN_COLS, y
        iny
        cpy #COLS
        bne @clr

        ; Advance text pointer by COLS
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


; ---- Coarse scroll down (reverse) -----------------------------------------
; Shifts all screen rows down by one and fills the top row (row 0) with
; text data from text_ptr - 25*COLS.  Decrements text_ptr with wrapping.
; ---------------------------------------------------------------------------
scroll_screen_down:
        ; First, retreat text pointer by COLS (undo one advance)
        sec
        lda text_lo
        sbc #COLS
        sta text_lo
        lda text_hi
        sbc #0
        sta text_hi

        ; Wrap check: if text_ptr < text_data, wrap to end
        lda text_hi
        cmp #>text_data
        bcc @wrap_down              ; hi byte below → wrap
        bne @no_wrap_down           ; hi byte above → ok
        lda text_lo
        cmp #<text_data
        bcs @no_wrap_down           ; lo byte >= → ok
@wrap_down:
        ; Wrap to text_data_end - COLS
        sec
        lda #<text_data_end
        sbc #COLS
        sta text_lo
        lda #>text_data_end
        sbc #0
        sta text_hi
@no_wrap_down:

        ; Copy screen rows DOWN: row 23→24, 22→23, ..., 0→1
        ; Must iterate high-to-low to avoid overwriting source data.
        ; Uses dex-before-body + bne to handle full 0-255 range
        ; (bpl fails for X > 127 since bit 7 is set).

        ; Page 3: 192 bytes (offsets 768-959 → 808-999)
        ldx #((ROWS-1)*SCREEN_COLS - 768)   ; 192
@d3:    dex
        lda SCREEN+768, x
        sta SCREEN+768+SCREEN_COLS, x
        txa                         ; set Z flag from X, not from lda
        bne @d3

        ; Page 2: 256 bytes (offsets 512-767 → 552-807)
        ldx #0
@d2:    dex
        lda SCREEN+512, x
        sta SCREEN+512+SCREEN_COLS, x
        txa
        bne @d2

        ; Page 1: 256 bytes (offsets 256-511 → 296-551)
        ldx #0
@d1:    dex
        lda SCREEN+256, x
        sta SCREEN+256+SCREEN_COLS, x
        txa
        bne @d1

        ; Page 0: 256 bytes (offsets 0-255 → 40-295)
        ldx #0
@d0:    dex
        lda SCREEN, x
        sta SCREEN+SCREEN_COLS, x
        txa
        bne @d0

        ; Fill top row (row 0) with text from text_ptr - 25*COLS
        ; Compute source address: text_ptr - 1000
        sec
        lda text_lo
        sbc #<1000
        sta zp_src
        lda text_hi
        sbc #>1000
        sta zp_src+1

        ; Handle wrap: if source < text_data, add text length
        lda zp_src+1
        cmp #>text_data
        bcc @src_wrap
        bne @src_ok
        lda zp_src
        cmp #<text_data
        bcs @src_ok
@src_wrap:
        ; source += (text_data_end - text_data)
        clc
        lda zp_src
        adc #<(text_data_end - text_data)
        sta zp_src
        lda zp_src+1
        adc #>(text_data_end - text_data)
        sta zp_src+1
@src_ok:
        ldy #0
@fill_top:
        lda (zp_src), y
        sta SCREEN, y
        iny
        cpy #COLS
        bne @fill_top

        ; Colour for new top row = white
        lda #$0F
        ldy #0
@clr_top:
        sta COLRAM, y
        iny
        cpy #COLS
        bne @clr_top

        rts


; ---- Build velocity lookup table -------------------------------------------
; Computes velocity_table[step] = baseSpeed * step^curvature * 256
; using BASIC ROM floating-point routines.
; Result is 8.8 fixed-point stored in velocity_hi/velocity_lo.
; ---------------------------------------------------------------------------
build_velocity_table:
        ; Step 0 = still (already zeroed)
        lda #0
        sta velocity_lo
        sta velocity_hi

        ldx #1                      ; start from step 1
@loop:
        stx @save_x + 1            ; self-mod: save loop counter

        ; Convert step (X) to float → FAC
        lda #0                      ; high byte = 0
        txa
        tay                         ; Y = low byte = step
        lda #0                      ; A = high byte
        jsr GIVAYF                  ; FAC = step

        ; Copy FAC → ARG (base for power function)
        jsr MOVFA

        ; Load accelerationCurvature → FAC (exponent)
        lda #<cfg_accel_curv
        ldy #>cfg_accel_curv
        jsr MOVFM

        ; FAC = ARG ^ FAC = step ^ curvature
        jsr FPWRT

        ; FAC *= baseSpeed
        lda #<cfg_base_speed
        ldy #>cfg_base_speed
        jsr FMULT

        ; FAC *= 256 (convert to 8.8 fixed-point units)
        lda #<fp_256
        ldy #>fp_256
        jsr FMULT

        ; Convert FAC → 16-bit unsigned integer in $14(lo)/$15(hi)
        jsr GETADR

@save_x:
        ldx #0                      ; restored by self-mod above
        lda $14                     ; low byte (fractional part)
        sta velocity_lo, x
        lda $15                     ; high byte (integer pixels)
        sta velocity_hi, x

        inx
        cpx #10
        bne @loop
        rts


; ---- Read keyboard ---------------------------------------------------------
; Reads KERNAL's current key ($CB) and maps to step (0-9).
; Reads SHIFT flag ($028D) for direction.
; Only updates current_step when a recognized number key is detected.
; ---------------------------------------------------------------------------
read_keyboard:
        ; --- Direction from SHIFT status ---
        lda SHIFT_FLAG
        and #$01                    ; bit 0 = SHIFT (includes SHIFT LOCK)
        beq @dir_fwd
        lda #$FF                    ; reverse
        sta direction
        jmp @check_key
@dir_fwd:
        lda #$01
        sta direction

@check_key:
        lda CURR_KEY                ; current key matrix code
        cmp #$40                    ; no key pressed
        beq @rk_done

        ; Check for F1 (matrix code $04) → enter config
        cmp #$04
        bne @not_f1
        lda #1
        sta enter_config
        rts
@not_f1:
        ; Compare against number key matrix codes
        cmp #$38                    ; key "1" → step 0 (still)
        bne @not1
        lda #0
        sta current_step
        rts
@not1:  cmp #$3B                    ; key "2" → step 1
        bne @not2
        lda #1
        sta current_step
        rts
@not2:  cmp #$08                    ; key "3" → step 2
        bne @not3
        lda #2
        sta current_step
        rts
@not3:  cmp #$0B                    ; key "4" → step 3
        bne @not4
        lda #3
        sta current_step
        rts
@not4:  cmp #$10                    ; key "5" → step 4
        bne @not5
        lda #4
        sta current_step
        rts
@not5:  cmp #$13                    ; key "6" → step 5
        bne @not6
        lda #5
        sta current_step
        rts
@not6:  cmp #$18                    ; key "7" → step 6
        bne @not7
        lda #6
        sta current_step
        rts
@not7:  cmp #$1B                    ; key "8" → step 7
        bne @not8
        lda #7
        sta current_step
        rts
@not8:  cmp #$20                    ; key "9" → step 8
        bne @not9
        lda #8
        sta current_step
        rts
@not9:  cmp #$23                    ; key "0" → step 9
        bne @rk_done
        lda #9
        sta current_step
@rk_done:
        rts


; ---- Switch to config screen and back --------------------------------------
; Called from main loop when F1 is pressed.
; Disables raster IRQ, restores KERNAL, runs config screen, rebuilds velocity
; table, restores raster IRQ, and refills the scroll display.
; ---------------------------------------------------------------------------
switch_to_config:
        sei

        ; Disable VIC raster IRQ
        lda #$00
        sta VIC_IRQ_MASK

        ; Acknowledge any pending VIC IRQ
        lda #$FF
        sta VIC_IRQ_STATUS

        ; Re-enable CIA1 timer IRQ (for KERNAL keyboard scan)
        lda #$81
        sta CIA1_ICR

        ; Restore KERNAL IRQ vector
        lda #$31
        sta $0314
        lda #$EA
        sta $0315

        ; Normal 25-row display for config screen
        lda #$1B
        sta VIC_CTRL1
        lda #$08                    ; CSEL=1 (40-col mode)
        sta VIC_CTRL2

        ; Restore BASIC default colors
        lda #$0E                    ; light blue
        sta VIC_BORDER
        lda #$06                    ; blue
        sta VIC_BG

        ; Hide sprites during config
        lda #$00
        sta VIC_SPR_EN

        cli

        ; Save text pointer — BASIC ROM float routines (called by
        ; config_screen and build_velocity_table) use ZP $07/$08
        ; as scratch, which overlaps text_lo/text_hi.
        lda text_lo
        pha
        lda text_hi
        pha

        ; --- Run config screen (no default reset) ---
        jsr config_screen
        jsr build_velocity_table

        ; Restore text pointer
        pla
        sta text_hi
        pla
        sta text_lo

        sei

        ; Restore black border/background
        lda #$00
        sta VIC_BORDER
        sta VIC_BG

        ; Clear screen and refill with text
        jsr clear_screen
        jsr refill_screen

        ; Reset scroll state
        lda #7
        sta fine_scroll
        lda #0
        sta scroll_accum
        sta do_coarse
        sta do_coarse_down

        ; Disable cursor blink again (config screen re-enabled KERNAL)
        lda #$01
        sta $CC

        ; Re-disable CIA1, enable VIC raster
        lda #$7F
        sta CIA1_ICR
        lda CIA1_ICR                ; acknowledge pending

        lda #$01
        sta VIC_IRQ_MASK

        ; Reset IRQ chain state
        lda #0
        sta irq_state
        sta csel_pass

        lda #RASTER_ZONE_ON
        sta VIC_RASTER

        ; Set VIC_CTRL1 for scrolling: DEN=1, RSEL=0, YSCROLL=fine_scroll
        lda fine_scroll
        ora #%00010000
        sta VIC_CTRL1
        lda VIC_CTRL1
        and #$7F                    ; clear raster bit 8
        sta VIC_CTRL1

        ; Restore 40-col mode (steady-state value — CSEL trick leaves CTRL2
        ; at $08 after the last sprite line; 38-col only during dodge rasters)
        lda #CTRL2_40COL
        sta VIC_CTRL2

        ; Restore IRQ vector
        lda #<irq_handler
        sta $0314
        lda #>irq_handler
        sta $0315

        ; Re-enable sprites
        lda #$03
        sta VIC_SPR_EN

        cli
        rts


; ---- Refill screen from text data ------------------------------------------
; Fills all 25 screen rows based on current text_ptr.
; Row 0 = text_ptr - 1000, Row 24 = text_ptr - 40.
; ---------------------------------------------------------------------------
refill_screen:
        ; Compute source = text_ptr - 1000 (top row)
        sec
        lda text_lo
        sbc #<1000
        sta zp_src
        lda text_hi
        sbc #>1000
        sta zp_src+1

        ; Wrap if source < text_data
        lda zp_src+1
        cmp #>text_data
        bcc @rf_wrap
        bne @rf_no_wrap
        lda zp_src
        cmp #<text_data
        bcs @rf_no_wrap
@rf_wrap:
        clc
        lda zp_src
        adc #<(text_data_end - text_data)
        sta zp_src
        lda zp_src+1
        adc #>(text_data_end - text_data)
        sta zp_src+1
@rf_no_wrap:

        ; Set screen destination
        lda #<SCREEN
        sta zp_dst
        lda #>SCREEN
        sta zp_dst+1

        ldx #ROWS                   ; 25 rows
@rf_row:
        ldy #0
@rf_col:
        lda (zp_src), y
        sta (zp_dst), y
        iny
        cpy #COLS
        bne @rf_col

        ; Advance source by COLS
        clc
        lda zp_src
        adc #COLS
        sta zp_src
        lda zp_src+1
        adc #0
        sta zp_src+1

        ; Wrap source if >= text_data_end
        lda zp_src+1
        cmp #>text_data_end
        bcc @rf_no_src_wrap
        bne @rf_src_wrap
        lda zp_src
        cmp #<text_data_end
        bcc @rf_no_src_wrap
@rf_src_wrap:
        lda #<text_data
        sta zp_src
        lda #>text_data
        sta zp_src+1
@rf_no_src_wrap:

        ; Advance dest by COLS
        clc
        lda zp_dst
        adc #COLS
        sta zp_dst
        lda zp_dst+1
        adc #0
        sta zp_dst+1

        dex
        bne @rf_row
        rts


; ---------------------------------------------------------------------------
;  Velocity lookup table — computed at startup by build_velocity_table
;  10 entries (steps 0-9), 8.8 fixed-point format
; ---------------------------------------------------------------------------
velocity_lo:    .byte 0,0,0,0,0,0,0,0,0,0
velocity_hi:    .byte 0,0,0,0,0,0,0,0,0,0

; ---------------------------------------------------------------------------
;  Writable copies of float parameters (modified by config screen)
; ---------------------------------------------------------------------------
cfg_base_speed: .byte $7E,$19,$99,$99,$9A       ; 0.15 (default)
cfg_accel_curv: .byte $81,$8C,$CC,$CC,$CD       ; 1.10 (default)

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

; BASIC ROM 5-byte float constants
fp_256:         .byte $89,$00,$00,$00,$00       ; 256.0 (for 8.8 conversion)
fp_0_01:        .byte $7A,$23,$D7,$0A,$3D       ; 0.01 (baseSpeed step)
fp_0_05:        .byte $7C,$4C,$CC,$CC,$CD       ; 0.05 (curvature step)
fp_1_10:        .byte $81,$0C,$CC,$CC,$CD       ; 1.10 (initial curvature)
fp_0_15:        .byte $7E,$19,$99,$99,$9A       ; 0.15 (initial baseSpeed)
fp_0_50:        .byte $80,$00,$00,$00,$00       ; 0.50 (min curvature / rounding)
fp_1_0:         .byte $81,$00,$00,$00,$00       ; 1.0
fp_2_0:         .byte $82,$00,$00,$00,$00       ; 2.0 (max curvature)
fp_4_0:         .byte $83,$00,$00,$00,$00       ; 4.0 (max baseSpeed)
fp_100:         .byte $87,$48,$00,$00,$00       ; 100.0 (for N.NN display)

; Blank row macro
.define BLK __,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__

text_data:
; --- Paragraph 1 ---
;         1234567890123456789012345678901234567890
; LINE:  "LOREM IPSUM DOLOR SIT AMET,             "
.byte sc_L,sc_O,sc_R,sc_E,sc_M,__,sc_I,sc_P,sc_S,sc_U,sc_M,__,sc_D,sc_O,sc_L,sc_O,sc_R,__,sc_S,sc_I,sc_T,__,sc_A,sc_M,sc_E,sc_T,_c,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_C,sc_O,sc_N,sc_S,sc_E,sc_C,sc_T,sc_E,sc_T,sc_U,sc_R,__,sc_A,sc_D,sc_I,sc_P,sc_I,sc_S,sc_C,sc_I,sc_N,sc_G,__,sc_E,sc_L,sc_I,sc_T,_d,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_S,sc_E,sc_D,__,sc_D,sc_O,__,sc_E,sc_I,sc_U,sc_S,sc_M,sc_O,sc_D,__,sc_T,sc_E,sc_M,sc_P,sc_O,sc_R,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_I,sc_N,sc_C,sc_I,sc_D,sc_I,sc_D,sc_U,sc_N,sc_T,__,sc_U,sc_T,__,sc_L,sc_A,sc_B,sc_O,sc_R,sc_E,__,sc_E,sc_T,__,sc_D,sc_O,sc_L,sc_O,sc_R,sc_E,__,__,__,__,__,__,__,__,__,__
.byte sc_M,sc_A,sc_G,sc_N,sc_A,__,sc_A,sc_L,sc_I,sc_Q,sc_U,sc_A,_d,__,sc_U,sc_T,__,sc_E,sc_N,sc_I,sc_M,__,sc_A,sc_D,__,sc_M,sc_I,sc_N,sc_I,sc_M,__,__,__,__,__,__,__,__,__,__
.byte sc_V,sc_E,sc_N,sc_I,sc_A,sc_M,_c,__,sc_Q,sc_U,sc_I,sc_S,__,sc_N,sc_O,sc_S,sc_T,sc_R,sc_U,sc_D,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_E,sc_X,sc_E,sc_R,sc_C,sc_I,sc_T,sc_A,sc_T,sc_I,sc_O,sc_N,__,sc_U,sc_L,sc_L,sc_A,sc_M,sc_C,sc_O,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_L,sc_A,sc_B,sc_O,sc_R,sc_I,sc_S,__,sc_N,sc_I,sc_S,sc_I,__,sc_U,sc_T,__,sc_A,sc_L,sc_I,sc_Q,sc_U,sc_I,sc_P,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_E,sc_X,__,sc_E,sc_A,__,sc_C,sc_O,sc_M,sc_M,sc_O,sc_D,sc_O,__,sc_C,sc_O,sc_N,sc_S,sc_E,sc_Q,sc_U,sc_A,sc_T,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte BLK

; --- Paragraph 2 ---
.byte sc_D,sc_U,sc_I,sc_S,__,sc_A,sc_U,sc_T,sc_E,__,sc_I,sc_R,sc_U,sc_R,sc_E,__,sc_D,sc_O,sc_L,sc_O,sc_R,__,sc_I,sc_N,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_R,sc_E,sc_P,sc_R,sc_E,sc_H,sc_E,sc_N,sc_D,sc_E,sc_R,sc_I,sc_T,__,sc_I,sc_N,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_V,sc_O,sc_L,sc_U,sc_P,sc_T,sc_A,sc_T,sc_E,__,sc_V,sc_E,sc_L,sc_I,sc_T,__,sc_E,sc_S,sc_S,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_C,sc_I,sc_L,sc_L,sc_U,sc_M,__,sc_D,sc_O,sc_L,sc_O,sc_R,sc_E,__,sc_E,sc_U,__,sc_F,sc_U,sc_G,sc_I,sc_A,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_N,sc_U,sc_L,sc_L,sc_A,__,sc_P,sc_A,sc_R,sc_I,sc_A,sc_T,sc_U,sc_R,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_E,sc_X,sc_C,sc_E,sc_P,sc_T,sc_E,sc_U,sc_R,__,sc_S,sc_I,sc_N,sc_T,__,sc_O,sc_C,sc_C,sc_A,sc_E,sc_C,sc_A,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_C,sc_U,sc_P,sc_I,sc_D,sc_A,sc_T,sc_A,sc_T,__,sc_N,sc_O,sc_N,__,sc_P,sc_R,sc_O,sc_I,sc_D,sc_E,sc_N,sc_T,_c,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_S,sc_U,sc_N,sc_T,__,sc_I,sc_N,__,sc_C,sc_U,sc_L,sc_P,sc_A,__,sc_Q,sc_U,sc_I,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_O,sc_F,sc_F,sc_I,sc_C,sc_I,sc_A,__,sc_D,sc_E,sc_S,sc_E,sc_R,sc_U,sc_N,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_M,sc_O,sc_L,sc_L,sc_I,sc_T,__,sc_A,sc_N,sc_I,sc_M,__,sc_I,sc_D,__,sc_E,sc_S,sc_T,__,sc_L,sc_A,sc_B,sc_O,sc_R,sc_U,sc_M,_d,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte BLK

; --- Paragraph 3 ---
.byte sc_S,sc_E,sc_D,__,sc_U,sc_T,__,sc_P,sc_E,sc_R,sc_S,sc_P,sc_I,sc_C,sc_I,sc_A,sc_T,sc_I,sc_S,__,sc_U,sc_N,sc_D,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_O,sc_M,sc_N,sc_I,sc_S,__,sc_I,sc_S,sc_T,sc_E,__,sc_N,sc_A,sc_T,sc_U,sc_S,__,sc_E,sc_R,sc_R,sc_O,sc_R,__,sc_S,sc_I,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_V,sc_O,sc_L,sc_U,sc_P,sc_T,sc_A,sc_T,sc_E,sc_M,__,sc_A,sc_C,sc_C,sc_U,sc_S,sc_A,sc_N,sc_T,sc_I,sc_U,sc_M,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_D,sc_O,sc_L,sc_O,sc_R,sc_E,sc_M,sc_Q,sc_U,sc_E,__,sc_L,sc_A,sc_U,sc_D,sc_A,sc_N,sc_T,sc_I,sc_U,sc_M,_c,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_T,sc_O,sc_T,sc_A,sc_M,__,sc_R,sc_E,sc_M,__,sc_A,sc_P,sc_E,sc_R,sc_I,sc_A,sc_M,_c,__,sc_E,sc_A,sc_Q,sc_U,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_I,sc_P,sc_S,sc_A,__,sc_Q,sc_U,sc_A,sc_E,__,sc_A,sc_B,__,sc_I,sc_L,sc_L,sc_O,__,sc_I,sc_N,sc_V,sc_E,sc_N,sc_T,sc_O,sc_R,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_V,sc_E,sc_R,sc_I,sc_T,sc_A,sc_T,sc_I,sc_S,__,sc_E,sc_T,__,sc_Q,sc_U,sc_A,sc_S,sc_I,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_A,sc_R,sc_C,sc_H,sc_I,sc_T,sc_E,sc_C,sc_T,sc_O,__,sc_B,sc_E,sc_A,sc_T,sc_A,sc_E,__,sc_V,sc_I,sc_T,sc_A,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_D,sc_I,sc_C,sc_T,sc_A,__,sc_S,sc_U,sc_N,sc_T,__,sc_E,sc_X,sc_P,sc_L,sc_I,sc_C,sc_A,sc_B,sc_O,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte BLK

; --- Paragraph 4 ---
.byte sc_N,sc_E,sc_M,sc_O,__,sc_E,sc_N,sc_I,sc_M,__,sc_I,sc_P,sc_S,sc_A,sc_M,__,sc_V,sc_O,sc_L,sc_U,sc_P,sc_T,sc_A,sc_T,sc_E,sc_M,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_Q,sc_U,sc_I,sc_A,__,sc_V,sc_O,sc_L,sc_U,sc_P,sc_T,sc_A,sc_S,__,sc_S,sc_I,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_A,sc_S,sc_P,sc_E,sc_R,sc_N,sc_A,sc_T,sc_U,sc_R,__,sc_A,sc_U,sc_T,__,sc_O,sc_D,sc_I,sc_T,__,sc_A,sc_U,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_F,sc_U,sc_G,sc_I,sc_T,_c,__,sc_S,sc_E,sc_D,__,sc_Q,sc_U,sc_I,sc_A,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_C,sc_O,sc_N,sc_S,sc_E,sc_Q,sc_U,sc_U,sc_N,sc_T,sc_U,sc_R,__,sc_M,sc_A,sc_G,sc_N,sc_I,__,sc_D,sc_O,sc_L,sc_O,sc_R,sc_E,sc_S,__,__,__,__,__,__,__,__,__,__,__,__,__,__
.byte sc_E,sc_O,sc_S,__,sc_Q,sc_U,sc_I,__,sc_R,sc_A,sc_T,sc_I,sc_O,sc_N,sc_E,__,sc_V,sc_O,sc_L,sc_U,sc_P,sc_T,sc_A,sc_T,sc_E,sc_M,__,__,__,__,__,__,__,__,__,__,__,__,__,__
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

; =============================================================================
;  Sprite data at $2000 — dedicated SPRITES segment
;  Right-pointing (►) for left side, Left-pointing (◄) for right side
;  Each sprite: 24×21 pixels = 63 bytes + 1 pad = 64 bytes
;  Sprite 0 pointer = $2000/64 = $80
;  Sprite 1 pointer = $2040/64 = $81
; =============================================================================
.segment "SPRITES"

spr_right_tri:  ; at $2000
        .byte $80,$00,$00           ; Row 0:  *
        .byte $C0,$00,$00           ; Row 1:  **
        .byte $E0,$00,$00           ; Row 2:  ***
        .byte $F0,$00,$00           ; Row 3:  ****
        .byte $F8,$00,$00           ; Row 4:  *****
        .byte $FC,$00,$00           ; Row 5:  ******
        .byte $FE,$00,$00           ; Row 6:  *******
        .byte $FF,$00,$00           ; Row 7:  ********
        .byte $FF,$80,$00           ; Row 8:  *********
        .byte $FF,$C0,$00           ; Row 9:  **********
        .byte $FF,$E0,$00           ; Row 10: *********** (widest)
        .byte $FF,$C0,$00           ; Row 11: **********
        .byte $FF,$80,$00           ; Row 12: *********
        .byte $FF,$00,$00           ; Row 13: ********
        .byte $FE,$00,$00           ; Row 14: *******
        .byte $FC,$00,$00           ; Row 15: ******
        .byte $F8,$00,$00           ; Row 16: *****
        .byte $F0,$00,$00           ; Row 17: ****
        .byte $E0,$00,$00           ; Row 18: ***
        .byte $C0,$00,$00           ; Row 19: **
        .byte $80,$00,$00           ; Row 20: *
        .byte $00                   ; Pad to 64 bytes

spr_left_tri:   ; at $2040
        .byte $00,$00,$01           ; Row 0:                        *
        .byte $00,$00,$03           ; Row 1:                       **
        .byte $00,$00,$07           ; Row 2:                      ***
        .byte $00,$00,$0F           ; Row 3:                     ****
        .byte $00,$00,$1F           ; Row 4:                    *****
        .byte $00,$00,$3F           ; Row 5:                   ******
        .byte $00,$00,$7F           ; Row 6:                  *******
        .byte $00,$00,$FF           ; Row 7:                 ********
        .byte $00,$01,$FF           ; Row 8:                *********
        .byte $00,$03,$FF           ; Row 9:               **********
        .byte $00,$07,$FF           ; Row 10:              *********** (widest)
        .byte $00,$03,$FF           ; Row 11:               **********
        .byte $00,$01,$FF           ; Row 12:                *********
        .byte $00,$00,$FF           ; Row 13:                 ********
        .byte $00,$00,$7F           ; Row 14:                  *******
        .byte $00,$00,$3F           ; Row 15:                   ******
        .byte $00,$00,$1F           ; Row 16:                    *****
        .byte $00,$00,$0F           ; Row 17:                     ****
        .byte $00,$00,$07           ; Row 18:                      ***
        .byte $00,$00,$03           ; Row 19:                       **
        .byte $00,$00,$01           ; Row 20:                        *
        .byte $00                   ; Pad to 64 bytes
