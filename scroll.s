; =============================================================================
;  QPrompt 64 — C64 Teleprompter
;  Assembler: ca65 (cc65 suite)
;
;  Teleprompter with smooth vertical scrolling, a full-screen text editor,
;  and floppy disk save/load.  Uses VIC-II hardware fine scrolling
;  ($D011 bits 0-2) with a raster interrupt chain.
;
;  Border color indicator: a 12-line light blue band on both borders
;  (rasters 140-151) marks the center of the reading zone.
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

COLS            = 40
SCREEN_COLS     = 40                ; screen memory stride (always 40)
ROWS            = 25
; TOTAL_BYTES     = ROWS * COLS

SPR_Y_CENTER    = 140
LIGHT_BLUE      = $0E
DARK_GRAY       = $0B
LIGHT_GRAY      = $01
WHITE           = $0F

; Raster positions
RASTER_ZONE_ON      = 123
RASTER_INDICATOR_ON = 144
RASTER_INDICATOR_OFF= 158
RASTER_ZONE_OFF     = 179
RASTER_SCROLL       = 250

; ---------------------------------------------------------------------------
;  Zero page
; ---------------------------------------------------------------------------
.segment "ZEROPAGE"
zp_src:         .res 2              ; general purpose source pointer
zp_dst:         .res 2              ; general purpose dest pointer
fine_scroll:    .res 1              ; current fine-scroll value (7..0)
text_lo:        .res 1              ; pointer into text_data (low)
text_hi:        .res 1              ; pointer into text_data (high)
irq_state:      .res 1              ; 0=zone_on, 1=zone_off, 2=scroll, 3=indicator_on, 4=indicator_off
do_coarse:      .res 1              ; pending forward coarse scroll count
current_step:   .res 1              ; current velocity step (0-9)
direction:      .res 1              ; 1=forward (up), $FF=reverse (down)
scroll_accum:   .res 1              ; fractional accumulator (8.8 low byte)
do_coarse_down: .res 1              ; pending reverse coarse scroll count
enter_config:   .res 1              ; flag: 0=none, 1=config, 2=editor
cursor_x:       .res 1              ; editor cursor column 0-39
cursor_y:       .res 1              ; editor cursor row 0-23
current_page:   .res 1              ; 0-based page number
total_pages:    .res 1              ; number of pages (1-based, max 10)
came_from:      .res 1              ; 0=initial, 1=editor, 2=scroll
first_run:      .res 1              ; 1=first RETURN on config goes to editor

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
        jsr init_document
        jsr build_velocity_table

        ; First config screen — returns destination in A
        jsr config_screen

; --- Top-level dispatch: A = 0 (scroll) or 1 (editor) ---
main_dispatch:
        cmp #1
        beq @md_editor
        jmp enter_scroll_mode

@md_editor:
        lda #0
        sta VIC_BORDER
        sta VIC_BG
        jsr enter_editor
        ; Editor returned — A: 0=go to config, 1=go to scroll
        cmp #1
        beq @md_ed_to_scroll
        ; Go to config
        lda #$0E
        sta VIC_BORDER
        lda #$06
        sta VIC_BG
        jsr build_velocity_table
        jsr config_screen
        jmp main_dispatch
@md_ed_to_scroll:
        lda #0                      ; destination = scroll
        jmp main_dispatch

; --- Enter scroll mode and run scroll loop ---
enter_scroll_mode:
        lda #2
        sta came_from               ; mark that we're in scroll mode
        jsr prepare_scroll_text

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

        ; 40-col mode
        lda #$08                    ; CSEL=1, XSCROLL=0
        sta VIC_CTRL2

        ; --- Set up sprites ---
        ; Sprite data pointers: sprite 0 at $3000/64=$C0, sprite 1 at $3040/64=$C1
        lda #$C0
        sta SPR_PTR                 ; Sprite 0 = right-pointing triangle
        lda #$C1
        sta SPR_PTR+1               ; Sprite 1 = left-pointing triangle

        ; Sprite positions — vertically centered
        lda #24                     ; X = left edge of visible area
        sta VIC_SPR0_X
        lda #65                     ; X = 344 (256+88), right edge
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

        ; Fill screen with text data
        jsr refill_screen

        ; ---- Install raster IRQ chain ----
        lda #$7F
        sta CIA1_ICR                ; disable CIA timer IRQs
        lda CIA1_ICR                ; acknowledge pending

        lda #$01
        sta VIC_IRQ_MASK            ; enable VIC raster IRQ

        ; Start with zone-on IRQ (fires 2 lines early for stable raster)
        lda #0
        sta irq_state

        lda VIC_CTRL1
        and #$7F                    ; clear raster bit 8
        sta VIC_CTRL1
        lda #(RASTER_ZONE_ON - 3)
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
        bne @exit_scroll            ; 2 cy (not taken)
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
@exit_scroll:
        ; enter_config: 1=F1 (config), 2=F3 (editor)
        lda enter_config
        pha
        lda #0
        sta enter_config
        jsr disable_raster_restore_kernal
        pla
        cmp #2
        beq @scroll_to_editor
        ; --- F1: go to config, then dispatch ---
        lda #$0E
        sta VIC_BORDER
        lda #$06
        sta VIC_BG
        jsr build_velocity_table
        jsr config_screen
        jmp main_dispatch

@scroll_to_editor:
        ; --- F3: go directly to editor ---
        lda #0
        sta VIC_BORDER
        sta VIC_BG
        jsr enter_editor
        ; Editor returned — A: 0=config, 1=scroll
        cmp #1
        beq @ste_to_scroll
        ; Go to config
        lda #$0E
        sta VIC_BORDER
        lda #$06
        sta VIC_BG
        jsr build_velocity_table
        jsr config_screen
        jmp main_dispatch
@ste_to_scroll:
        lda #0                      ; destination = scroll
        jmp main_dispatch


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
        ;            rows 9-15 = light gray (bytes 360-639)
        ;            rows 16-24 = white (bytes 640-999)
        ; Split across pages since X is 8-bit only.

        ; Bytes 0-255: rows 0-6 (all white)
        lda #WHITE
        ldx #0
@cr0:   sta COLRAM, x
        inx
        bne @cr0

        ; Bytes 256-359: rows 7-8 (still white)
        lda #WHITE
        ldx #0
@cr1a:  sta COLRAM+256, x
        inx
        cpx #104
        bne @cr1a

        ; Bytes 360-511: rows 9-12 (light gray)
        lda #LIGHT_GRAY
        ldx #104
@cr1b:  sta COLRAM+256, x
        inx
        bne @cr1b

        ; Bytes 512-639: rows 12-15 (light gray)
        lda #LIGHT_GRAY
        ldx #0
@cr2a:  sta COLRAM+512, x
        inx
        cpx #128
        bne @cr2a

        ; Bytes 640-767: rows 16-19 (white)
        lda #WHITE
        ldx #128
@cr2b:  sta COLRAM+512, x
        inx
        bne @cr2b

        ; Page 3: COLRAM+768..1023 (rows 19-24, 24 extra bytes harmless)
        lda #WHITE
        ldx #0
@cr3:   sta COLRAM+768, x
        inx
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
        ; Set first_run and came_from
        lda #1
        sta first_run
        lda #0
        sta came_from
        rts

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
        ; RETURN: if first_run → go to editor; else check came_from
        lda first_run
        beq @ret_not_first
        lda #0
        sta first_run
        lda #1                      ; destination = editor
        rts
@ret_not_first:
        lda came_from
        cmp #1                      ; came from editor?
        beq @ret_to_editor
        lda #0                      ; destination = scroll
        rts
@ret_to_editor:
        lda #1                      ; destination = editor
        rts
@not_return:
        cmp #PETSCII_F5
        beq @is_f5
        cmp #PETSCII_F5+4           ; SHIFT+F5 = F6 = $8B
        bne @not_f5
@is_f5: lda #0                      ; destination = scroll
        sta first_run               ; clear first_run
        rts
@not_f5:
        cmp #$86                    ; F3 PETSCII
        bne @not_f3
        lda #1                      ; destination = editor
        rts
@not_f3:
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
        ldx #0
@in4:   lda @str_instr4, x
        beq @in4d
        sta SCREEN + 11*40 + 2, x
        inx
        bne @in4
@in4d:
        ; Row 23: "QPROMPT 64" centered (col 15)
        ldx #0
@in5:   lda @str_title, x
        beq @in5d
        sta SCREEN + 23*40 + 15, x
        inx
        bne @in5
@in5d:

        ; Set all color RAM to white
        lda #WHITE
        ldx #0
@ccr:   sta COLRAM, x
        sta COLRAM+256, x
        sta COLRAM+512, x
        sta COLRAM+768, x
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
@str_instr4:
        .byte sc_F,$33,__,$3D,__,sc_E,sc_D,sc_I,sc_T,sc_O,sc_R,0
@str_title:
        .byte sc_Q,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,__,$36,$34,0


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
; Raster IRQ handler — 5-point chain with raster-line polling
;
; Each color-change IRQ fires 3 lines before the target raster.  After
; dispatch, the handler polls VIC_RASTER (CPX $D012 / BNE, 7-cycle loop)
; until the exact target line appears, then writes the color register
; immediately.  This technique is immune to variable IRQ entry latency
; (from coarse-scroll routines with 4-5 cycle instructions) and VIC-II
; bad-line cycle stealing (~40 cycles), both of which disrupted the old
; NOP-delay approach.  The 7-cycle polling loop gives ≤6 cycles of write
; jitter, which always lands in the left border (invisible).
;
; Per-frame order (ascending raster values):
;   State 0 → fires raster 120 : zone on  (dark gray bg + border from 123)
;   State 3 → fires raster 141 : indicator on (light blue border from 144)
;   State 4 → fires raster 153 : indicator off (dark gray border from 156)
;   State 1 → fires raster 176 : zone off (black bg + border from 179)
;   State 2 → fires raster 250 : scroll update (no alignment needed)
;
; Chain: 0 → 3 → 4 → 1 → 2 → 0
; =============================================================================
irq_handler:
        lda #$01
        sta VIC_IRQ_STATUS          ; ack

        lda irq_state
        cmp #2
        bne @not_state2
        jmp @state2
@not_state2:
        cmp #1
        bne @not_state1
        jmp @state1
@not_state1:
        cmp #3
        bne @not_state3
        jmp @state3
@not_state3:
        cmp #4
        bne @state0
        jmp @state4
@state0:
        ; --- State 0: zone start ---
        ; Poll target-1, then NOP-delay to HBLANK so both writes land at
        ; cycles 0-10 on target (before visible area).  When target-1 is a
        ; bad line (fine_scroll matches), skip delay — the bad-line halt
        ; already consumed the extra cycles.
        lda #DARK_GRAY
        ldx #(RASTER_ZONE_ON - 1)
@w0:    cpx VIC_RASTER
        bne @w0
        ldy fine_scroll
        cpy #((RASTER_ZONE_ON - 1) & 7)
        beq @s0_bl
        .repeat 25
        nop
        .endrepeat
        sta VIC_BORDER
        sta VIC_BG
        jmp @s0_done
@s0_bl: sta VIC_BORDER
        sta VIC_BG
@s0_done:
        lda #(RASTER_INDICATOR_ON - 3)
        sta VIC_RASTER
        lda #3
        sta irq_state
        jmp $EA81

@state3:
        ; --- State 3: indicator on ---
        ; Sprite DMA on these lines (140-160) prevents poll exit before cycle 3,
        ; so STA lands at cycles 9-12 — before visible border at ~cycle 14.
        lda #LIGHT_BLUE
        ldx #RASTER_INDICATOR_ON
@w3:    cpx VIC_RASTER
        bne @w3
        sta VIC_BORDER
        lda #(RASTER_INDICATOR_OFF - 3)
        sta VIC_RASTER
        lda #4
        sta irq_state
        jmp $EA81

@state4:
        ; --- State 4: indicator off ---
        ; Sprite DMA on these lines (140-160) prevents poll exit before cycle 3,
        ; so STA lands at cycles 9-12 — before visible border at ~cycle 14.
        lda #DARK_GRAY
        ldx #RASTER_INDICATOR_OFF
@w4:    cpx VIC_RASTER
        bne @w4
        sta VIC_BORDER
        lda #(RASTER_ZONE_OFF - 3)
        sta VIC_RASTER
        lda #1
        sta irq_state
        jmp $EA81

@state1:
        ; --- State 1: zone end ---
        lda #0
        ldx #(RASTER_ZONE_OFF - 1)
@w1:    cpx VIC_RASTER
        bne @w1
        ldy fine_scroll
        cpy #((RASTER_ZONE_OFF - 1) & 7)
        beq @s1_bl
        .repeat 25
        nop
        .endrepeat
        sta VIC_BORDER
        sta VIC_BG
        jmp @s1_done
@s1_bl: sta VIC_BORDER
        sta VIC_BG
@s1_done:

        lda #RASTER_SCROLL
        sta VIC_RASTER
        lda #2
        sta irq_state
        jmp $EA81

@state2:
        ; --- State 2: scroll update (raster 250) ---
        lda #(RASTER_ZONE_ON - 3)
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
@p3:    lda SCREEN+SCREEN_COLS+744, x
        sta SCREEN+744, x
        inx
        bne @p3

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
        cmp scroll_end_hi
        bcc @no_wrap
        bne @wrap
        lda text_lo
        cmp scroll_end_lo
        bcc @no_wrap
@wrap:
        lda scroll_start_lo
        sta text_lo
        lda scroll_start_hi
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

        ; Wrap check: if text_ptr < scroll_start, wrap to end
        lda text_hi
        cmp scroll_start_hi
        bcc @wrap_down              ; hi byte below → wrap
        bne @no_wrap_down           ; hi byte above → ok
        lda text_lo
        cmp scroll_start_lo
        bcs @no_wrap_down           ; lo byte >= → ok
@wrap_down:
        ; Wrap to scroll_end - COLS
        sec
        lda scroll_end_lo
        sbc #COLS
        sta text_lo
        lda scroll_end_hi
        sbc #0
        sta text_hi
@no_wrap_down:

        ; Compute fill source address for row 0: text_ptr - 1000
        sec
        lda text_lo
        sbc #<1000
        sta zp_src
        lda text_hi
        sbc #>1000
        sta zp_src+1

        ; Handle wrap: if source < scroll_start, add text length
        lda zp_src+1
        cmp scroll_start_hi
        bcc @src_wrap
        bne @src_ok
        lda zp_src
        cmp scroll_start_lo
        bcs @src_ok
@src_wrap:
        ; Add scroll_end - scroll_start to source
        sec
        lda scroll_end_lo
        sbc scroll_start_lo
        sta zp_dst              ; temp: text length lo
        lda scroll_end_hi
        sbc scroll_start_hi
        sta zp_dst+1            ; temp: text length hi
        clc
        lda zp_src
        adc zp_dst
        sta zp_src
        lda zp_src+1
        adc zp_dst+1
        sta zp_src+1
@src_ok:

        ; Copy screen rows DOWN: row 23→24, 22→23, ..., 0→1
        ; Pages copied 0→1→2→3 so top rows update before the beam.
        ; Each page's +40 shift overwrites the first 40 bytes of the next
        ; page's source, so those bytes are saved upfront.

        ; Save 3 inter-page overlap regions (40 bytes each)
        ldx #39
@save:  lda SCREEN+256, x
        sta save_buf_a, x
        lda SCREEN+512, x
        sta save_buf_b, x
        lda SCREEN+768, x
        sta save_buf_c, x
        dex
        bpl @save

        ; Page 0: 256 bytes (offsets 0-255 → 40-295)
        ldx #0
@d0:    dex
        lda SCREEN, x
        sta SCREEN+SCREEN_COLS, x
        txa
        bne @d0

        ; Fill row 0 immediately after page 0 (before beam reaches raster 51)
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

        ; Page 1: 256 bytes (offsets 256-511 → 296-551)
        ; Upper 216 bytes from screen (uncorrupted), lower 40 from save_buf_a
        ldx #0
@d1u:   dex
        lda SCREEN+256, x
        sta SCREEN+256+SCREEN_COLS, x
        cpx #40
        bne @d1u
        ldx #40
@d1l:   dex
        lda save_buf_a, x
        sta SCREEN+256+SCREEN_COLS, x
        txa
        bne @d1l

        ; Page 2: 256 bytes (offsets 512-767 → 552-807)
        ; Upper 216 bytes from screen (uncorrupted), lower 40 from save_buf_b
        ldx #0
@d2u:   dex
        lda SCREEN+512, x
        sta SCREEN+512+SCREEN_COLS, x
        cpx #40
        bne @d2u
        ldx #40
@d2l:   dex
        lda save_buf_b, x
        sta SCREEN+512+SCREEN_COLS, x
        txa
        bne @d2l

        ; Page 3: 192 bytes (offsets 768-959 → 808-999)
        ; Upper 152 bytes from screen, lower 40 from save_buf_c
        ldx #((ROWS-1)*SCREEN_COLS - 768)   ; 192
@d3u:   dex
        lda SCREEN+768, x
        sta SCREEN+768+SCREEN_COLS, x
        cpx #40
        bne @d3u
        ldx #40
@d3l:   dex
        lda save_buf_c, x
        sta SCREEN+768+SCREEN_COLS, x
        txa
        bne @d3l

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
        ; Check for F3 (matrix code $05) → enter editor
        cmp #$05
        bne @not_f3
        lda #2
        sta enter_config
        rts
@not_f3:
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


; ---- Disable raster IRQ and restore KERNAL ----------------------------------
disable_raster_restore_kernal:
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

        ; Normal 25-row display
        lda #$1B
        sta VIC_CTRL1
        lda #$08                    ; CSEL=1 (40-col mode)
        sta VIC_CTRL2

        ; Disable sprites
        lda #$00
        sta VIC_SPR_EN

        cli
        rts


; ===========================================================================
;  EDITOR SCREEN
; ===========================================================================

; ---- Enter editor -----------------------------------------------------------
; Full-screen text editor with page navigation, cursor movement, and typing.
; Returns when F1 is pressed (came_from set to 1 = editor).
; ---------------------------------------------------------------------------
enter_editor:
        ; Set black border/background
        lda #0
        sta VIC_BORDER
        sta VIC_BG

        ; Clear screen
        lda #$20
        ldx #0
@ee_cls:
        sta SCREEN, x
        sta SCREEN+256, x
        sta SCREEN+512, x
        sta SCREEN+744, x
        inx
        bne @ee_cls

        ; Set color RAM rows 0-23 = WHITE
        lda #WHITE
        ldx #0
@ee_cr0:
        sta COLRAM, x
        sta COLRAM+256, x
        sta COLRAM+512, x
        inx
        bne @ee_cr0
        ; Remaining row 24 area in page 3 = LIGHT_BLUE
        ldx #0
@ee_cr3:
        sta COLRAM+768, x
        inx
        cpx #192                    ; rows 19-23 (white)
        bne @ee_cr3
        lda #LIGHT_BLUE
        ldx #192
@ee_cr4:
        sta COLRAM+768, x          ; row 24 = light blue
        inx
        bne @ee_cr4

        ; Load current page
        jsr load_editor_page

        ; Draw status bar
        jsr draw_status_bar

        ; Draw cursor (reverse char at position)
        jsr draw_cursor

        ; Flush keyboard buffer
        lda #0
        sta $C6

; ---- Editor main loop -------------------------------------------------------
editor_loop:
        ; Check Ctrl key via $028D (bit 2 = CTRL)
        lda $028D
        and #$04
        beq @no_ctrl
        lda $CB                     ; matrix code
        cmp #$0D                    ; S key
        bne @not_ctrl_s
        jmp do_ctrl_s
@not_ctrl_s:
        cmp #$27                    ; N key
        bne @not_ctrl_n
        jmp do_ctrl_n
@not_ctrl_n:
        cmp #$26                    ; O key
        bne @not_ctrl_o
        jmp do_ctrl_o
@not_ctrl_o:
        cmp #$33                    ; HOME/CLR key
        bne @no_ctrl
        jmp do_ctrl_clr
@no_ctrl:
        ; GETIN for normal keys
        jsr KERNAL_GETIN
        beq editor_loop

        ; Dispatch
        cmp #$88                    ; F7 → next page
        bne @not_f7
        jmp ed_next_page
@not_f7:
        cmp #$8C                    ; F8 → prev page
        bne @not_f8
        jmp ed_prev_page
@not_f8:
        cmp #$87                    ; F5 → exit to scroll
        bne @not_f5
        jmp ed_exit_to_scroll
@not_f5:
        cmp #$85                    ; F1 → exit to config
        bne @not_f1_ed
        jmp ed_exit
@not_f1_ed:
        cmp #$86                    ; F3 → exit to scroll
        bne @not_f3_ed
        jmp ed_exit_to_scroll
@not_f3_ed:
        cmp #$0D                    ; RETURN
        bne @not_return
        jmp ed_return_key
@not_return:
        cmp #$14                    ; DEL (backspace)
        bne @not_del
        jmp ed_del_key
@not_del:
        cmp #$91                    ; Cursor Up
        bne @not_up
        jmp ed_cursor_up
@not_up:
        cmp #$11                    ; Cursor Down
        bne @not_down
        jmp ed_cursor_down
@not_down:
        cmp #$9D                    ; Cursor Left
        bne @not_left
        jmp ed_cursor_left
@not_left:
        cmp #$1D                    ; Cursor Right
        bne @not_right_ed
        jmp ed_cursor_right
@not_right_ed:
        ; Try printable character
        jsr petscii_to_screencode_editor
        bcs editor_loop             ; carry set = not printable
        jmp ed_printable

; ---- Printable character ----------------------------------------------------
ed_printable:
        ; A = screen code to place
        pha
        jsr undraw_cursor           ; restore original char (also sets zp_dst)
        jsr ed_calc_cursor_addr     ; zp_dst = screen addr of cursor (trashes A)
        pla                         ; restore screen code AFTER addr calc
        ; Write at cursor position
        ldy #0
        sta (zp_dst), y
        ; Advance cursor right
        inc cursor_x
        lda cursor_x
        cmp #40
        bcc @ep_done
        lda #0
        sta cursor_x
        inc cursor_y
        lda cursor_y
        cmp #24
        bcc @ep_done
        lda #23
        sta cursor_y
@ep_done:
        jsr draw_cursor
        jmp editor_loop

; ---- RETURN key -------------------------------------------------------------
ed_return_key:
        jsr undraw_cursor
        lda #0
        sta cursor_x
        inc cursor_y
        lda cursor_y
        cmp #24
        bcc @erk_done
        lda #23
        sta cursor_y
@erk_done:
        jsr draw_cursor
        jmp editor_loop

; ---- DEL (backspace) --------------------------------------------------------
ed_del_key:
        ; If at 0,0 do nothing
        lda cursor_x
        ora cursor_y
        beq @edk_done_jmp
        jsr undraw_cursor
        ; Move cursor left
        lda cursor_x
        bne @edk_left
        ; At col 0 → go to col 39, prev row
        lda #39
        sta cursor_x
        dec cursor_y
        jmp @edk_clear
@edk_left:
        dec cursor_x
@edk_clear:
        ; Write space at new cursor position
        jsr ed_calc_cursor_addr
        lda #$20
        ldy #0
        sta (zp_dst), y
        jsr draw_cursor
@edk_done_jmp:
        jmp editor_loop

; ---- Cursor movement --------------------------------------------------------
ed_cursor_up:
        jsr undraw_cursor
        lda cursor_y
        beq @ecu_done
        dec cursor_y
@ecu_done:
        jsr draw_cursor
        jmp editor_loop

ed_cursor_down:
        jsr undraw_cursor
        lda cursor_y
        cmp #23
        bcs @ecd_done
        inc cursor_y
@ecd_done:
        jsr draw_cursor
        jmp editor_loop

ed_cursor_left:
        jsr undraw_cursor
        lda cursor_x
        beq @ecl_done
        dec cursor_x
@ecl_done:
        jsr draw_cursor
        jmp editor_loop

ed_cursor_right:
        jsr undraw_cursor
        lda cursor_x
        cmp #39
        bcs @ecr_done
        inc cursor_x
@ecr_done:
        jsr draw_cursor
        jmp editor_loop

; ---- F7: Next page ----------------------------------------------------------
ed_next_page:
        jsr undraw_cursor
        jsr save_editor_page
        lda current_page
        clc
        adc #1
        cmp total_pages
        bcc @enp_existing           ; current_page+1 < total_pages → ok
        ; At last page — can we add a new one?
        lda total_pages
        cmp #10
        bcs @enp_no_more            ; already 10 pages
        ; Add new blank page
        inc total_pages
        ; Fill new page with spaces
        ldx total_pages
        dex                         ; index of new page (total_pages-1)
        lda page_addr_lo, x
        sta zp_dst
        lda page_addr_hi, x
        sta zp_dst+1
        jsr fill_page_spaces
@enp_existing:
        inc current_page
        jsr load_editor_page
        jsr draw_status_bar
        lda #0
        sta cursor_x
        sta cursor_y
        jsr draw_cursor
@enp_no_more:
        jmp editor_loop

; ---- F8/F5: Prev page -------------------------------------------------------
ed_prev_page:
        lda current_page
        beq @epp_done               ; already at page 0
        jsr undraw_cursor
        jsr save_editor_page
        ; Check if we're on the last page and it's empty → remove it
        lda current_page
        clc
        adc #1
        cmp total_pages             ; are we on the last page?
        bne @epp_no_trim
        lda total_pages
        cmp #2                      ; need at least 2 pages to trim (keep min 1)
        bcc @epp_no_trim
        jsr check_page_empty        ; checks current_page, sets carry if empty
        bcc @epp_no_trim
        dec total_pages             ; remove the empty last page
@epp_no_trim:
        dec current_page
        jsr load_editor_page
        jsr draw_status_bar
        lda #0
        sta cursor_x
        sta cursor_y
        jsr draw_cursor
@epp_done:
        jmp editor_loop

; ---- F1: Exit to config -----------------------------------------------------
ed_exit:
        jsr undraw_cursor
        jsr save_editor_page
        lda #1
        sta came_from               ; came from editor
        lda #0                      ; return 0 = go to config
        rts

; ---- F3: Exit to scroll -----------------------------------------------------
ed_exit_to_scroll:
        jsr undraw_cursor
        jsr save_editor_page
        lda #1
        sta came_from               ; came from editor
        lda #1                      ; return 1 = go to scroll
        rts

; ---- Calculate cursor screen address ----------------------------------------
; Sets zp_dst to SCREEN + cursor_y * 40 + cursor_x
; ---------------------------------------------------------------------------
ed_calc_cursor_addr:
        ; Multiply cursor_y by 40: y*40 = y*8 + y*32
        lda #0
        sta zp_dst+1
        lda cursor_y
        asl                         ; y*2
        asl                         ; y*4
        asl                         ; y*8
        sta zp_dst                  ; save y*8
        asl                         ; y*16 (low byte)
        rol zp_dst+1               ; carry into high byte
        asl                         ; y*32 (low byte)
        rol zp_dst+1
        clc
        adc zp_dst                  ; y*32 + y*8 = y*40 (low)
        sta zp_dst
        lda zp_dst+1
        adc #0                      ; carry from low-byte add
        sta zp_dst+1
        ; Add cursor_x
        clc
        lda zp_dst
        adc cursor_x
        sta zp_dst
        lda zp_dst+1
        adc #0
        sta zp_dst+1
        ; Add SCREEN base
        clc
        lda zp_dst
        adc #<SCREEN
        sta zp_dst
        lda zp_dst+1
        adc #>SCREEN
        sta zp_dst+1
        rts

; ---- Draw cursor (reverse char at position) ---------------------------------
draw_cursor:
        jsr ed_calc_cursor_addr
        ldy #0
        lda (zp_dst), y
        ora #$80                    ; set bit 7 (reverse)
        sta (zp_dst), y
        rts

; ---- Undraw cursor (un-reverse char at position) ----------------------------
undraw_cursor:
        jsr ed_calc_cursor_addr
        ldy #0
        lda (zp_dst), y
        and #$7F                    ; clear bit 7 (un-reverse)
        sta (zp_dst), y
        rts

; ---- PETSCII → screen code conversion (editor) -----------------------------
; Input: A = PETSCII character
; Output: A = screen code, carry clear if printable; carry set if rejected
; ---------------------------------------------------------------------------
petscii_to_screencode_editor:
        cmp #$20
        bcc @pts_reject
        cmp #$40
        bcc @pts_direct             ; $20-$3F → same screen code (space, digits, punctuation)
        cmp #$60
        bcc @pts_upper              ; $40-$5F → AND #$3F (uppercase letters, @, [, etc.)
        cmp #$80
        bcc @pts_reject             ; $60-$7F → reject (control chars)
        cmp #$A0
        bcc @pts_reject             ; $80-$9F → reject (control chars)
        cmp #$C0
        bcc @pts_gfx                ; $A0-$BF → shifted punctuation/graphics
        cmp #$E0
        bcc @pts_lower              ; $C0-$DF → lowercase letters (AND #$3F → same as uppercase screen codes, but use AND #$7F for shifted gfx)
        ; $E0-$FE → shifted graphics
        and #$7F                    ; map to $60-$7E screen codes
        clc
        rts
@pts_reject:
        sec
        rts
@pts_direct:
        clc
        rts
@pts_upper:
        and #$3F                    ; PETSCII $41-$5A → screen $01-$1A
        clc
        rts
@pts_gfx:
        sbc #$3F                    ; PETSCII $A0-$BF → screen $60-$7F (carry is set from cmp)
        clc
        rts
@pts_lower:
        and #$3F                    ; PETSCII $C1-$DA → screen $01-$1A (same as uppercase)
        clc
        rts

; ---- Save editor page: SCREEN rows 0-23 → doc_buffer -----------------------
save_editor_page:
        ; Calculate doc_buffer address for current_page
        ldx current_page
        lda page_addr_lo, x
        sta zp_dst
        lda page_addr_hi, x
        sta zp_dst+1

        ; Source = SCREEN
        lda #<SCREEN
        sta zp_src
        lda #>SCREEN
        sta zp_src+1

        ; Copy 960 bytes = 3 full 256-byte pages + 192 bytes
        ldx #3
@sep_full:
        ldy #0
@sep_byte:
        lda (zp_src), y
        sta (zp_dst), y
        iny
        bne @sep_byte
        inc zp_src+1
        inc zp_dst+1
        dex
        bne @sep_full
        ; Copy remaining 192 bytes
        ldy #0
@sep_tail:
        lda (zp_src), y
        sta (zp_dst), y
        iny
        cpy #192
        bne @sep_tail
        rts

; ---- Load editor page: doc_buffer → SCREEN rows 0-23 -----------------------
load_editor_page:
        ; Calculate doc_buffer address for current_page
        ldx current_page
        lda page_addr_lo, x
        sta zp_src
        lda page_addr_hi, x
        sta zp_src+1

        ; Dest = SCREEN
        lda #<SCREEN
        sta zp_dst
        lda #>SCREEN
        sta zp_dst+1

        ; Copy 960 bytes = 3 full 256-byte pages + 192 bytes
        ldx #3
@lep_full:
        ldy #0
@lep_byte:
        lda (zp_src), y
        sta (zp_dst), y
        iny
        bne @lep_byte
        inc zp_src+1
        inc zp_dst+1
        dex
        bne @lep_full
        ; Copy remaining 192 bytes
        ldy #0
@lep_tail:
        lda (zp_src), y
        sta (zp_dst), y
        iny
        cpy #192
        bne @lep_tail
        rts

; ---- Fill a page (960 bytes) at zp_dst with spaces --------------------------
fill_page_spaces:
        lda #$20
        ldx #3
@fps_full:
        ldy #0
@fps_byte:
        sta (zp_dst), y
        iny
        bne @fps_byte
        inc zp_dst+1
        dex
        bne @fps_full
        ldy #0
@fps_tail:
        sta (zp_dst), y
        iny
        cpy #192
        bne @fps_tail
        rts

; ---- Check if current page (in doc_buffer) is all spaces --------------------
; Output: carry set = empty, carry clear = has content
; ---------------------------------------------------------------------------
check_page_empty:
        ldx current_page
        lda page_addr_lo, x
        sta zp_src
        lda page_addr_hi, x
        sta zp_src+1

        ; Check 960 bytes: 3 full pages + 192 bytes
        ldx #3
@cpe_full:
        ldy #0
@cpe_byte:
        lda (zp_src), y
        cmp #$20
        bne @cpe_not_empty
        iny
        bne @cpe_byte
        inc zp_src+1
        dex
        bne @cpe_full
        ; Check remaining 192 bytes
        ldy #0
@cpe_tail:
        lda (zp_src), y
        cmp #$20
        bne @cpe_not_empty
        iny
        cpy #192
        bne @cpe_tail
        sec                         ; all spaces = empty
        rts
@cpe_not_empty:
        clc                         ; has content
        rts

; ---- Draw status bar on row 24 ---------------------------------------------
; Shows "PAGE X/Y" in reversed characters on a light blue background.
; ---------------------------------------------------------------------------
draw_status_bar:
        ; Fill row 24 with reversed spaces ($A0)
        lda #$A0
        ldx #0
@dsb_fill:
        sta SCREEN + 24*40, x
        inx
        cpx #40
        bne @dsb_fill

        ; Write "PAGE " at col 1 (reversed screen codes: sc_X | $80)
        lda #(sc_P | $80)
        sta SCREEN + 24*40 + 1
        lda #(sc_A | $80)
        sta SCREEN + 24*40 + 2
        lda #(sc_G | $80)
        sta SCREEN + 24*40 + 3
        lda #(sc_E | $80)
        sta SCREEN + 24*40 + 4

        ; Current page number (1-based)
        lda current_page
        clc
        adc #1
        ora #$30                    ; digit → screen code
        ora #$80                    ; reversed
        sta SCREEN + 24*40 + 6

        ; "/"
        lda #($2F | $80)
        sta SCREEN + 24*40 + 7

        ; Total pages
        lda total_pages
        ora #$30
        ora #$80
        sta SCREEN + 24*40 + 8
        rts

; ---- Dialog system ----------------------------------------------------------
; Shows a message on row 24, waits for RETURN (confirm) or ← (cancel).
; Input: zp_src = pointer to null-terminated screen code string
; Output: carry clear = confirmed, carry set = cancelled
; ---------------------------------------------------------------------------
show_dialog:
        ; Save row 24 content
        ldx #39
@sd_save:
        lda SCREEN + 24*40, x
        sta dialog_save, x
        dex
        bpl @sd_save

        ; Fill row 24 with reversed spaces
        lda #$A0
        ldx #0
@sd_fill:
        sta SCREEN + 24*40, x
        inx
        cpx #40
        bne @sd_fill

        ; Display message (reversed)
        ldy #0
@sd_msg:
        lda (zp_src), y
        beq @sd_wait
        ora #$80                    ; reverse
        sta SCREEN + 24*40 + 1, y
        iny
        cpy #38
        bne @sd_msg

@sd_wait:
        ; Flush keyboard
        lda #0
        sta $C6
@sd_key:
        jsr KERNAL_GETIN
        beq @sd_key
        cmp #$0D                    ; RETURN = confirm
        beq @sd_confirm
        cmp #$5F                    ; ← (back-arrow) = cancel
        beq @sd_cancel
        jmp @sd_key

@sd_confirm:
        ; Restore row 24
        ldx #39
@sd_rest1:
        lda dialog_save, x
        sta SCREEN + 24*40, x
        dex
        bpl @sd_rest1
        clc                         ; confirmed
        rts

@sd_cancel:
        ; Restore row 24
        ldx #39
@sd_rest2:
        lda dialog_save, x
        sta SCREEN + 24*40, x
        dex
        bpl @sd_rest2
        sec                         ; cancelled
        rts

; ---- Ctrl+S: Save to disk --------------------------------------------------
do_ctrl_s:
        lda #<str_save_dialog
        sta zp_src
        lda #>str_save_dialog
        sta zp_src+1
        jsr show_dialog
        bcs @dcs_done               ; cancelled
        ; Save current page first
        jsr undraw_cursor
        jsr save_editor_page
        ; Store total_pages in save_header
        lda total_pages
        sta save_header
        ; KERNAL SAVE: set up logical file
        lda #1                      ; logical file #
        ldx #8                      ; device 8
        ldy #1                      ; secondary address 1
        jsr KERNAL_SETLFS
        ; Set filename "@0:TELEPROMPTER"
        lda #15                     ; filename length
        ldx #<str_save_fname
        ldy #>str_save_fname
        jsr KERNAL_SETNAM
        ; KERNAL SAVE: A = ZP addr of 2-byte start ptr, X/Y = end addr
        ; Store start address in zp_src
        lda #<save_header
        sta zp_src
        lda #>save_header
        sta zp_src+1
        ; Calculate end address: page_addr[total_pages]
        ldx total_pages
        lda page_addr_lo, x
        sta zp_dst                  ; temp end lo
        lda page_addr_hi, x
        sta zp_dst+1                ; temp end hi
        lda #zp_src                 ; A = ZP addr of start pointer
        ldx zp_dst                  ; X = end lo
        ldy zp_dst+1               ; Y = end hi
        jsr KERNAL_SAVE
        jsr draw_cursor
@dcs_done:
        jmp editor_loop

; ---- Ctrl+N: New document ---------------------------------------------------
do_ctrl_n:
        lda #<str_new_dialog
        sta zp_src
        lda #>str_new_dialog
        sta zp_src+1
        jsr show_dialog
        bcs @dcn_done               ; cancelled
        jsr undraw_cursor
        ; Fill entire doc_buffer with spaces (10 pages max = 9600 bytes)
        ; Just fill total_pages worth
        lda #<doc_buffer
        sta zp_dst
        lda #>doc_buffer
        sta zp_dst+1
        ; Fill 960 bytes (1 page)
        jsr fill_page_spaces
        lda #1
        sta total_pages
        lda #0
        sta current_page
        sta cursor_x
        sta cursor_y
        jsr load_editor_page
        jsr draw_status_bar
        jsr draw_cursor
@dcn_done:
        jmp editor_loop

; ---- Ctrl+O: Open from disk ------------------------------------------------
do_ctrl_o:
        lda #<str_open_dialog
        sta zp_src
        lda #>str_open_dialog
        sta zp_src+1
        jsr show_dialog
        bcs @dco_done               ; cancelled
        jsr undraw_cursor
        ; KERNAL LOAD
        lda #1                      ; logical file #
        ldx #8                      ; device 8
        ldy #1                      ; secondary 1 = load to file address
        jsr KERNAL_SETLFS
        lda #12                     ; filename length "TELEPROMPTER"
        ldx #<str_load_fname
        ldy #>str_load_fname
        jsr KERNAL_SETNAM
        lda #0                      ; LOAD (not VERIFY)
        ldx #<save_header           ; load address lo (when secondary=0)
        ldy #>save_header           ; load address hi
        jsr KERNAL_LOAD
        bcs @dco_error              ; carry set = error
        ; Read total_pages from save_header
        lda save_header
        sta total_pages
        lda #0
        sta current_page
        sta cursor_x
        sta cursor_y
        jsr load_editor_page
        jsr draw_status_bar
        jsr draw_cursor
        jmp editor_loop
@dco_error:
        ; Load failed — just restore display
        jsr draw_status_bar
        jsr draw_cursor
@dco_done:
        jmp editor_loop

; ---- Ctrl+CLR: Clear current page ----------------------------------------
do_ctrl_clr:
        jsr undraw_cursor
        ; Clear screen rows 0-23 with spaces
        lda #$20
        ldx #0
@dcc_loop:
        sta SCREEN, x
        sta SCREEN+256, x
        sta SCREEN+512, x
        inx
        bne @dcc_loop
        ldx #0
@dcc_tail:
        sta SCREEN+768, x
        inx
        cpx #192
        bne @dcc_tail
        ; Reset cursor to top-left
        lda #0
        sta cursor_x
        sta cursor_y
        jsr draw_cursor
        jmp editor_loop

; ---- Editor string data (screen codes, null-terminated) ---------------------
str_save_dialog:
        .byte sc_R,sc_E,sc_A,sc_D,sc_Y,__,sc_D,sc_I,sc_S,sc_K,_d
        .byte __,sc_R,sc_E,sc_T,sc_U,sc_R,sc_N,$2F,$1F,0
str_new_dialog:
        .byte sc_N,sc_E,sc_W,__,sc_D,sc_O,sc_C,sc_U,sc_M,sc_E,sc_N,sc_T,$3F
        .byte __,sc_R,sc_E,sc_T,sc_U,sc_R,sc_N,$2F,$1F,0
str_open_dialog:
        .byte sc_R,sc_E,sc_A,sc_D,sc_Y,__,sc_D,sc_I,sc_S,sc_K,_d
        .byte __,sc_R,sc_E,sc_T,sc_U,sc_R,sc_N,$2F,$1F,0

; Filenames for KERNAL file I/O (PETSCII)
str_save_fname:
        .byte "@0:TELEPROMPTER"     ; 15 chars, save with replace
str_load_fname:
        .byte "TELEPROMPTER"        ; 12 chars


; ---- Initialize document buffer from text_data --------------------------------
; Copies the instruction text (48 lines = 1920 bytes = 2 pages exactly)
; into doc_buffer.  No padding needed.
; Sets total_pages=2, current_page=0, cursor_x/y=0.
; ---------------------------------------------------------------------------
init_document:
        ; Source = text_data (48 lines × 40 bytes = 1920 bytes)
        lda #<text_data
        sta zp_src
        lda #>text_data
        sta zp_src+1

        ; Dest = doc_buffer
        lda #<doc_buffer
        sta zp_dst
        lda #>doc_buffer
        sta zp_dst+1

        ; Copy 1920 bytes = 7 × 256 + 128
        ldx #7
@id_page:
        ldy #0
@id_byte:
        lda (zp_src), y
        sta (zp_dst), y
        iny
        bne @id_byte
        inc zp_src+1
        inc zp_dst+1
        dex
        bne @id_page

        ; Copy remaining 128 bytes
        ldy #0
@id_tail:
        lda (zp_src), y
        sta (zp_dst), y
        iny
        cpy #128
        bne @id_tail

        ; Set editor state
        lda #2
        sta total_pages
        lda #0
        sta current_page
        sta cursor_x
        sta cursor_y
        rts


; ---- Prepare scroll text from doc_buffer -----------------------------------
; Sets scroll_start/scroll_end and text_lo/hi for the scroller.
; Appends 1000 bytes (25 blank lines) as scroll_trail after document content.
; ---------------------------------------------------------------------------
prepare_scroll_text:
        ; Note: editor page is already saved by ed_exit before we get here.
        ; Do NOT call save_editor_page — screen may contain config/scroll content.

        ; scroll_start = doc_buffer
        lda #<doc_buffer
        sta scroll_start_lo
        lda #>doc_buffer
        sta scroll_start_hi

        ; Calculate end of document content: doc_buffer + total_pages * 960
        ; Use page_addr_lo/hi table: entry [total_pages] gives the address
        ldx total_pages
        lda page_addr_lo, x
        sta zp_dst
        lda page_addr_hi, x
        sta zp_dst+1

        ; Fill scroll_trail (1000 bytes of spaces after document content)
        lda #$20
        ldy #0
@pst_fill1:
        sta (zp_dst), y
        iny
        bne @pst_fill1
        inc zp_dst+1
        ldy #0
@pst_fill2:
        sta (zp_dst), y
        iny
        bne @pst_fill2
        inc zp_dst+1
        ldy #0
@pst_fill3:
        sta (zp_dst), y
        iny
        bne @pst_fill3
        inc zp_dst+1
        ; 768 done, 232 more
        ldy #0
@pst_fill4:
        sta (zp_dst), y
        iny
        cpy #232
        bne @pst_fill4

        ; scroll_end = doc_buffer + total_pages*960 + 1000
        ; = page_addr[total_pages] + 1000
        ; 1000 = $03E8
        ldx total_pages
        clc
        lda page_addr_lo, x
        adc #<1000
        sta scroll_end_lo
        lda page_addr_hi, x
        adc #>1000
        sta scroll_end_hi

        ; text_lo/hi = scroll_start (beginning of document)
        lda scroll_start_lo
        sta text_lo
        lda scroll_start_hi
        sta text_hi
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

        ; Wrap if source < scroll_start
        lda zp_src+1
        cmp scroll_start_hi
        bcc @rf_wrap
        bne @rf_no_wrap
        lda zp_src
        cmp scroll_start_lo
        bcs @rf_no_wrap
@rf_wrap:
        ; Add text length = scroll_end - scroll_start
        sec
        lda scroll_end_lo
        sbc scroll_start_lo
        pha                     ; text_len_lo
        lda scroll_end_hi
        sbc scroll_start_hi
        tay                     ; text_len_hi
        clc
        pla
        adc zp_src
        sta zp_src
        tya
        adc zp_src+1
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

        ; Wrap source if >= scroll_end
        lda zp_src+1
        cmp scroll_end_hi
        bcc @rf_no_src_wrap
        bne @rf_src_wrap
        lda zp_src
        cmp scroll_end_lo
        bcc @rf_no_src_wrap
@rf_src_wrap:
        lda scroll_start_lo
        sta zp_src
        lda scroll_start_hi
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

; ---------------------------------------------------------------------------
;  Save buffers for scroll_screen_down inter-page overlaps (3×40 bytes)
;  When copying pages 0→1→2→3, each page's +40 shift overwrites the first
;  40 bytes of the next page's source.  These buffers preserve those bytes.
; ---------------------------------------------------------------------------
save_buf_a: .res 40                     ; original SCREEN+256..295
save_buf_b: .res 40                     ; original SCREEN+512..551
save_buf_c: .res 40                     ; original SCREEN+768..807

; ---------------------------------------------------------------------------
;  Variable scroll boundaries (set by prepare_scroll_text)
; ---------------------------------------------------------------------------
scroll_start_lo: .byte 0
scroll_start_hi: .byte 0
scroll_end_lo:   .byte 0
scroll_end_hi:   .byte 0

; ---------------------------------------------------------------------------
;  Dialog row 24 save buffer (40 bytes)
; ---------------------------------------------------------------------------
dialog_save: .res 40

; ---------------------------------------------------------------------------
;  KERNAL file I/O addresses
; ---------------------------------------------------------------------------
KERNAL_SETLFS   = $FFBA
KERNAL_SETNAM   = $FFBD
KERNAL_OPEN     = $FFC0
KERNAL_CLOSE    = $FFC3
KERNAL_CHKIN    = $FFC6
KERNAL_CHKOUT   = $FFC9
KERNAL_CLRCHN   = $FFCC
KERNAL_CHRIN    = $FFCF
KERNAL_SAVE     = $FFD8
KERNAL_LOAD     = $FFD5

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
_sl = $2F      ; slash
_pl = $2B      ; plus
_co = $3A      ; colon
_eq = $3D      ; equals
_da = $2D      ; dash/minus
_0 = $30
_1 = $31
_2 = $32
_3 = $33
_4 = $34
_5 = $35
_6 = $36
_7 = $37
_8 = $38
_9 = $39

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

; Page address table: page_addr[N] = doc_buffer + N * 960
; 11 entries (pages 0-10, where entry 10 = end of 10 pages)
; 960 = $03C0
page_addr_lo:
        .byte <(doc_buffer)
        .byte <(doc_buffer + 960)
        .byte <(doc_buffer + 1920)
        .byte <(doc_buffer + 2880)
        .byte <(doc_buffer + 3840)
        .byte <(doc_buffer + 4800)
        .byte <(doc_buffer + 5760)
        .byte <(doc_buffer + 6720)
        .byte <(doc_buffer + 7680)
        .byte <(doc_buffer + 8640)
        .byte <(doc_buffer + 9600)
page_addr_hi:
        .byte >(doc_buffer)
        .byte >(doc_buffer + 960)
        .byte >(doc_buffer + 1920)
        .byte >(doc_buffer + 2880)
        .byte >(doc_buffer + 3840)
        .byte >(doc_buffer + 4800)
        .byte >(doc_buffer + 5760)
        .byte >(doc_buffer + 6720)
        .byte >(doc_buffer + 7680)
        .byte >(doc_buffer + 8640)
        .byte >(doc_buffer + 9600)

; Blank row macro
.define BLK __,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__

text_data:
; --- Page 1: Intro + Config + Editor controls ---
;         1234567890123456789012345678901234567890
; Line 0: "               QPROMPT 64              "
.byte __,__,__,__,__,__,__,__,__,__,__,__,__,__,__,sc_Q,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,__,_6,_4,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 1: "               ----------              "
.byte __,__,__,__,__,__,__,__,__,__,__,__,__,__,__,_da,_da,_da,_da,_da,_da,_da,_da,_da,_da,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 2: blank
.byte BLK
; Line 3: " WELCOME TO QPROMPT 64, A              "
.byte __,sc_W,sc_E,sc_L,sc_C,sc_O,sc_M,sc_E,__,sc_T,sc_O,__,sc_Q,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,__,_6,_4,_c,__,sc_A,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 4: " TELEPROMPTER FOR THE                  "
.byte __,sc_T,sc_E,sc_L,sc_E,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,sc_E,sc_R,__,sc_F,sc_O,sc_R,__,sc_T,sc_H,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 5: " COMMODORE 64.                         "
.byte __,sc_C,sc_O,sc_M,sc_M,sc_O,sc_D,sc_O,sc_R,sc_E,__,_6,_4,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 6: blank
.byte BLK
; Line 7: " CONFIG SCREEN:                        "
.byte __,sc_C,sc_O,sc_N,sc_F,sc_I,sc_G,__,sc_S,sc_C,sc_R,sc_E,sc_E,sc_N,_co,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 8: blank
.byte BLK
; Line 9: "  UP/DOWN     ADJUST BASE SPEED        "
.byte __,__,sc_U,sc_P,_sl,sc_D,sc_O,sc_W,sc_N,__,__,__,__,__,sc_A,sc_D,sc_J,sc_U,sc_S,sc_T,__,sc_B,sc_A,sc_S,sc_E,__,sc_S,sc_P,sc_E,sc_E,sc_D,__,__,__,__,__,__,__,__,__
; Line 10: "  LEFT/RIGHT  ADJUST CURVE             "
.byte __,__,sc_L,sc_E,sc_F,sc_T,_sl,sc_R,sc_I,sc_G,sc_H,sc_T,__,__,sc_A,sc_D,sc_J,sc_U,sc_S,sc_T,__,sc_C,sc_U,sc_R,sc_V,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 11: "  RETURN      START                    "
.byte __,__,sc_R,sc_E,sc_T,sc_U,sc_R,sc_N,__,__,__,__,__,__,sc_S,sc_T,sc_A,sc_R,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 12: "  F3          OPEN EDITOR              "
.byte __,__,sc_F,_3,__,__,__,__,__,__,__,__,__,__,sc_O,sc_P,sc_E,sc_N,__,sc_E,sc_D,sc_I,sc_T,sc_O,sc_R,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 13: "  F5          START SCROLL             "
.byte __,__,sc_F,_5,__,__,__,__,__,__,__,__,__,__,sc_S,sc_T,sc_A,sc_R,sc_T,__,sc_S,sc_C,sc_R,sc_O,sc_L,sc_L,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 14: blank
.byte BLK
; Line 15: " EDITOR:                               "
.byte __,sc_E,sc_D,sc_I,sc_T,sc_O,sc_R,_co,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 16: blank
.byte BLK
; Line 17: "  TYPE TO ENTER TEXT.                   "
.byte __,__,sc_T,sc_Y,sc_P,sc_E,__,sc_T,sc_O,__,sc_E,sc_N,sc_T,sc_E,sc_R,__,sc_T,sc_E,sc_X,sc_T,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 18: "  USE CURSOR KEYS TO MOVE.             "
.byte __,__,sc_U,sc_S,sc_E,__,sc_C,sc_U,sc_R,sc_S,sc_O,sc_R,__,sc_K,sc_E,sc_Y,sc_S,__,sc_T,sc_O,__,sc_M,sc_O,sc_V,sc_E,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 19: "  F7  NEXT PAGE                        "
.byte __,__,sc_F,_7,__,__,sc_N,sc_E,sc_X,sc_T,__,sc_P,sc_A,sc_G,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 20: "  F8  PREVIOUS PAGE                    "
.byte __,__,sc_F,_8,__,__,sc_P,sc_R,sc_E,sc_V,sc_I,sc_O,sc_U,sc_S,__,sc_P,sc_A,sc_G,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 21: "  F1  GO TO CONFIG SCREEN              "
.byte __,__,sc_F,_1,__,__,sc_G,sc_O,__,sc_T,sc_O,__,sc_C,sc_O,sc_N,sc_F,sc_I,sc_G,__,sc_S,sc_C,sc_R,sc_E,sc_E,sc_N,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 22: "  F3  START SCROLLING                  "
.byte __,__,sc_F,_3,__,__,sc_S,sc_T,sc_A,sc_R,sc_T,__,sc_S,sc_C,sc_R,sc_O,sc_L,sc_L,sc_I,sc_N,sc_G,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 23: "  F5  START SCROLLING                  "
.byte __,__,sc_F,_5,__,__,sc_S,sc_T,sc_A,sc_R,sc_T,__,sc_S,sc_C,sc_R,sc_O,sc_L,sc_L,sc_I,sc_N,sc_G,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__

; --- Page 2: Editor Ctrl keys + Scroll controls ---
; Line 0: "  CTRL+S    SAVE TO DISK               "
.byte __,__,sc_C,sc_T,sc_R,sc_L,_pl,sc_S,__,__,__,__,sc_S,sc_A,sc_V,sc_E,__,sc_T,sc_O,__,sc_D,sc_I,sc_S,sc_K,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 1: "  CTRL+O    LOAD FROM DISK             "
.byte __,__,sc_C,sc_T,sc_R,sc_L,_pl,sc_O,__,__,__,__,sc_L,sc_O,sc_A,sc_D,__,sc_F,sc_R,sc_O,sc_M,__,sc_D,sc_I,sc_S,sc_K,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 2: "  CTRL+N    NEW DOCUMENT               "
.byte __,__,sc_C,sc_T,sc_R,sc_L,_pl,sc_N,__,__,__,__,sc_N,sc_E,sc_W,__,sc_D,sc_O,sc_C,sc_U,sc_M,sc_E,sc_N,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 3: "  CTRL+CLR  CLEAR CURRENT PAGE         "
.byte __,__,sc_C,sc_T,sc_R,sc_L,_pl,sc_C,sc_L,sc_R,__,__,sc_C,sc_L,sc_E,sc_A,sc_R,__,sc_C,sc_U,sc_R,sc_R,sc_E,sc_N,sc_T,__,sc_P,sc_A,sc_G,sc_E,__,__,__,__,__,__,__,__,__,__
; Line 4: blank
.byte BLK
; Line 5: " SCROLL SCREEN:                        "
.byte __,sc_S,sc_C,sc_R,sc_O,sc_L,sc_L,__,sc_S,sc_C,sc_R,sc_E,sc_E,sc_N,_co,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 6: blank
.byte BLK
; Line 7: "  KEYS 1 TO 9, 0  SET SPEED            "
.byte __,__,sc_K,sc_E,sc_Y,sc_S,__,_1,__,sc_T,sc_O,__,_9,_c,__,_0,__,__,sc_S,sc_E,sc_T,__,sc_S,sc_P,sc_E,sc_E,sc_D,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 8: "  1=SLOWEST  0=FASTEST                 "
.byte __,__,_1,_eq,sc_S,sc_L,sc_O,sc_W,sc_E,sc_S,sc_T,__,__,_0,_eq,sc_F,sc_A,sc_S,sc_T,sc_E,sc_S,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 9: "  SHIFT LOCK   REVERSE SCROLL          "
.byte __,__,sc_S,sc_H,sc_I,sc_F,sc_T,__,sc_L,sc_O,sc_C,sc_K,__,__,__,sc_R,sc_E,sc_V,sc_E,sc_R,sc_S,sc_E,__,sc_S,sc_C,sc_R,sc_O,sc_L,sc_L,__,__,__,__,__,__,__,__,__,__,__
; Line 10: "  F1  GO TO CONFIG SCREEN              "
.byte __,__,sc_F,_1,__,__,sc_G,sc_O,__,sc_T,sc_O,__,sc_C,sc_O,sc_N,sc_F,sc_I,sc_G,__,sc_S,sc_C,sc_R,sc_E,sc_E,sc_N,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 11: "  F3  OPEN EDITOR                      "
.byte __,__,sc_F,_3,__,__,sc_O,sc_P,sc_E,sc_N,__,sc_E,sc_D,sc_I,sc_T,sc_O,sc_R,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Lines 12-13: blank
.byte BLK
.byte BLK
; Line 14: "  EDIT THIS DOCUMENT TO ADD            "
.byte __,__,sc_E,sc_D,sc_I,sc_T,__,sc_T,sc_H,sc_I,sc_S,__,sc_D,sc_O,sc_C,sc_U,sc_M,sc_E,sc_N,sc_T,__,sc_T,sc_O,__,sc_A,sc_D,sc_D,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 15: "  YOUR OWN TELEPROMPTER                "
.byte __,__,sc_Y,sc_O,sc_U,sc_R,__,sc_O,sc_W,sc_N,__,sc_T,sc_E,sc_L,sc_E,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,sc_E,sc_R,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 16: "  SCRIPT, THEN PRESS F3 OR             "
.byte __,__,sc_S,sc_C,sc_R,sc_I,sc_P,sc_T,_c,__,sc_T,sc_H,sc_E,sc_N,__,sc_P,sc_R,sc_E,sc_S,sc_S,__,sc_F,_3,__,sc_O,sc_R,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 17: "  F5 TO START SCROLLING.               "
.byte __,__,sc_F,_5,__,sc_T,sc_O,__,sc_S,sc_T,sc_A,sc_R,sc_T,__,sc_S,sc_C,sc_R,sc_O,sc_L,sc_L,sc_I,sc_N,sc_G,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Lines 18-23: blank
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK
.byte BLK

text_data_end:

; =============================================================================
;  Sprite data at $3000 — dedicated SPRITES segment
;  Right-pointing (►) for left side, Left-pointing (◄) for right side
;  Each sprite: 24×21 pixels = 63 bytes + 1 pad = 64 bytes
;  Sprite 0 pointer = $3000/64 = $C0
;  Sprite 1 pointer = $3040/64 = $C1
; =============================================================================
.segment "SPRITES"

spr_right_tri:  ; at $3000
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

spr_left_tri:   ; at $3040
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

; =============================================================================
;  BSS segment — runtime-only document buffer (not stored in PRG file)
; =============================================================================
.segment "BSS"

save_header:    .res 1              ; total_pages (saved to disk as first byte)
doc_buffer:     .res 9600           ; 10 pages × 960 bytes (24 rows × 40 cols)
