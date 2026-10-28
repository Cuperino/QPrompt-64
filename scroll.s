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
ROWS            = 25

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
cs_pending:     .res 1              ; coarse scroll requested by IRQ: 0=none, 1=up, 2=down
current_step:   .res 1              ; current velocity step (0-9)
direction:      .res 1              ; 1=forward (up), $FF=reverse (down)
scroll_accum:   .res 1              ; fractional accumulator (8.8 low byte)
cs_commit:      .res 1              ; set by main loop: 1=copy started, 2=fwd limit, 3=rev floor
enter_config:   .res 1              ; flag: 0=none, 1=config, 2=editor
cursor_x:       .res 1              ; editor cursor column 0-39
cursor_y:       .res 1              ; editor cursor row 0-23
current_page:   .res 1              ; 0-based page number
total_pages:    .res 1              ; number of pages (1-based, max 10)
came_from:      .res 1              ; 0=initial, 1=editor, 2=scroll
first_run:      .res 1              ; 1=first RETURN on config goes to editor

; Render engine cursor state ($0016-$001D)
rnd_top_lo:     .res 1              ; top cursor: doc ptr lo (start of current top rendered line)
rnd_top_hi:     .res 1              ; top cursor: doc ptr hi
rnd_top_row:    .res 1              ; top cursor: tile row 0-2 currently at screen row 0
rnd_bot_lo:     .res 1              ; bot cursor: doc ptr lo (start of current bottom rendered line)
rnd_bot_hi:     .res 1              ; bot cursor: doc ptr hi
rnd_bot_row:    .res 1              ; bot cursor: next tile row 0-2 to add at bottom
rnd_out_lo:     .res 1              ; render work: output ptr lo
rnd_out_hi:     .res 1              ; render work: output ptr hi
rnd_wk_csrc:    .res 2              ; ZP: working source ptr for render word-measure and save

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
        ; --- Detect PAL or NTSC system ---
        jsr detect_pal_ntsc

        ; --- Config screen (runs with KERNAL IRQs still active) ---
        jsr config_screen_init
        jsr init_document

        ; First config screen — returns destination in A
        jsr config_screen
        pha
        lda #$36                    ; bank out BASIC ROM — BSS is under it
        sta $01
        pla

; --- Top-level dispatch: A = 0 (scroll/resume), 1 (editor), 2 (scroll/F3) ---
main_dispatch:
        cmp #1
        beq @md_editor
        cmp #2
        beq @md_scroll_f3
        ; A=0: scroll — resume if saved, else fresh
        lda scroll_has_saved
        beq @md_fresh
        lda #1
        sta scroll_entry_mode       ; F5 resume
        jmp enter_scroll_mode
@md_fresh:
        lda #0
        sta scroll_entry_mode       ; fresh start
        jmp enter_scroll_mode
@md_scroll_f3:
        lda #2
        sta scroll_entry_mode       ; F3 jump to cursor
        jmp enter_scroll_mode

@md_editor:
        lda #0
        sta VIC_BORDER
        sta VIC_BG
        jsr enter_editor
        ; Editor returned — A: 0=go to config, 1=scroll(F5), 2=scroll(F3)
        cmp #0
        beq @md_to_config
        cmp #2
        beq @md_ed_f3
        ; A=1: F5 resume scroll
        lda scroll_has_saved
        beq @md_ed_fresh
        lda #1
        sta scroll_entry_mode
        jmp enter_scroll_mode
@md_ed_fresh:
        lda #0
        sta scroll_entry_mode
        jmp enter_scroll_mode
@md_ed_f3:
        lda #2
        sta scroll_entry_mode
        jmp enter_scroll_mode
@md_to_config:
        lda #$0E
        sta VIC_BORDER
        lda #$06
        sta VIC_BG
        lda #$37                    ; bank in BASIC ROM for config_screen
        sta $01
        jsr config_screen
        lda #$36                    ; bank out BASIC ROM — BSS is under it
        sta $01
        jmp main_dispatch

; --- Enter scroll mode and run scroll loop ---
enter_scroll_mode:
        lda #$37                    ; bank in BASIC ROM for float routines
        sta $01
        jsr build_velocity_table
        lda #$36                    ; bank out BASIC ROM — BSS is under it
        sta $01
        lda #2
        sta came_from               ; mark that we're in scroll mode
        jsr prepare_scroll_text

        sei

        ; Wait for VBlank to prevent mid-frame VIC changes
@enter_vbl:
        lda VIC_RASTER
        cmp #251
        bcc @enter_vbl

        ; Black border and background
        lda #0
        sta VIC_BORDER
        sta VIC_BG

        ; Blank display during setup (DEN=0); re-enabled by IRQ state 2
        lda #$0B                    ; RSEL=1, DEN=0, YSCROLL=3
        sta VIC_CTRL1

        ; Clear screen with spaces and set colour RAM
        jsr clear_screen

        ; Initialise scroll state
        lda #7
        sta fine_scroll
        lda #0                      ; start at step 0 (stationary)
        sta current_step
        lda #1                      ; forward direction
        sta direction
        lda #0
        sta scroll_accum
        sta cs_pending
        sta cs_commit
        sta enter_config
        sta fwd_limit_reached

        ; 40-col mode
        lda #$08                    ; CSEL=1, XSCROLL=0
        sta VIC_CTRL2

        ; --- Set up sprites ---
        ; Sprite data pointers: sprite 0 at $3F00/64=$FC, sprite 1 at $3F40/64=$FD
        lda #$FC
        sta SPR_PTR                 ; Sprite 0 = right-pointing triangle
        lda #$FD
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

        ; Switch to custom charset at $3800 for large-character rendering
        lda #$1E                    ; screen@$0400, charset@$3800 (bank 0)
        sta $D018

        ; Re-enable Commodore+Shift charset toggle (disabled during editor/config)
        lda #$00
        sta $0291

        ; Count rendered content lines and compute forward scroll limit
        jsr count_rendered_lines

        ; Build render state and fill screen with large-character tiles
        lda scroll_entry_mode
        cmp #1
        beq @esm_resume
        cmp #2
        beq @esm_f3
        cmp #3
        beq @esm_direct_target
        ; Mode 0: fresh start
        jsr render_init
        jmp @esm_install_irq
@esm_resume:
        ; F5 resume: restore saved position
        lda saved_rows_lo
        sta target_rows_lo
        lda saved_rows_hi
        sta target_rows_hi
        jsr clamp_target_rows
        jsr render_init_at_position
        lda saved_fine_scroll
        sta fine_scroll
        jmp @esm_install_irq
@esm_f3:
        ; F3: jump to cursor position
        jsr compute_f3_target
@esm_direct_target:
        jsr clamp_target_rows
        jsr render_init_at_position
        jmp @esm_install_irq

@esm_install_irq:
        ; Set reverse scroll floor to current position
        lda rows_from_start_lo
        sta reverse_floor_lo
        lda rows_from_start_hi
        sta reverse_floor_hi
        ; Save initial top doc pointer for retreat clamping
        lda rnd_top_lo
        sta init_top_lo
        lda rnd_top_hi
        sta init_top_hi
        ; ---- Install raster IRQ chain ----
        lda #$7F
        sta CIA1_ICR                ; disable CIA timer IRQs
        lda CIA1_ICR                ; acknowledge pending

        lda #$01
        sta VIC_IRQ_MASK            ; enable VIC raster IRQ

        ; Start with zone-on IRQ (fires 2 lines early for stable raster)
        lda #0
        sta irq_state

        lda fine_scroll
        sta next_fine               ; nothing pending: next frame = same
        ora #%00010000              ; DEN=1, YSCROLL=fine_scroll
        sta VIC_CTRL1
        lda #(RASTER_ZONE_ON - 3)
        sta VIC_RASTER

        ; Point IRQ vector
        lda #<irq_handler
        sta $0314
        lda #>irq_handler
        sta $0315

        cli

; Main loop — services coarse-scroll requests from the IRQ.
; The IRQ computes each frame's fine scroll one frame ahead; when it needs a
; coarse scroll it sets cs_pending.  The coarse routines start their copy just
; after the beam has fetched the top rows, so the copy runs behind the beam
; and has a full frame to finish before the new layout is shown.
@forever:
        lda enter_config
        bne @exit_req
        lda cs_pending
        bne @service
        jmp @forever
@service:
        cmp #1
        bne @svc_down
        jsr scroll_screen_up
        jmp @forever
@svc_down:
        jsr scroll_screen_down
        jmp @forever
@exit_req:
        ; Don't leave while a started copy waits for its YSCROLL update.
        ; IRQs stay disabled from here on (disable_raster_restore_kernal
        ; re-enables them), so no new request can slip in.
        sei
        lda cs_commit
        beq @exit_ok
        cli
        jmp @forever
@exit_ok:
        sta cs_pending              ; drop a coarse request that never started
@exit_scroll:
        ; enter_config: 1=F1, 2=F3, 3=T, 4=search prev #, 5=search next #
        lda enter_config
        cmp #3
        beq @scroll_reset
        cmp #4
        beq @search_prev_hash
        cmp #5
        beq @search_next_hash
        ; Save scroll position for F5 resume
        lda rows_from_start_lo
        sta saved_rows_lo
        lda rows_from_start_hi
        sta saved_rows_hi
        lda fine_scroll
        sta saved_fine_scroll
        lda #1
        sta scroll_has_saved
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
        lda #$37                    ; bank in BASIC ROM for config_screen
        sta $01
        jsr config_screen
        lda #$36                    ; bank out BASIC ROM — BSS is under it
        sta $01
        jmp main_dispatch

@scroll_reset:
        ; --- T: reset scroll to start of document ---
        lda #0
        sta enter_config
        sta scroll_has_saved
        sta scroll_entry_mode       ; fresh start
        jsr disable_raster_restore_kernal
        jmp enter_scroll_mode

@search_prev_hash:
        ; --- Comma/<: search backward for previous # ---
        lda #0
        sta enter_config
        jsr disable_raster_restore_kernal
        jsr search_hash_prev        ; sets target_rows_lo/hi
        lda #3
        sta scroll_entry_mode       ; direct target positioning
        jmp enter_scroll_mode

@search_next_hash:
        ; --- Period/>: search forward for next # ---
        ; Save current position in case search fails
        lda rows_from_start_lo
        sta saved_rows_lo
        lda rows_from_start_hi
        sta saved_rows_hi
        lda fine_scroll
        sta saved_fine_scroll
        lda #1
        sta scroll_has_saved
        lda #0
        sta enter_config
        jsr disable_raster_restore_kernal
        jsr search_hash_next
        bcc @snh_found
        ; Not found — resume at current position
        lda #1
        sta scroll_entry_mode       ; F5 resume
        jmp enter_scroll_mode
@snh_found:
        lda #3
        sta scroll_entry_mode       ; direct target positioning
        jmp enter_scroll_mode

@scroll_to_editor:
        ; --- F3: go directly to editor ---
        lda #0
        sta VIC_BORDER
        sta VIC_BG
        jsr enter_editor
        ; Editor returned — A: 0=config, 1=scroll(F5), 2=scroll(F3)
        cmp #2
        beq @ste_f3
        cmp #1
        beq @ste_f5
        jmp @ste_to_config
@ste_f5:
        lda scroll_has_saved
        beq @ste_fresh
        lda #1
        sta scroll_entry_mode
        jmp enter_scroll_mode
@ste_fresh:
        lda #0
        sta scroll_entry_mode
        jmp enter_scroll_mode
@ste_f3:
        lda #2
        sta scroll_entry_mode
        jmp enter_scroll_mode
@ste_to_config:
        lda #$0E
        sta VIC_BORDER
        lda #$06
        sta VIC_BG
        lda #$37                    ; bank in BASIC ROM for config_screen
        sta $01
        jsr config_screen
        lda #$36                    ; bank out BASIC ROM — BSS is under it
        sta $01
        jmp main_dispatch


; ---- Clear screen -----------------------------------------------------------
clear_screen:
        lda #$20                    ; space screen code
        ldx #0
@cs1:   .repeat 8
        sta SCREEN, x
        sta SCREEN+256, x
        sta SCREEN+512, x
        sta SCREEN+744, x
        inx
        .endrepeat
        bne @cs1

        ; Colour RAM: rows 0-8 = base (bytes 0-359)
        ;            rows 9-15 = light (bytes 360-639)
        ;            rows 16-24 = base (bytes 640-999)
        ; Split across pages since X is 8-bit only.

        ; Bytes 0-255: rows 0-6 (base = $0F default light gray)
        lda #WHITE
        ldx #0
@cr0:   .repeat 8
        sta COLRAM, x
        inx
        .endrepeat
        bne @cr0

        ; Bytes 256-359: rows 7-8 (base)
        lda #WHITE
        ldx #0
@cr1a:  .repeat 8
        sta COLRAM+256, x
        inx
        .endrepeat
        cpx #104
        bne @cr1a

        ; Bytes 360-511: rows 9-12 (light = $01 white)
        lda #LIGHT_GRAY
        ldx #104
@cr1b:  .repeat 8
        sta COLRAM+256, x
        inx
        .endrepeat
        bne @cr1b

        ; Bytes 512-639: rows 12-15 (light)
        lda #LIGHT_GRAY
        ldx #0
@cr2a:  .repeat 8
        sta COLRAM+512, x
        inx
        .endrepeat
        cpx #128
        bne @cr2a

        ; Bytes 640-767: rows 16-19 (base)
        lda #WHITE
        ldx #128
@cr2b:  .repeat 8
        sta COLRAM+512, x
        inx
        .endrepeat
        bne @cr2b

        ; Page 3: COLRAM+768..1023 (rows 19-24, base)
        lda #WHITE
        ldx #0
@cr3:   .repeat 8
        sta COLRAM+768, x
        inx
        .endrepeat
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
@cp_ac: lda fp_1_20, x
        sta cfg_accel_curv, x
        dex
        bpl @cp_ac
        ; Set first_run and came_from
        lda #1
        sta first_run
        lda #0
        sta came_from
        ; Initialize color settings
        lda #$0F
        sta cfg_font_color          ; default light gray
        lda #$0B
        sta cfg_bg_color            ; default dark gray
        rts

config_screen:
        ; Disable Commodore+Shift charset toggle
        lda #$80
        sta $0291
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
        jsr @update_speed
        jmp @cfg_loop
@clamp_speed_hi:
        ldx #4
@csh:   lda fp_4_0, x
        sta cfg_base_speed, x
        dex
        bpl @csh
        jsr @update_speed
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
        jsr @update_speed
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
        jsr @update_curv
        jmp @cfg_loop
@clamp_curv_hi:
        ldx #4
@cch:   lda fp_2_0, x
        sta cfg_accel_curv, x
        dex
        bpl @cch
        jsr @update_curv
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
        jsr @update_curv
        jmp @cfg_loop

; --- Update just the base speed value on screen ---
@update_speed:
        lda #<(SCREEN + 5*40 + 20)
        sta zp_dst
        lda #>(SCREEN + 5*40 + 20)
        sta zp_dst+1
        lda #<cfg_base_speed
        ldy #>cfg_base_speed
        jmp display_fixed2
; --- Update just the curvature value on screen ---
@update_curv:
        lda #<(SCREEN + 7*40 + 20)
        sta zp_dst
        lda #>(SCREEN + 7*40 + 20)
        sta zp_dst+1
        lda #<cfg_accel_curv
        ldy #>cfg_accel_curv
        jmp display_fixed2

; --- Draw config screen ---
@draw_config:
        ; Clear screen
        lda #$20
        ldx #0
@dcs:   .repeat 8
        sta SCREEN, x
        sta SCREEN+256, x
        sta SCREEN+512, x
        sta SCREEN+744, x
        inx
        .endrepeat
        bne @dcs

        ; Display values
        jsr @update_speed
        jsr @update_curv

        ; Draw all config strings (including labels) via table
        ldx #0
@draw_strs:
        lda @str_tbl_lo, x
        sta @ds_lda+1
        lda @str_tbl_hi, x
        sta @ds_lda+2
        lda @scr_tbl_lo, x
        sta @ds_sta+1
        lda @scr_tbl_hi, x
        sta @ds_sta+2
        stx @ds_savx+1
        ldy #0
@ds_lda:
        lda $FFFF, y
        beq @ds_next
@ds_sta:
        sta $FFFF, y
        iny
        bne @ds_lda
@ds_next:
@ds_savx:
        ldx #0
        inx
        cpx #10
        bne @draw_strs
        ; Set all color RAM to white
        lda #WHITE
        ldx #0
@ccr:   .repeat 8
        sta COLRAM, x
        sta COLRAM+256, x
        sta COLRAM+512, x
        sta COLRAM+768, x
        inx
        .endrepeat
        bne @ccr

        ; Re-enable display (may have been blanked during scroll→config transition)
        lda #$1B
        sta VIC_CTRL1
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
        .byte sc_F,_5,__,$3D,__,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,sc_E,sc_R,0
@str_instr4:
        .byte sc_F,_3,__,$3D,__,sc_E,sc_D,sc_I,sc_T,sc_O,sc_R,0
@str_velocity:
        .byte sc_N,sc_U,sc_M,sc_B,sc_E,sc_R,sc_S,__,sc_A,sc_N,sc_D,__,sc_S,sc_H,sc_I,sc_F,sc_T,__,sc_C,sc_O,sc_N,sc_T,sc_R,sc_O,sc_L,__,sc_V,sc_E,sc_L,sc_O,sc_C,sc_I,sc_T,sc_Y,0
@str_title:
        .byte sc_Q,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,__,_6,_4,0
@str_copyright:
        .byte sc_C,sc_O,sc_P,sc_Y,sc_R,sc_I,sc_G,sc_H,sc_T,__,_2,_0,_2,_6,__,sc_J,sc_A,sc_V,sc_I,sc_E,sc_R,__,sc_O,_d,__,sc_C,sc_O,sc_R,sc_D,sc_E,sc_R,sc_O,__,sc_P,sc_E,sc_R,sc_E,sc_Z,0
@str_license:
        .byte sc_L,sc_I,sc_C,sc_E,sc_N,sc_S,sc_E,sc_D,__,sc_U,sc_N,sc_D,sc_E,sc_R,__,sc_C,sc_R,sc_E,sc_A,sc_T,sc_I,sc_V,sc_E,__,sc_C,sc_O,sc_M,sc_M,sc_O,sc_N,sc_S,__,_0,0

; String/screen address tables for table-driven config renderer
@str_tbl_lo:
        .byte <@str_base_speed, <@str_accel_curv
        .byte <@str_instr1, <@str_instr2, <@str_instr4, <@str_instr3
        .byte <@str_velocity, <@str_title, <@str_copyright, <@str_license
@str_tbl_hi:
        .byte >@str_base_speed, >@str_accel_curv
        .byte >@str_instr1, >@str_instr2, >@str_instr4, >@str_instr3
        .byte >@str_velocity, >@str_title, >@str_copyright, >@str_license
@scr_tbl_lo:
        .byte <(SCREEN+5*40+2), <(SCREEN+7*40+2)
        .byte <(SCREEN+9*40+3), <(SCREEN+10*40+3), <(SCREEN+12*40+3), <(SCREEN+13*40+3)
        .byte <(SCREEN+15*40+2), <(SCREEN+2*40+14), <(SCREEN+22*40+1), <(SCREEN+23*40+4)
@scr_tbl_hi:
        .byte >(SCREEN+5*40+2), >(SCREEN+7*40+2)
        .byte >(SCREEN+9*40+3), >(SCREEN+10*40+3), >(SCREEN+12*40+3), >(SCREEN+13*40+3)
        .byte >(SCREEN+15*40+2), >(SCREEN+2*40+14), >(SCREEN+22*40+1), >(SCREEN+23*40+4)


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
        lda cfg_bg_color
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
        lda cfg_bg_color
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
        ; Fine scroll is pipelined one frame: this IRQ shows the value
        ; computed last frame, then computes the next one.  When the next
        ; value needs a coarse scroll, the main loop does the copy during the
        ; coming frame (behind the beam) and the result is shown here at the
        ; following vblank.
        lda #(RASTER_ZONE_ON - 3)
        sta VIC_RASTER
        lda #0
        sta irq_state
        inc frame_ctr

        ; --- Apply ---
        lda cs_commit
        beq @s2_no_commit
        ldx #0
        stx cs_commit
        cmp #1
        beq @s2_apply               ; copy underway → show post-coarse value
        ; Main loop hit a limit (2 = forward limit, 3 = reverse floor):
        ; snap fine scroll and stop
        stx current_step
        stx scroll_accum
        cmp #2
        beq @s2_lim
        ldx #7
@s2_lim:
        stx next_fine
        jmp @s2_apply
@s2_no_commit:
        lda cs_pending
        beq @s2_apply
        ; Coarse requested but main loop could not start it in time:
        ; hold the current fine scroll one more frame.
        jsr read_keyboard
        jmp $EA81
@s2_apply:
        lda next_fine
        sta fine_scroll
        ora #%00010000
        sta VIC_CTRL1

        ; --- Read keyboard, accumulate velocity ---
        jsr read_keyboard
        ldx current_step
        clc
        lda scroll_accum
        adc velocity_lo, x
        sta scroll_accum
        lda velocity_hi, x
        adc #0                      ; A = integer pixels to scroll
        beq @s2_done                ; 0 pixels → next_fine = fine_scroll
        ldx direction
        bmi @s2_reverse

        ; --- Forward: fine scroll decreases, coarse up below 0 ---
        sta s2_pixels
        lda fine_scroll
        sec
        sbc s2_pixels
        bcs @s2_set                 ; still >= 0
        lda fwd_limit_reached
        bne @s2_stop0
        lda fine_scroll
        clc
        adc #8
        sec
        sbc s2_pixels               ; fine + 8 - n
        bcs :+
        lda #0                      ; more than one row per frame: clamp
:       sta next_fine
        lda #1
        sta cs_pending
        jmp $EA81
@s2_stop0:
        lda #0
        sta next_fine
        sta current_step
        sta scroll_accum
        jmp $EA81
@s2_set:
        sta next_fine
@s2_done:
        jmp $EA81

        ; --- Reverse (double speed): fine scroll increases, coarse down above 7 ---
@s2_reverse:
        asl a
        bcc :+
        lda #$FF                    ; clamp to 255 on overflow
:       clc
        adc fine_scroll
        bcs :+
        cmp #8
        bcc @s2_set                 ; still <= 7
        sbc #8                      ; carry set here
        cmp #8
        bcc :++
:       lda #7                      ; more than one row per frame: clamp
:       sta s2_pixels
        lda rows_from_start_lo
        ora rows_from_start_hi
        bne :+
        ; At start of document: snap to 7, stop
        lda #7
        sta next_fine
        lda #0
        sta current_step
        sta scroll_accum
        jmp $EA81
:       lda s2_pixels
        sta next_fine
        lda #2
        sta cs_pending
        jmp $EA81


.segment "SCROLL"

; =============================================================================
;  Coarse scroll — beam-chasing copy
;
;  The IRQ requests a coarse scroll one frame before it is shown.  The copy
;  starts once the beam has fetched the rows it overwrites (raster >= 57 for
;  row 0), so the current frame still shows the old layout.  From there it
;  has until the same row's fetch in the next frame, when the IRQ has
;  switched YSCROLL.  That is almost a full frame per row instead of the
;  ~60-line vblank head start of a copy that begins at raster 250.
;
;  Both directions split the screen into bands processed top to bottom.
;  Each band first waits until the beam has fetched its bottom row.
;
;  Up:   row r <- row r+1.  The source rows of a band are not touched by
;        earlier bands, so bands are compact column loops (~18 cy/char).
;  Down: row r <- row r-1 must run bottom-up inside a band, and the band
;        above has already overwritten its source top row, so each band
;        first saves its bottom row for the next one.  Down is the heavier
;        direction (saves, and the YSCROLL after it is small, so deadlines
;        come early), so it is fully unrolled (16 cy/char).
; =============================================================================

COARSE_START_LINE   = 57            ; row 0 is fetched by line 55 (YSCROLL 7)
; Latest start lines that still finish before the next frame's fetches on
; NTSC with margin (measured in VICE: starting at line 57 leaves ~3400 cy
; going up and ~3200 cy going down; each line later costs 65 cy).  A request
; that misses its window waits one frame; the IRQ holds the fine scroll.
UP_WINDOW_END       = 100
DOWN_WINDOW_END     = 95

; ---- wait_window: wait until raster is in [57, A) and remember the frame ----
; If the window is already over, waits for the next frame's window (the IRQ
; holds the fine scroll for that frame).
wait_window:
        sta wait_tgt
@ww:    bit VIC_CTRL1               ; raster bit 8
        bmi @ww
        lda VIC_RASTER
        cmp #COARSE_START_LINE
        bcc @ww
        cmp wait_tgt
        bcs @ww
        lda frame_ctr
        sta start_frame
        rts

; ---- wait_beam_past: wait until the beam has fetched a text row -------------
; A = 49 + 8*row.  Returns once raster > row's bad line in the start frame,
; or immediately if that frame is already over.
wait_beam_past:
        clc
        adc fine_scroll
        sta wait_tgt
@wb:    lda frame_ctr
        cmp start_frame
        bne @wb_done
        lda VIC_RASTER
        cmp wait_tgt
        bcc @wb
@wb_done:
        rts

; ---- commit: tell the IRQ a copy has started (show it at next vblank) ------
coarse_commit:
        sei
        lda #1
        sta cs_commit
        lda #0
        sta cs_pending
        cli
        rts

; ---- Coarse scroll up (forward) ---------------------------------------------

; Colour value for destination row r (up), read into A: remap across zone edges.
.macro SSU_COLFIX r
    .if r = 8                       ; inner(9) → outer(8): light → base
        and #$0F
        tay
        lda color_to_base, y
    .elseif r = 15                  ; outer(16) → inner(15): base → light
        and #$0F
        tay
        lda color_to_light, y
    .endif
.endmacro

; One band: destination rows first..last get rows first+1..last+1.
.macro SSU_BAND first, last
        .local loop
        lda #(49 + 8*last)
        jsr wait_beam_past
        ldx #COLS-1
loop:
    .repeat last-first+1, k
        lda SCREEN + (first+k+1)*COLS, x
        sta SCREEN + (first+k)*COLS, x
        lda COLRAM + (first+k+1)*COLS, x
        SSU_COLFIX (first+k)
        sta COLRAM + (first+k)*COLS, x
    .endrepeat
        dex
    .if * - loop < 126
        bpl loop
    .else
        bmi :+
        jmp loop
:
    .endif
.endmacro

scroll_screen_up:
        ; --- Forward limit check: rows_from_start >= max_rows_fwd? ---
        lda rows_from_start_hi
        cmp max_rows_fwd_hi
        bcc @ssu_ok                 ; hi < → allow
        bne @ssu_limit              ; hi > → at limit
        lda rows_from_start_lo
        cmp max_rows_fwd_lo
        bcc @ssu_ok                 ; lo < → allow
@ssu_limit:
        ; At forward limit: IRQ snaps fine scroll to 0 and stops
        lda #1
        sta fwd_limit_reached
        sei
        lda #2
        sta cs_commit
        lda #0
        sta cs_pending
        cli
        rts
@ssu_ok:
        lda #0
        sta fwd_limit_reached

        ; Source for the new bottom row (render engine bot cursor)
        lda rnd_bot_row
        beq @ssu_row0
        cmp #1
        beq @ssu_row1
        lda #<(rnd_bot_linebuf + 80)
        ldx #>(rnd_bot_linebuf + 80)
        jmp @ssu_src
@ssu_row1:
        lda #<(rnd_bot_linebuf + 40)
        ldx #>(rnd_bot_linebuf + 40)
        jmp @ssu_src
@ssu_row0:
        lda #<rnd_bot_linebuf
        ldx #>rnd_bot_linebuf
@ssu_src:
        sta zp_src
        stx zp_src+1

        lda #UP_WINDOW_END
        jsr wait_window
        jsr coarse_commit
        inc rows_from_start_lo
        bne :+
        inc rows_from_start_hi
:
        ; ── Shift SCREEN + COLRAM up one row ─────────────────────────────
        SSU_BAND  0,  2
        SSU_BAND  3,  6
        SSU_BAND  7, 11
        SSU_BAND 12, 17
        SSU_BAND 18, 23

        ; ── New bottom row ─────────────────────────────────────────────────
        ldy #0
        .repeat COLS
        lda (zp_src), y
        sta SCREEN + (ROWS-1)*COLS, y
        iny
        .endrepeat
        ldx #39
@ssu_newcol:
        lda rnd_bot_colbuf, x
        sta COLRAM + (ROWS-1)*COLS, x
        dex
        bpl @ssu_newcol

        ; Render ahead (not visible, only needs to finish before next coarse)
        jsr render_advance_bot
        jsr render_advance_top
        rts


; ---- Coarse scroll down (reverse) -------------------------------------------
; Shifts all rows down by one and fills row 0 from the render engine top
; cursor.  Bands are processed top to bottom, each one bottom-up.

; Colour value for destination row r, read into A: remap across zone edges.
.macro SSD_COLFIX r
    .if r = 9                       ; outer(8) → inner(9): base → light
        and #$0F
        tay
        lda color_to_light, y
    .elseif r = 16                  ; inner(15) → outer(16): light → base
        and #$0F
        tay
        lda color_to_base, y
    .endif
.endmacro

; One band: destination rows first..last, fully unrolled.  in_s/in_c hold
; the old row first-1 (saved by the previous band, or the new row 0).  If
; out_s is given, the old row `last` is saved there first for the next band.
.macro SSD_BAND first, last, in_s, in_c, out_s, out_c
        lda #(49 + 8*last)
        jsr wait_beam_past
    .ifnblank out_s
      .repeat COLS, c
        lda SCREEN + last*COLS + c
        sta out_s + c
        lda COLRAM + last*COLS + c
        sta out_c + c
      .endrepeat
    .endif
    .repeat last-first, k
      .repeat COLS, c
        lda SCREEN + (last-k-1)*COLS + c
        sta SCREEN + (last-k)*COLS + c
        lda COLRAM + (last-k-1)*COLS + c
        SSD_COLFIX (last-k)
        sta COLRAM + (last-k)*COLS + c
      .endrepeat
    .endrepeat
    .repeat COLS, c
        lda in_s + c
        sta SCREEN + first*COLS + c
        lda in_c + c
        SSD_COLFIX first
        sta COLRAM + first*COLS + c
    .endrepeat
.endmacro

scroll_screen_down:
        ; Boundary check: if rows_from_start <= reverse_floor, snap fine
        ; scroll to 7, zero velocity, and return without moving.
        lda rows_from_start_hi
        cmp reverse_floor_hi
        bcc @ssd_at_floor           ; hi < floor_hi → at/below floor
        bne @ssd_ok                 ; hi > floor_hi → allow
        lda rows_from_start_lo
        cmp reverse_floor_lo
        beq @ssd_at_floor           ; equal → at floor
        bcs @ssd_ok                 ; lo > floor_lo → allow
@ssd_at_floor:
        sei
        lda #3
        sta cs_commit
        lda #0
        sta cs_pending
        cli
        rts
@ssd_ok:
        lda #0
        sta fwd_limit_reached

        ; ── Prepare new row 0 before the copy window ─────────────────────
        ; Retreat the top cursor first (may re-render its linebuf, or clear
        ; it when entering the blank lead-in), then stage the row it points at.
        jsr render_retreat_top
        lda rnd_top_row
        beq @ssd_r0
        cmp #1
        beq @ssd_r1
        lda #<(rnd_top_linebuf + 80)
        ldx #>(rnd_top_linebuf + 80)
        jmp @ssd_src
@ssd_r1:
        lda #<(rnd_top_linebuf + 40)
        ldx #>(rnd_top_linebuf + 40)
        jmp @ssd_src
@ssd_r0:
        lda #<rnd_top_linebuf
        ldx #>rnd_top_linebuf
@ssd_src:
        sta zp_src
        stx zp_src+1
        ldy #COLS-1
@ssd_stage:
        lda (zp_src), y
        sta newrow_buf, y
        dey
        bpl @ssd_stage

        lda #DOWN_WINDOW_END
        jsr wait_window
        jsr coarse_commit
        lda rows_from_start_lo
        bne :+
        dec rows_from_start_hi
:       dec rows_from_start_lo

        SSD_BAND  0,  2, newrow_buf, rnd_top_colbuf, ssd_sv0s, ssd_sv0c
        SSD_BAND  3,  7, ssd_sv0s, ssd_sv0c, ssd_sv1s, ssd_sv1c
        SSD_BAND  8, 13, ssd_sv1s, ssd_sv1c, ssd_sv2s, ssd_sv2c
        SSD_BAND 14, 19, ssd_sv2s, ssd_sv2c, ssd_sv3s, ssd_sv3c
        SSD_BAND 20, 24, ssd_sv3s, ssd_sv3c

        jsr render_retreat_bot
        rts

.segment "CODE"

; ---- Detect PAL or NTSC ---------------------------------------------------
; Sets is_ntsc: 0=PAL (312 lines/frame, 50fps), 1=NTSC (263 lines/frame, 60fps).
; Method: wait for raster >= 256, then check if it reaches line 264+.
; PAL raster goes up to 311 (low byte 55); NTSC only to 262 (low byte 6).
; ---------------------------------------------------------------------------
detect_pal_ntsc:
        ; Wait for raster to be in top half (bit 8 of raster = 0)
:       bit VIC_CTRL1
        bmi :-
        ; Wait for raster >= 256 (bit 8 = 1, stored in bit 7 of $D011)
:       bit VIC_CTRL1
        bpl :-
        ; Poll: can raster low byte reach 8+? (i.e., raster line >= 264)
:       lda VIC_RASTER
        cmp #8
        bcs @pal                    ; low byte >= 8 → raster 264+ → PAL
        bit VIC_CTRL1
        bmi :-                      ; still in 256+ range, keep checking
        ; Raster wrapped before reaching 264 → NTSC
        lda #1
        sta is_ntsc
        rts
@pal:
        lda #0
        sta is_ntsc
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

        ; On NTSC (60fps), scale by 5/6 to match PAL (50fps) scroll speed
        lda is_ntsc
        beq @not_ntsc
        lda #<fp_ntsc_scale
        ldy #>fp_ntsc_scale
        jsr FMULT
@not_ntsc:

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
        jsr scan_keyboard
        ; --- Direction from SHIFT status ---
        lda kb_shift                ; SHIFT or SHIFT LOCK
        beq @dir_fwd
        lda #$FF                    ; reverse
        sta direction
        jmp @check_key
@dir_fwd:
        lda #$01
        sta direction

@check_key:
        lda kb_code                 ; current key matrix code
        cmp #$40                    ; no key pressed
        bne @has_key
        rts
@has_key:

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
        ; Check for T (matrix code $16) → reset to start
        cmp #$16
        bne @not_t
        lda #3
        sta enter_config            ; 3 = reset to start
        rts
@not_t:
        ; Check for comma/< (matrix code $2F) → search previous #
        cmp #$2F
        bne @not_comma
        lda #4
        sta enter_config            ; 4 = search previous #
        rts
@not_comma:
        ; Check for period/> (matrix code $2C) → search next #
        cmp #$2C
        bne @not_period
        lda #5
        sta enter_config            ; 5 = search next #
        rts
@not_period:
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


; ---- Scan keyboard matrix -------------------------------------------------
; Replaces the KERNAL scan ($EA31) during scrolling: a held key (e.g. SHIFT
; LOCK) makes SCNKEY decode the whole matrix every frame, which costs cycles
; the coarse scroll copy needs.
; Out: kb_code = KERNAL matrix code of a non-modifier key ($40 = none)
;      kb_shift = nonzero if either SHIFT (or SHIFT LOCK) is down
; Also mirrors kb_code into $CB/$C5 so the KERNAL does not see a held key as
; a new press when scrolling ends.
scan_keyboard:
        lda #$40
        sta kb_code
        lda #0
        sta kb_shift
        sta $DC00                   ; all columns
        lda $DC01
        cmp #$FF
        beq @sk_done                ; nothing pressed
        ldx #7
@sk_col:
        lda kb_col_sel, x
        sta $DC00
        lda $DC01
        eor #$FF                    ; 1 = pressed
        beq @sk_next
        tay
        and kb_shift_bits, x
        beq :+
        sta kb_shift
:       tya
        and kb_key_bits, x          ; drop SHIFT/CTRL/C=
        beq @sk_next
        ; matrix code = column*8 + lowest set bit
        ldy #$FF
:       iny
        lsr a
        bcc :-
        stx kb_tmp
        tya
        ldy kb_tmp
        ora kb_col_x8, y
        sta kb_code
@sk_next:
        dex
        bpl @sk_col
@sk_done:
        lda #$7F
        sta $DC00
        lda kb_code
        sta CURR_KEY
        sta $C5                     ; KERNAL "last key" (no repeat on exit)
        rts

kb_col_sel:    .byte $FE, $FD, $FB, $F7, $EF, $DF, $BF, $7F
kb_col_x8:     .byte $00, $08, $10, $18, $20, $28, $30, $38
kb_shift_bits: .byte $00, $80, $00, $00, $00, $00, $10, $00  ; L-SHIFT, R-SHIFT
kb_key_bits:   .byte $FF, $7F, $FF, $FF, $FF, $FF, $EF, $DB  ; minus SHIFTs, CTRL, C=
kb_code:       .byte $40
kb_shift:      .byte 0
kb_tmp:        .byte 0


; ---- Disable raster IRQ and restore KERNAL ----------------------------------
disable_raster_restore_kernal:
        sei

        ; Wait for VBlank to avoid mid-frame changes
@drr_vbl:
        lda VIC_RASTER
        cmp #251
        bcc @drr_vbl

        ; Blank display immediately (DEN=0) to hide transition
        lda #$0B                    ; RSEL=1, DEN=0, YSCROLL=3
        sta VIC_CTRL1

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

        ; Restore ROM charset (editor/config use ROM charset at $1000)
        lda #$14                    ; screen@$0400, ROM charset@$1000 (bank 0)
        sta $D018

        ; Disable Commodore+Shift charset toggle
        lda #$80
        sta $0291

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
        ; Clean any $FF blank-line sentinels left by the scroll renderer
        jsr clean_doc_sentinels

        ; Set black border/background
        lda #0
        sta VIC_BORDER
        sta VIC_BG

        ; Clear screen
        lda #$20
        ldx #0
@ee_cls:
        .repeat 8
        sta SCREEN, x
        sta SCREEN+256, x
        sta SCREEN+512, x
        sta SCREEN+744, x
        inx
        .endrepeat
        bne @ee_cls

        ; Set color RAM rows 0-23 = WHITE
        lda #WHITE
        ldx #0
@ee_cr0:
        .repeat 8
        sta COLRAM, x
        sta COLRAM+256, x
        sta COLRAM+512, x
        inx
        .endrepeat
        bne @ee_cr0
        ; Remaining row 24 area in page 3 = LIGHT_BLUE
        ldx #0
@ee_cr3:
        .repeat 8
        sta COLRAM+768, x
        inx
        .endrepeat
        cpx #192                    ; rows 19-23 (white)
        bne @ee_cr3
        lda #LIGHT_BLUE
        ldx #192
@ee_cr4:
        .repeat 8
        sta COLRAM+768, x          ; row 24 = light blue
        inx
        .endrepeat
        bne @ee_cr4

        ; Load current page
        jsr load_editor_page

        ; Draw status bar
        jsr draw_status_bar

        ; Draw cursor (reverse char at position)
        jsr draw_cursor

        ; Re-enable display (may have been blanked during scroll→editor transition)
        lda #$1B
        sta VIC_CTRL1

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
        bne @not_ctrl_clr
        jmp do_ctrl_clr
@not_ctrl_clr:
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
        cmp #$8B                    ; F6 (Shift+F5) → exit to scroll (jump to cursor)
        bne @not_f6_ed
        jmp ed_exit_to_scroll_f3
@not_f6_ed:
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
        lda $028D
        and #$06                    ; Commodore (bit1) or Ctrl (bit2)?
        bne @do_word_left
        jmp ed_cursor_left
@do_word_left:
        jmp ed_word_left
@not_left:
        cmp #$1D                    ; Cursor Right
        bne @not_right_ed
        lda $028D
        and #$06                    ; Commodore (bit1) or Ctrl (bit2)?
        bne @do_word_right
        jmp ed_cursor_right
@do_word_right:
        jmp ed_word_right
@not_right_ed:
        ; ── F3 = cycle font color (light gray → red → blue → green → ...) ─
        cmp #$86                    ; F3
        bne @not_f3_ed
        ldx cfg_font_color
        lda color_to_idx, x        ; current index 0-3
        clc
        adc #1
        and #$03                    ; wrap 0-3
        tax
        lda idx_to_color_base, x   ; next C64 color
        sta cfg_font_color
        jsr draw_status_bar
        jmp editor_loop
@not_f3_ed:
        ; ── F4 = cycle background color ──────────────────────────────────
        cmp #$8A                    ; F4 (Shift+F3)
        bne @not_f4
        lda cfg_bg_color
        clc
        adc #1
        and #$0F
        sta cfg_bg_color
        jsr draw_status_bar
        jmp editor_loop
@not_f4:
        ; Try printable character
        jsr petscii_to_screencode_editor
        bcc @is_printable           ; carry clear = printable
        jmp editor_loop
@is_printable:
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
        ; Write font color to COLRAM at same position
        ; COLRAM addr = zp_dst - SCREEN + COLRAM
        lda zp_dst
        clc
        adc #<(COLRAM - SCREEN)
        sta zp_src
        lda zp_dst+1
        adc #>(COLRAM - SCREEN)
        sta zp_src+1
        lda cfg_font_color
        sta (zp_src), y             ; Y is still 0
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
        bne @ecu_same_page
        ; At row 0 — try to go to previous page
        lda current_page
        beq @ecu_done               ; already at page 0, nowhere to go
        jsr save_editor_page
        ; Trim empty last page (same logic as ed_prev_page)
        lda current_page
        clc
        adc #1
        cmp total_pages
        bne @ecu_no_trim
        lda total_pages
        cmp #2
        bcc @ecu_no_trim
        jsr check_page_empty
        bcc @ecu_no_trim
        dec total_pages
@ecu_no_trim:
        dec current_page
        jsr load_editor_page
        jsr draw_status_bar
        lda #23
        sta cursor_y                ; cursor to last row
        jmp @ecu_done
@ecu_same_page:
        dec cursor_y
@ecu_done:
        jsr draw_cursor
        jmp editor_loop

ed_cursor_down:
        jsr undraw_cursor
        lda cursor_y
        cmp #23
        bcc @ecd_same_page
        ; At row 23 — try to go to next page
        lda current_page
        clc
        adc #1
        cmp total_pages
        bcc @ecd_has_next           ; next page exists
        ; At last page — can we add a new one?
        lda total_pages
        cmp #10
        bcs @ecd_done               ; already 10 pages, can't go further
        ; Add new blank page
        inc total_pages
        ldx total_pages
        dex
        lda page_addr_lo, x
        sta zp_dst
        lda page_addr_hi, x
        sta zp_dst+1
        jsr fill_page_spaces
@ecd_has_next:
        jsr save_editor_page
        inc current_page
        jsr load_editor_page
        jsr draw_status_bar
        lda #0
        sta cursor_y                ; cursor to first row
        jmp @ecd_done
@ecd_same_page:
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

; ---- C=+Right: Jump to start of next word ------------------------------------
ed_word_right:
        jsr undraw_cursor
        jsr save_editor_page
        jsr calc_cursor_doc_ptr     ; zp_src = cursor pos in doc_buffer
        ; Save original position
        lda zp_src
        sta wskip_save
        lda zp_src+1
        sta wskip_save+1
        ; End boundary = page_addr[total_pages]
        ldx total_pages
        lda page_addr_lo, x
        sta wskip_end
        lda page_addr_hi, x
        sta wskip_end+1
        ; Phase 1: skip non-spaces (rest of current word)
@wr_nonsp:
        lda zp_src+1
        cmp wskip_end+1
        bcc @wr_nonsp_ok
        bne @wr_fail
        lda zp_src
        cmp wskip_end
        bcs @wr_fail
@wr_nonsp_ok:
        ldy #0
        lda (zp_src), y
        cmp #$20
        beq @wr_sp
        inc zp_src
        bne @wr_nonsp
        inc zp_src+1
        jmp @wr_nonsp
        ; Phase 2: skip spaces
@wr_sp:
        lda zp_src+1
        cmp wskip_end+1
        bcc @wr_sp_ok
        bne @wr_fail
        lda zp_src
        cmp wskip_end
        bcs @wr_fail
@wr_sp_ok:
        ldy #0
        lda (zp_src), y
        cmp #$20
        bne @wr_found
        inc zp_src
        bne @wr_sp
        inc zp_src+1
        jmp @wr_sp
@wr_found:
        ; zp_src = start of next word
        jmp @wr_finish
@wr_fail:
        ; No next word — restore original position
        lda wskip_save
        sta zp_src
        lda wskip_save+1
        sta zp_src+1
@wr_finish:
        jsr doc_ptr_to_cursor
        jsr load_editor_page
        jsr draw_status_bar
        jsr draw_cursor
        jmp editor_loop

; ---- C=+Left: Jump to start of previous word ---------------------------------
ed_word_left:
        jsr undraw_cursor
        jsr save_editor_page
        jsr calc_cursor_doc_ptr     ; zp_src = cursor pos in doc_buffer
        ; Save original position
        lda zp_src
        sta wskip_save
        lda zp_src+1
        sta wskip_save+1
        ; Start boundary = page_addr[0]
        lda page_addr_lo
        sta wskip_end
        lda page_addr_hi
        sta wskip_end+1
        ; Check if already at document start
        lda zp_src+1
        cmp wskip_end+1
        bne @wl_not_start
        lda zp_src
        cmp wskip_end
        beq @wl_fail
@wl_not_start:
        ; Step back one position
        lda zp_src
        bne :+
        dec zp_src+1
:       dec zp_src
        ; Phase 1: skip spaces backward
@wl_skip_sp:
        ldy #0
        lda (zp_src), y
        cmp #$20
        bne @wl_skip_nonsp
        ; Check if at start
        lda zp_src+1
        cmp wskip_end+1
        bne @wl_sp_dec
        lda zp_src
        cmp wskip_end
        beq @wl_fail                ; all spaces back to start → no prev word
@wl_sp_dec:
        lda zp_src
        bne :+
        dec zp_src+1
:       dec zp_src
        jmp @wl_skip_sp
        ; Phase 2: skip non-spaces backward (inside previous word)
@wl_skip_nonsp:
        ; Check if at document start
        lda zp_src+1
        cmp wskip_end+1
        bne @wl_nonsp_dec
        lda zp_src
        cmp wskip_end
        beq @wl_found               ; at doc start = start of first word
@wl_nonsp_dec:
        lda zp_src
        bne :+
        dec zp_src+1
:       dec zp_src
        ldy #0
        lda (zp_src), y
        cmp #$20
        bne @wl_skip_nonsp
        ; Found space → next byte is start of word
        inc zp_src
        bne @wl_found
        inc zp_src+1
@wl_found:
        jmp @wl_finish
@wl_fail:
        ; No previous word — restore original position
        lda wskip_save
        sta zp_src
        lda wskip_save+1
        sta zp_src+1
@wl_finish:
        jsr doc_ptr_to_cursor
        jsr load_editor_page
        jsr draw_status_bar
        jsr draw_cursor
        jmp editor_loop

; ---- Helper: compute doc_buffer pointer for cursor position -------------------
; Output: zp_src = page_addr[current_page] + cursor_y * 40 + cursor_x
calc_cursor_doc_ptr:
        ldx current_page
        lda page_addr_lo, x
        sta zp_src
        lda page_addr_hi, x
        sta zp_src+1
        ; Compute cursor_y * 40 = y*8 + y*32
        lda #0
        sta wskip_tmp+1
        lda cursor_y
        asl                         ; *2
        asl                         ; *4
        asl                         ; *8
        sta wskip_tmp
        asl                         ; *16
        rol wskip_tmp+1
        asl                         ; *32
        rol wskip_tmp+1
        clc
        adc wskip_tmp               ; *40 low
        sta wskip_tmp
        lda wskip_tmp+1
        adc #0
        sta wskip_tmp+1
        ; Add to page base
        clc
        lda zp_src
        adc wskip_tmp
        sta zp_src
        lda zp_src+1
        adc wskip_tmp+1
        sta zp_src+1
        ; Add cursor_x
        clc
        lda zp_src
        adc cursor_x
        sta zp_src
        lda zp_src+1
        adc #0
        sta zp_src+1
        rts

; ---- Helper: convert doc_buffer pointer to page/row/col ----------------------
; Input: zp_src = pointer into doc_buffer
; Output: current_page, cursor_y, cursor_x set
doc_ptr_to_cursor:
        ; Find page: zp_src < page_addr[x+1]
        ldx #0
@dpc_page:
        inx
        lda zp_src+1
        cmp page_addr_hi, x
        bcc @dpc_found
        bne @dpc_page
        lda zp_src
        cmp page_addr_lo, x
        bcs @dpc_page
@dpc_found:
        dex
        stx current_page
        ; offset = zp_src - page_addr[current_page]
        sec
        lda zp_src
        sbc page_addr_lo, x
        sta wskip_tmp
        lda zp_src+1
        sbc page_addr_hi, x
        sta wskip_tmp+1
        ; Divide offset by 40 → cursor_y (quotient), cursor_x (remainder)
        lda #0
        sta cursor_y
@dpc_div:
        lda wskip_tmp+1
        bne @dpc_sub
        lda wskip_tmp
        cmp #40
        bcc @dpc_done
@dpc_sub:
        sec
        lda wskip_tmp
        sbc #40
        sta wskip_tmp
        lda wskip_tmp+1
        sbc #0
        sta wskip_tmp+1
        inc cursor_y
        jmp @dpc_div
@dpc_done:
        lda wskip_tmp
        sta cursor_x
        rts

; Word-skip temporary storage
wskip_save:     .byte 0, 0             ; saved cursor doc_buffer position
wskip_end:      .byte 0, 0             ; boundary (end for right, start for left)
wskip_tmp:      .byte 0, 0             ; temp for multiply/divide

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

; ---- F5: Exit to scroll (resume) --------------------------------------------
ed_exit_to_scroll:
        jsr undraw_cursor
        jsr save_editor_page
        lda #1
        sta came_from               ; came from editor
        lda #1                      ; return 1 = go to scroll (F5 resume)
        rts

; ---- F6: Exit to scroll (jump to cursor) -----------------------------------
ed_exit_to_scroll_f3:
        jsr undraw_cursor
        jsr save_editor_page
        lda #1
        sta came_from               ; came from editor
        lda #2                      ; return 2 = go to scroll (F6 jump to cursor)
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
; Encodes color from COLRAM into bits 6-7 of each screen code.
; Uses ZP $22-$23 as temporary COLRAM pointer (safe when BASIC is banked out).
SEP_COLPTR = $22
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
        ; COLRAM pointer (same lo, hi = SCREEN hi + $D4)
        lda #<COLRAM
        sta SEP_COLPTR
        lda #>COLRAM
        sta SEP_COLPTR+1

        ; Encode 960 bytes (3 full pages + 192 tail)
        lda #3
        sta @sep_cnt
@sep_full:
        ldy #0
@sep_byte:
        lda (zp_src), y         ; screen code
        and #$3F                ; mask out any old high bits
        sta @sep_tmp
        lda (SEP_COLPTR), y    ; COLRAM color
        and #$0F
        tax
        lda color_to_idx, x    ; 2-bit color index (0-3)
        asl
        asl
        asl
        asl
        asl
        asl                     ; shift index into bits 6-7
        ora @sep_tmp            ; combine with screen code
        sta (zp_dst), y
        iny
        bne @sep_byte
        inc zp_src+1
        inc zp_dst+1
        inc SEP_COLPTR+1
        dec @sep_cnt
        bne @sep_full
        ; Remaining 192 bytes
        ldy #0
@sep_tail:
        lda (zp_src), y
        and #$3F
        sta @sep_tmp
        lda (SEP_COLPTR), y
        and #$0F
        tax
        lda color_to_idx, x
        asl
        asl
        asl
        asl
        asl
        asl
        ora @sep_tmp
        sta (zp_dst), y
        iny
        cpy #192
        bne @sep_tail
        rts
@sep_tmp: .byte 0
@sep_cnt: .byte 0

; ---- Load editor page: doc_buffer → SCREEN rows 0-23 -----------------------
; Decodes color from bits 6-7 of stored screen codes and sets COLRAM.
LEP_COLPTR = $22
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
        ; COLRAM pointer
        lda #<COLRAM
        sta LEP_COLPTR
        lda #>COLRAM
        sta LEP_COLPTR+1

        ; Decode 960 bytes (3 full pages + 192 tail)
        lda #3
        sta @lep_cnt
@lep_full:
        ldy #0
@lep_byte:
        lda (zp_src), y         ; encoded byte: [color_idx:2 | screen_code:6]
        pha
        and #$3F                ; extract screen code
        sta (zp_dst), y         ; write to SCREEN
        pla
        ; Extract color index from bits 6-7
        rol
        rol
        rol
        and #$03                ; A = color index 0-3
        tax
        lda idx_to_color_base, x ; C64 base color
        sta (LEP_COLPTR), y     ; write to COLRAM
        iny
        bne @lep_byte
        inc zp_src+1
        inc zp_dst+1
        inc LEP_COLPTR+1
        dec @lep_cnt
        bne @lep_full
        ; Remaining 192 bytes
        ldy #0
@lep_tail:
        lda (zp_src), y
        pha
        and #$3F
        sta (zp_dst), y
        pla
        rol
        rol
        rol
        and #$03
        tax
        lda idx_to_color_base, x
        sta (LEP_COLPTR), y
        iny
        cpy #192
        bne @lep_tail
        rts
@lep_cnt: .byte 0

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
        and #$3F                    ; mask color bits 6-7
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
        and #$3F                    ; mask color bits 6-7
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

        ; Shortcut hints at cols 10-30: ↑N ↑O ↑S F1 F5 F6 F7 F8
        ; (↑ = up-arrow $1E as Ctrl indicator; ↑C = Ctrl+CLR)
        ldx #0
@dsb_hints:
        lda @dsb_hint_str, x
        beq @dsb_color_ind
        ora #$80
        sta SCREEN + 24*40 + 10, x
        inx
        bne @dsb_hints
@dsb_color_ind:
        ; Font color indicator: "F3" label at 34-35, reversed block at col 36
        lda #$A0                    ; reversed space (filled block)
        sta SCREEN + 24*40 + 36
        lda cfg_font_color
        sta COLRAM + 24*40 + 36
        ; Background color indicator: "4" label at 37, reversed block at col 38
        lda #$A0
        sta SCREEN + 24*40 + 38
        lda cfg_bg_color
        sta COLRAM + 24*40 + 38
        ; Labels: "F3" at 34-35, "4" at 37
        lda #(sc_F | $80)
        sta SCREEN + 24*40 + 34
        lda #($33 | $80)            ; "3"
        sta SCREEN + 24*40 + 35
        lda #($34 | $80)            ; "4"
        sta SCREEN + 24*40 + 37
        rts
@dsb_hint_str:
        ; ↑N  ↑O  ↑S  F1  F5  F6  F7  F8
        .byte $1E,sc_N,__,$1E,sc_O,__,$1E,sc_S,__
        .byte sc_F,$31,__,sc_F,$35,__,sc_F,$36,__,sc_F,$37,__,sc_F,$38,0

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
        sta scroll_has_saved        ; invalidate saved scroll position
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
        sta scroll_has_saved        ; invalidate saved scroll position
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
        .repeat 8
        sta SCREEN, x
        sta SCREEN+256, x
        sta SCREEN+512, x
        inx
        .endrepeat
        bne @dcc_loop
        ldx #0
@dcc_tail:
        .repeat 8
        sta SCREEN+768, x
        inx
        .endrepeat
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
; Copies the instruction text (72 lines = 2880 bytes = 3 pages exactly)
; into doc_buffer.  No padding needed.
; Sets total_pages=3, current_page=0, cursor_x/y=0.
; ---------------------------------------------------------------------------
init_document:
        ; Source = text_data (72 lines × 40 bytes = 2880 bytes)
        lda #<text_data
        sta zp_src
        lda #>text_data
        sta zp_src+1

        ; Dest = doc_buffer
        lda #<doc_buffer
        sta zp_dst
        lda #>doc_buffer
        sta zp_dst+1

        ; Copy 2880 bytes = 11 × 256 + 64
        ldx #11
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

        ; Copy remaining 64 bytes
        ldy #0
@id_tail:
        lda (zp_src), y
        sta (zp_dst), y
        iny
        cpy #64
        bne @id_tail

        ; Set editor state
        lda #3
        sta total_pages
        lda #0
        sta current_page
        sta cursor_x
        sta cursor_y
        sta scroll_has_saved        ; invalidate saved scroll position
        rts


; ---- Prepare scroll text from doc_buffer -----------------------------------
; Sets scroll_start/scroll_end and text_lo/hi for the scroller.
; Appends 1000 bytes (25 blank lines) as scroll_trail after document content.
; ---------------------------------------------------------------------------
prepare_scroll_text:
        ; Note: editor page is already saved by ed_exit before we get here.
        ; Do NOT call save_editor_page — screen may contain config/scroll content.

        ; Clean any leftover sentinels from a previous scroll session
        jsr clean_doc_sentinels

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

        ; Mark blank lines with $FF sentinels for the renderer
        jsr mark_blank_sentinels
        rts


; ---- Clean doc_buffer sentinels: replace $FF → $20 at byte[0] of each line ---
clean_doc_sentinels:
        lda #<doc_buffer
        sta zp_src
        lda #>doc_buffer
        sta zp_src+1
        ; line_count = total_pages * 24
        lda total_pages
        asl                         ; *2
        asl                         ; *4
        asl                         ; *8
        sta @cds_tmp
        asl                         ; *16
        clc
        adc @cds_tmp                ; *24
        sta @cds_count
@cds_loop:
        ldy #0
        lda (zp_src), y
        cmp #$FF
        bne @cds_next
        lda #$20
        sta (zp_src), y
@cds_next:
        lda zp_src
        clc
        adc #40
        sta zp_src
        bcc @cds_adv_ok
        inc zp_src+1
@cds_adv_ok:
        dec @cds_count
        bne @cds_loop
        rts
@cds_tmp:   .byte 0
@cds_count: .byte 0


; ---- Mark blank lines with $FF sentinel in doc_buffer ------------------------
; Scans doc_buffer line-by-line (40 bytes each).  For each run of consecutive
; blank lines (all spaces), sets byte[0] of the FIRST blank line to $FF.
; The renderer treats $FF as "produce one blank rendered line".
; ---------------------------------------------------------------------------
mark_blank_sentinels:
        lda #<doc_buffer
        sta zp_src
        lda #>doc_buffer
        sta zp_src+1
        ; line_count = total_pages * 24
        lda total_pages
        asl                         ; *2
        asl                         ; *4
        asl                         ; *8
        sta @mbs_tmp
        asl                         ; *16
        clc
        adc @mbs_tmp                ; *24
        sta @mbs_count
        lda #0
        sta @mbs_prev_blank
@mbs_loop:
        ; Check if all 40 bytes of this line are spaces (masking color bits)
        ldy #0
@mbs_check:
        lda (zp_src), y
        and #$3F                    ; mask color bits 6-7
        cmp #$20
        bne @mbs_not_blank
        iny
        cpy #40
        bne @mbs_check
        ; Line is all spaces — mark if first blank in run
        lda @mbs_prev_blank
        bne @mbs_next               ; already in blank run, skip
        ldy #0
        lda #$FF
        sta (zp_src), y
        lda #1
        sta @mbs_prev_blank
        jmp @mbs_next
@mbs_not_blank:
        lda #0
        sta @mbs_prev_blank
@mbs_next:
        lda zp_src
        clc
        adc #40
        sta zp_src
        bcc @mbs_adv_ok
        inc zp_src+1
@mbs_adv_ok:
        dec @mbs_count
        bne @mbs_loop
        rts
@mbs_tmp:        .byte 0
@mbs_count:      .byte 0
@mbs_prev_blank: .byte 0


; ===========================================================================
;  RENDER ENGINE — large-character scroll mode
;  Converts editor text (screen codes) to 3×3 tile characters on the fly,
;  with word-wrap and centering.  Each rendered line = 3 screen rows.
; ===========================================================================

; ---------------------------------------------------------------------------
;  render_compute_line
;  Word-wraps source text, centres, and writes 120 tile bytes (3×40) to buf.
;  Input:  zp_src  = source ptr in doc_buffer
;          zp_dst  = pointer to 120-byte output buffer
;  Output: zp_src advanced to start of next rendered line
;  Clobbers: A, X, Y, all rnd_wk_* vars, rnd_out_lo/hi
; ---------------------------------------------------------------------------
render_compute_line:
        ; ── Phase 1: clear output buffer ────────────────────────────────────
        lda zp_dst
        sta rnd_out_lo
        lda zp_dst+1
        sta rnd_out_hi
        lda #0
        ldy #0
@rcl_clr:
        sta (rnd_out_lo), y
        iny
        cpy #120
        bne @rcl_clr

        ; ── Phase 2: word-wrap ───────────────────────────────────────────────
        lda #0
        sta rnd_wk_len
        sta rnd_wk_wid
        sta rnd_wk_first        ; 0 = "first word not yet placed"

@ww_loop:
        ; ── skip spaces and note if any were seen ────────────────────────────
        lda #0
        sta rnd_wk_sep          ; has_sep = 0
@ww_skip_sp:
        ; bounds check: zp_src >= scroll_end → done
        lda zp_src+1
        cmp scroll_end_hi
        bcc @ww_not_end
        bne @ww_jmp_done    ; hi byte above → done
        lda zp_src
        cmp scroll_end_lo
        bcc @ww_not_end
@ww_jmp_done:
        jmp @ww_done
@ww_not_end:
        ldy #0
        lda (zp_src), y
        cmp #$FF                ; check sentinel before masking color bits
        beq @ww_no_sp_sent
        and #$3F                ; mask color bits 6-7
        cmp #$20
        bne @ww_no_sp
        lda #1
        sta rnd_wk_sep
        inc zp_src
        bne @ww_skip_sp
        inc zp_src+1
        jmp @ww_skip_sp
@ww_no_sp_sent:
        ; fall through: $FF is not a space
@ww_no_sp:
        ; ── check for blank-line sentinel ──────────────────────────────────
        ldy #0
        lda (zp_src), y         ; re-read unmasked for sentinel check
        cmp #$FF
        bne @ww_not_sentinel
        ; Sentinel found: blank line marker
        lda rnd_wk_first
        beq @ww_sent_blank
        jmp @ww_done            ; words placed → end line, $FF stays for next call
@ww_sent_blank:
        ; No words → produce blank line: skip $FF and return
        inc zp_src
        bne @ww_sent_ok
        inc zp_src+1
@ww_sent_ok:
        jmp @ww_done
@ww_not_sentinel:
        ; ── measure next word (count non-space chars) ───────────────────────
        lda zp_src
        sta rnd_wk_csrc
        lda zp_src+1
        sta rnd_wk_csrc+1
        lda #0
        sta rnd_wk_wlen
@ww_meas:
        ; bounds check
        lda rnd_wk_csrc+1
        cmp scroll_end_hi
        bcc @ww_m_ok
        bne @ww_m_end
        lda rnd_wk_csrc
        cmp scroll_end_lo
        bcs @ww_m_end
@ww_m_ok:
        ldy #0
        lda (rnd_wk_csrc), y
        cmp #$FF                ; sentinel ends word (check before masking)
        beq @ww_m_end
        and #$3F                ; mask color bits 6-7
        cmp #$20                ; space ends word
        beq @ww_m_end
        inc rnd_wk_csrc
        bne @ww_m_ok2
        inc rnd_wk_csrc+1
@ww_m_ok2:
        inc rnd_wk_wlen
        lda rnd_wk_wlen
        cmp #14             ; hard cap at 13 chars (13×3=39 tiles)
        bne @ww_meas
@ww_m_end:
        ; if word length = 0 → end of text
        lda rnd_wk_wlen
        bne @ww_m_nonzero
        jmp @ww_done
@ww_m_nonzero:
        ; ── compute word width = wlen*3 ──────────────────────────────────────
        asl                 ; ×2
        clc
        adc rnd_wk_wlen     ; +wlen = ×3  (max 13×3=39, no overflow)
        sta rnd_wk_wwidth
        ; ── compute separator to add before this word ────────────────────────
        lda rnd_wk_first
        beq @ww_nosep       ; first word → no sep
        lda rnd_wk_sep
        beq @ww_nosep
        lda #2
        sta rnd_wk_sep
        jmp @ww_chk_fit
@ww_nosep:
        lda #0
        sta rnd_wk_sep
@ww_chk_fit:
        ; ── check if word fits: wid + sep + wwidth ≤ 40 ────────────────────
        lda rnd_wk_wid
        clc
        adc rnd_wk_sep
        clc
        adc rnd_wk_wwidth
        cmp #41             ; > 40?
        bcc @ww_fits
        ; doesn't fit
        lda rnd_wk_len
        bne @ww_done        ; not first word → end line
        ; first word too wide → force-include (wlen capped at 13)
        lda #0
        sta rnd_wk_sep
@ww_fits:
        ; ── advance line width by sep ────────────────────────────────────────
        lda rnd_wk_wid
        clc
        adc rnd_wk_sep
        sta rnd_wk_wid
        ; ── copy word chars and their x positions into rnd_wk_char/x ────────
        lda #0
        sta @wi             ; word char index
@ww_addch:
        lda @wi
        cmp rnd_wk_wlen
        beq @ww_adddone
        lda rnd_wk_len
        cmp #13
        beq @ww_adddone     ; buffer full
        tax                 ; X = current rnd_wk_len (index to write)
        ; store x position
        lda rnd_wk_wid
        ldy @wi
        ; x = rnd_wk_wid + wi*3
        lda @wi
        asl
        sta @tmp_byte
        lda @wi
        clc
        adc @tmp_byte       ; A = wi*3
        clc
        adc rnd_wk_wid      ; A = rnd_wk_wid + wi*3
        sta rnd_wk_x, x
        ; store screen code
        ldy @wi
        lda (zp_src), y
        sta rnd_wk_char, x
        inc rnd_wk_len
        inc @wi
        jmp @ww_addch
@ww_adddone:
        ; ── advance rnd_wk_wid and zp_src past this word ────────────────────
        lda rnd_wk_wid
        clc
        adc rnd_wk_wwidth
        sta rnd_wk_wid
        ; advance zp_src by wlen bytes
        lda rnd_wk_wlen
        clc
        adc zp_src
        sta zp_src
        bcc @ww_adv_ok
        inc zp_src+1
@ww_adv_ok:
        lda #1
        sta rnd_wk_first    ; mark that we've placed at least one word
        jmp @ww_loop

@ww_done:
        ; ── Phase 3: centre — compute pad_left = (40 - wid) / 2 ──────────────
        lda #40
        sec
        sbc rnd_wk_wid      ; A = 40 - wid (always ≥ 0)
        lsr                 ; A = (40 - wid) / 2
        sta @pad            ; pad_left
        ; add pad to all x positions
        ldx #0
@rcl_pad:
        cpx rnd_wk_len
        beq @rcl_render
        lda rnd_wk_x, x
        clc
        adc @pad
        sta rnd_wk_x, x
        inx
        jmp @rcl_pad

@rcl_render:
        ; save zp_src (next-source-line start) — render phase overwrites it
        lda zp_src
        sta rnd_wk_csrc
        lda zp_src+1
        sta rnd_wk_csrc+1
        ; ── Phase 4: render each char into output buffer ────────────────────
        ldx #0
@rcl_ch:
        cpx rnd_wk_len
        bne @rcl_ch_go
        jmp @rcl_done
@rcl_ch_go:
        stx @chi            ; save char index
        ; look up tile set index from screen code (mask color bits 6-7)
        lda rnd_wk_char, x
        and #$3F
        tay
        lda tile_char_idx, y    ; set_idx (0-43)
        ; look up tile set pointer via table
        tay
        lda tile_off_lo, y
        sta zp_src
        lda tile_off_hi, y
        sta zp_src+1
        ; compute output row 0 ptr: rnd_out_lo + x_pos (column = tile 0 of char)
        ldx @chi
        lda rnd_wk_x, x        ; x column position
        clc
        adc rnd_out_lo
        sta rnd_out_lo
        lda rnd_out_hi
        adc #0
        sta rnd_out_hi
        ; write 9 tile bytes: 3 cols × 3 rows (row stride = 40)
        ; row 0:
        ldy #0
        lda (zp_src), y
        sta (rnd_out_lo), y
        iny
        lda (zp_src), y
        sta (rnd_out_lo), y
        iny
        lda (zp_src), y
        sta (rnd_out_lo), y
        ; advance output ptr by 40 → row 1
        lda rnd_out_lo
        clc
        adc #40
        sta rnd_out_lo
        bcc @ok1r
        inc rnd_out_hi
@ok1r:
        ; row 1 (tile bytes 3-5):
        ldy #3
        lda (zp_src), y
        ldy #0
        sta (rnd_out_lo), y
        ldy #4
        lda (zp_src), y
        ldy #1
        sta (rnd_out_lo), y
        ldy #5
        lda (zp_src), y
        ldy #2
        sta (rnd_out_lo), y
        ; advance output ptr by 40 → row 2
        lda rnd_out_lo
        clc
        adc #40
        sta rnd_out_lo
        bcc @ok2r
        inc rnd_out_hi
@ok2r:
        ; row 2 (tile bytes 6-8):
        ldy #6
        lda (zp_src), y
        ldy #0
        sta (rnd_out_lo), y
        ldy #7
        lda (zp_src), y
        ldy #1
        sta (rnd_out_lo), y
        ldy #8
        lda (zp_src), y
        ldy #2
        sta (rnd_out_lo), y
        ; restore rnd_out_lo/hi to base of output buf (subtract 80)
        sec
        lda rnd_out_lo
        sbc #80
        sta rnd_out_lo
        bcs @ok3r
        dec rnd_out_hi
@ok3r:
        ; restore x offset: subtract rnd_wk_x back out
        ldx @chi
        sec
        lda rnd_out_lo
        sbc rnd_wk_x, x
        sta rnd_out_lo
        bcs @ok4r
        dec rnd_out_hi
@ok4r:
        ; advance to next char
        ldx @chi
        inx
        jmp @rcl_ch

@rcl_done:
        ; restore zp_src to start of next source line (saved before render phase)
        lda rnd_wk_csrc
        sta zp_src
        lda rnd_wk_csrc+1
        sta zp_src+1
        rts

; ---------------------------------------------------------------------------
;  Local storage for render_compute_line (data bytes after rts, never executed)
; ---------------------------------------------------------------------------
@wi:        .byte 0
@tmp_byte:  .byte 0
@pad:       .byte 0
@chi:       .byte 0

; ---------------------------------------------------------------------------
;  render_fill_colbuf — fill a 40-byte color linebuf from rnd_wk_char/x/len
;  Extracts color index from bits 6-7 of rnd_wk_char[], looks up base C64
;  color, and writes it to 3 consecutive columns per character.
;  Input: X preserved, zp_dst = pointer to 40-byte colbuf
;  Clobbers: A, X, Y
; ---------------------------------------------------------------------------
render_fill_top_colbuf:
        lda #<rnd_top_colbuf
        sta zp_dst
        lda #>rnd_top_colbuf
        sta zp_dst+1
        jmp render_fill_colbuf
render_fill_bot_colbuf:
        lda #<rnd_bot_colbuf
        sta zp_dst
        lda #>rnd_bot_colbuf
        sta zp_dst+1
        ; fall through
render_fill_colbuf:
        ; Fill 40 bytes with default base color ($0F = light gray)
        lda #$0F
        ldy #39
@rfc_clr:
        sta (zp_dst), y
        dey
        bpl @rfc_clr
        ; For each rendered char, fill 3 columns with its color
        ldx #0
@rfc_loop:
        cpx rnd_wk_len
        beq @rfc_done
        ; Extract 2-bit color index from bits 6-7
        lda rnd_wk_char, x
        rol
        rol
        rol
        and #$03                ; A = color index 0-3
        tay
        lda idx_to_color_base, y ; C64 base color
        sta rnd_wk_color, x    ; store for later use
        ; Write to 3 columns at rnd_wk_x[x]
        ldy rnd_wk_x, x
        sta (zp_dst), y
        iny
        sta (zp_dst), y
        iny
        sta (zp_dst), y
        inx
        jmp @rfc_loop
@rfc_done:
        rts

; ---------------------------------------------------------------------------
;  clamp_target_rows
;  Ensures target_rows_lo/hi <= max_rows_fwd_lo/hi.
; ---------------------------------------------------------------------------
clamp_target_rows:
        lda target_rows_hi
        cmp max_rows_fwd_hi
        bcc @ctr_ok
        bne @ctr_clamp
        lda target_rows_lo
        cmp max_rows_fwd_lo
        bcc @ctr_ok
        beq @ctr_ok
@ctr_clamp:
        lda max_rows_fwd_lo
        sta target_rows_lo
        lda max_rows_fwd_hi
        sta target_rows_hi
@ctr_ok:
        rts

; ---------------------------------------------------------------------------
;  divide_by_3
;  Divides target_rows_lo/hi by 3.
;  Output: riap_quotient_lo/hi = quotient, A = remainder (0-2)
; ---------------------------------------------------------------------------
divide_by_3:
        lda #0
        sta riap_quotient_lo
        sta riap_quotient_hi
        lda target_rows_lo
        sta riap_div_tmp_lo
        lda target_rows_hi
        sta riap_div_tmp_hi
@db3_loop:
        lda riap_div_tmp_hi
        bne @db3_sub
        lda riap_div_tmp_lo
        cmp #3
        bcc @db3_done
@db3_sub:
        sec
        lda riap_div_tmp_lo
        sbc #3
        sta riap_div_tmp_lo
        bcs @db3_nob
        dec riap_div_tmp_hi
@db3_nob:
        inc riap_quotient_lo
        bne @db3_loop
        inc riap_quotient_hi
        jmp @db3_loop
@db3_done:
        lda riap_div_tmp_lo     ; remainder in A
        rts

riap_quotient_lo:  .byte 0
riap_quotient_hi:  .byte 0
riap_div_tmp_lo:   .byte 0
riap_div_tmp_hi:   .byte 0
riap_remainder:    .byte 0

; ---------------------------------------------------------------------------
;  render_init_at_position
;  Positions the scroll viewport at target_rows_lo/hi coarse rows from start.
;  Fast-forwards through rendered lines, patches scroll_start, calls
;  render_init to fill screen rows 12-24, then restores scroll_start.
;  Line L appears at screen row 12 (center).  Rows 0-11 are blank.
;  History ring is empty; backward scroll fills blanks until reaching start.
; ---------------------------------------------------------------------------
render_init_at_position:
        ; If target_rows == 0, just call render_init
        lda target_rows_lo
        ora target_rows_hi
        bne @riap_nonzero
        jmp render_init

@riap_nonzero:
        ; Save original scroll_start
        lda scroll_start_lo
        sta riap_save_lo
        lda scroll_start_hi
        sta riap_save_hi

        ; Divide target_rows by 3 → L (rendered line count)
        jsr divide_by_3
        ; Snap target_rows to L*3 (subtract remainder)
        sec
        lda target_rows_lo
        sbc riap_div_tmp_lo         ; remainder still in riap_div_tmp_lo
        sta target_rows_lo
        bcs @riap_no_borrow
        dec target_rows_hi
@riap_no_borrow:

        ; Fast-forward L rendered lines from scroll_start
        lda scroll_start_lo
        sta zp_src
        lda scroll_start_hi
        sta zp_src+1
@riap_ff:
        lda riap_quotient_lo
        ora riap_quotient_hi
        beq @riap_ff_done
        lda #<rnd_bot_linebuf
        sta zp_dst
        lda #>rnd_bot_linebuf
        sta zp_dst+1
        jsr render_compute_line
        lda riap_quotient_lo
        bne @riap_dec
        dec riap_quotient_hi
@riap_dec:
        dec riap_quotient_lo
        jmp @riap_ff

@riap_ff_done:
        ; Patch scroll_start to line L
        lda zp_src
        sta scroll_start_lo
        lda zp_src+1
        sta scroll_start_hi

        ; render_init fills rows 12-24 starting from patched scroll_start
        jsr render_init

        ; Restore original scroll_start
        lda riap_save_lo
        sta scroll_start_lo
        lda riap_save_hi
        sta scroll_start_hi

        ; Set rows_from_start = target_rows (rounded down to multiple of 3)
        ; target_rows = L * 3 (the division discarded the remainder)
        ; Recompute: riap_quotient was consumed, so use target_rows directly
        ; but snapped to a multiple of 3.
        lda target_rows_lo
        sta rows_from_start_lo
        lda target_rows_hi
        sta rows_from_start_hi
        rts

riap_save_lo: .byte 0
riap_save_hi: .byte 0

; ---------------------------------------------------------------------------
;  compute_f3_target
;  Finds the rendered line containing the editor cursor position.
;  Sets target_rows_lo/hi = rendered_line_number * 3.
;  Uses rnd_wk_csrc to hold cursor address (safe: only used inside
;  render_compute_line which we call, but we save/restore around it).
; ---------------------------------------------------------------------------
compute_f3_target:
        ; Compute cursor doc_buffer address:
        ;   cursor_addr = page_addr[current_page] + cursor_y * 40 + cursor_x
        ldx current_page
        lda page_addr_lo, x
        sta cf3_cursor_lo
        lda page_addr_hi, x
        sta cf3_cursor_hi

        ; Add cursor_y * 40 (y*40 = y*8 + y*32)
        lda cursor_y
        asl                         ; *2
        asl                         ; *4
        asl                         ; *8
        sta cf3_tmp
        lda #0
        sta cf3_tmp+1
        lda cursor_y
        asl                         ; *2
        asl                         ; *4
        asl                         ; *8
        asl                         ; *16
        rol cf3_tmp+1
        asl                         ; *32
        rol cf3_tmp+1
        clc
        adc cf3_tmp                 ; lo byte of y*40
        sta cf3_tmp
        bcc @cf3_no_carry1
        inc cf3_tmp+1
@cf3_no_carry1:
        clc
        lda cf3_cursor_lo
        adc cf3_tmp
        sta cf3_cursor_lo
        lda cf3_cursor_hi
        adc cf3_tmp+1
        sta cf3_cursor_hi

        ; Add cursor_x
        clc
        lda cf3_cursor_lo
        adc cursor_x
        sta cf3_cursor_lo
        bcc @cf3_no_carry2
        inc cf3_cursor_hi
@cf3_no_carry2:
        ; cf3_cursor_lo/hi = absolute doc_buffer address of cursor
        jmp find_line_for_addr      ; tail call

; ---------------------------------------------------------------------------
;  find_line_for_addr
;  Given a doc_buffer address in cf3_cursor_lo/hi, iterates rendered lines
;  from scroll_start to find which line contains it.
;  Sets target_rows_lo/hi = rendered_line_number * 3.
; ---------------------------------------------------------------------------
find_line_for_addr:
        lda scroll_start_lo
        sta zp_src
        lda scroll_start_hi
        sta zp_src+1
        lda #0
        sta cf3_line_lo
        sta cf3_line_hi

@fla_loop:
        lda #<rnd_bot_linebuf
        sta zp_dst
        lda #>rnd_bot_linebuf
        sta zp_dst+1
        jsr render_compute_line

        ; Check if cursor_addr < zp_src (i.e., addr is within this line)
        lda cf3_cursor_hi
        cmp zp_src+1
        bcc @fla_found
        bne @fla_next
        lda cf3_cursor_lo
        cmp zp_src
        bcc @fla_found

@fla_next:
        inc cf3_line_lo
        bne @fla_check_bounds
        inc cf3_line_hi
@fla_check_bounds:
        lda zp_src+1
        cmp scroll_end_hi
        bcc @fla_loop
        bne @fla_found
        lda zp_src
        cmp scroll_end_lo
        bcc @fla_loop

@fla_found:
        ; target_rows = cf3_line * 3 (line*2 + line)
        lda cf3_line_lo
        asl
        sta target_rows_lo
        lda cf3_line_hi
        rol
        sta target_rows_hi
        clc
        lda target_rows_lo
        adc cf3_line_lo
        sta target_rows_lo
        lda target_rows_hi
        adc cf3_line_hi
        sta target_rows_hi
        rts

cf3_cursor_lo: .byte 0
cf3_cursor_hi: .byte 0
cf3_line_lo:   .byte 0
cf3_line_hi:   .byte 0
cf3_tmp:       .byte 0, 0

; ---------------------------------------------------------------------------
;  find_center_doc_ptr
;  Fast-forwards through rows_from_start/3 rendered lines from scroll_start.
;  On return, zp_src = doc_buffer address of the start of the center line.
; ---------------------------------------------------------------------------
find_center_doc_ptr:
        lda rows_from_start_lo
        sta target_rows_lo
        lda rows_from_start_hi
        sta target_rows_hi
        jsr divide_by_3
        ; riap_quotient_lo/hi = number of rendered lines to skip

        lda scroll_start_lo
        sta zp_src
        lda scroll_start_hi
        sta zp_src+1

@fcdp_loop:
        lda riap_quotient_lo
        ora riap_quotient_hi
        beq @fcdp_done
        lda #<rnd_bot_linebuf
        sta zp_dst
        lda #>rnd_bot_linebuf
        sta zp_dst+1
        jsr render_compute_line
        lda riap_quotient_lo
        bne @fcdp_dec
        dec riap_quotient_hi
@fcdp_dec:
        dec riap_quotient_lo
        jmp @fcdp_loop
@fcdp_done:
        ; zp_src = start of center line in doc_buffer
        rts

; ---------------------------------------------------------------------------
;  search_hash_prev
;  Searches backward from the end of the line before the center line for #.
;  Sets target_rows_lo/hi to the found line, or 0 (start) if not found.
; ---------------------------------------------------------------------------
search_hash_prev:
        jsr find_center_doc_ptr     ; zp_src = start of center line

        ; Check if we're already at scroll_start (no previous line)
        lda zp_src+1
        cmp scroll_start_hi
        bne @shp_has_prev
        lda zp_src
        cmp scroll_start_lo
        beq @shp_not_found          ; at start, no previous line
@shp_has_prev:
        ; Decrement to last byte of previous line
        lda zp_src
        bne :+
        dec zp_src+1
:       dec zp_src

@shp_loop:
        ; Check bounds: zp_src < scroll_start → not found
        lda zp_src+1
        cmp scroll_start_hi
        bcc @shp_not_found
        bne @shp_check
        lda zp_src
        cmp scroll_start_lo
        bcc @shp_not_found
@shp_check:
        ldy #0
        lda (zp_src), y
        and #$3F                    ; mask color bits
        cmp #$23                    ; # screen code
        beq @shp_found
        ; Decrement pointer
        lda zp_src
        bne :+
        dec zp_src+1
:       dec zp_src
        jmp @shp_loop

@shp_found:
        ; Store address for line lookup
        lda zp_src
        sta cf3_cursor_lo
        lda zp_src+1
        sta cf3_cursor_hi
        jmp find_line_for_addr      ; sets target_rows, returns

@shp_not_found:
        ; No # found — go to start of document
        lda #0
        sta target_rows_lo
        sta target_rows_hi
        rts

; ---------------------------------------------------------------------------
;  search_hash_next
;  Searches forward from the start of the line after the center line for #.
;  Sets target_rows_lo/hi if found (carry clear), carry set if not found.
; ---------------------------------------------------------------------------
search_hash_next:
        jsr find_center_doc_ptr     ; zp_src = start of center line

        ; Advance past center line to get start of next line
        lda #<rnd_bot_linebuf
        sta zp_dst
        lda #>rnd_bot_linebuf
        sta zp_dst+1
        jsr render_compute_line     ; zp_src = start of next line

@shn_loop:
        ; Check bounds: zp_src >= scroll_end → not found
        lda zp_src+1
        cmp scroll_end_hi
        bcc @shn_check
        bne @shn_not_found
        lda zp_src
        cmp scroll_end_lo
        bcs @shn_not_found
@shn_check:
        ldy #0
        lda (zp_src), y
        and #$3F                    ; mask color bits
        cmp #$23                    ; # screen code
        beq @shn_found
        ; Increment pointer
        inc zp_src
        bne @shn_loop
        inc zp_src+1
        jmp @shn_loop

@shn_found:
        lda zp_src
        sta cf3_cursor_lo
        lda zp_src+1
        sta cf3_cursor_hi
        jsr find_line_for_addr      ; sets target_rows
        clc                         ; found
        rts

@shn_not_found:
        sec                         ; not found
        rts

; ---------------------------------------------------------------------------
;  count_rendered_lines
;  Iterates through the entire document text, calling render_compute_line to
;  count how many rendered lines the content produces.  Stores the forward
;  scroll limit (3 × line count) in max_rows_fwd_lo/hi.
;  Must be called BEFORE render_init (uses rnd_bot_linebuf as scratch).
; ---------------------------------------------------------------------------
count_rendered_lines:
        lda scroll_start_lo
        sta zp_src
        lda scroll_start_hi
        sta zp_src+1
        lda #0
        sta max_rows_fwd_lo
        sta max_rows_fwd_hi
@crl_loop:
        ; check if zp_src >= scroll_end
        lda zp_src+1
        cmp scroll_end_hi
        bcc @crl_count
        bne @crl_done
        lda zp_src
        cmp scroll_end_lo
        bcs @crl_done
@crl_count:
        lda #<rnd_bot_linebuf
        sta zp_dst
        lda #>rnd_bot_linebuf
        sta zp_dst+1
        jsr render_compute_line
        ; max_rows_fwd += 3
        clc
        lda max_rows_fwd_lo
        adc #3
        sta max_rows_fwd_lo
        bcc @crl_loop
        inc max_rows_fwd_hi
        jmp @crl_loop
@crl_done:
        ; Add 3 extra rows so last content line stops at screen row 6
        clc
        lda max_rows_fwd_lo
        adc #3
        sta max_rows_fwd_lo
        bcc @crl_ret
        inc max_rows_fwd_hi
@crl_ret:
        rts

; ---------------------------------------------------------------------------
;  render_init
;  Initialise render cursors and fill all 25 screen rows with large chars.
;  Called from enter_scroll_mode before IRQ chain is installed.
; ---------------------------------------------------------------------------
render_init:
        lda #0
        sta rnd_hist_head
        sta rnd_hist_count
        sta rnd_hist_bot_head
        sta rnd_hist_bot_count
        sta rnd_top_row
        lda #4
        sta rnd_top_skip
        lda #0
        sta rows_from_start_lo
        sta rows_from_start_hi

        lda scroll_start_lo
        sta zp_src
        sta rnd_top_lo
        lda scroll_start_hi
        sta zp_src+1
        sta rnd_top_hi

        ; ── Blank rnd_top_linebuf; text starts at screen row 12 (line 13) ───
        ; rnd_top_next = scroll_start so first top-cursor advance (after 3
        ; forward scrolls) renders doc line 0 into the linebuf.
        lda scroll_start_lo
        sta rnd_top_next_lo
        lda scroll_start_hi
        sta rnd_top_next_hi
        lda #0
        ldy #0
@ri_clr_top:
        sta rnd_top_linebuf, y
        iny
        cpy #120
        bne @ri_clr_top
        ; ── Blank color linebufs (default base $0F) ──────────────────────
        lda #$0F
        ldy #0
@ri_clr_colbufs:
        sta rnd_top_colbuf, y
        sta rnd_bot_colbuf, y
        iny
        cpy #40
        bne @ri_clr_colbufs

        ; ── Zero-fill screen rows 0-11 (480 bytes = 2×256 - 32) ─────────
        lda #<SCREEN
        sta zp_dst
        lda #>SCREEN
        sta zp_dst+1
        lda #0
        ldy #0
@ri_clr_scr1:
        sta (zp_dst), y
        iny
        bne @ri_clr_scr1            ; first 256 bytes (rows 0–6)
        inc zp_dst+1
        ldy #0
@ri_clr_scr2:
        sta (zp_dst), y
        iny
        cpy #224
        bne @ri_clr_scr2            ; 224 more bytes (rows 6–11), total 480

        ; Fall through to render_init_fill (rows 12-24 + bot linebuf)
        jmp render_init_fill

; ---------------------------------------------------------------------------
;  render_init_fill
;  Fills screen rows 12-24 and rnd_bot_linebuf from zp_src.
;  Expects zp_src pointing to the first content line for screen row 12.
;  Sets rnd_bot_lo/hi, rnd_bot_next_lo/hi, rnd_bot_row.
; ---------------------------------------------------------------------------
render_init_fill:
        ; ── Set destination to screen row 12 (SCREEN + 480) ──────────────
        lda #<(SCREEN + 480)
        sta zp_dst
        lda #>(SCREEN + 480)
        sta zp_dst+1
        ; Track COLRAM destination row (starts at row 12)
        lda #12
        sta rif_colrow

        ; ── Lines 0-3: render into rnd_bot_linebuf, copy to rows 12-23 ───
        ldx #4
@rif_l4:
        stx rif_cnt
        jsr ri_render_bot       ; renders to rnd_bot_linebuf + rnd_bot_colbuf
        lda zp_src
        sta rif_next_lo
        lda zp_src+1
        sta rif_next_hi
        lda #<rnd_bot_linebuf
        sta zp_src
        lda #>rnd_bot_linebuf
        sta zp_src+1
        jsr ri_copy120_adv
        ; Set COLRAM for the 3 rows just copied
        jsr ri_set_colram_3rows
        lda rif_next_lo
        sta zp_src
        lda rif_next_hi
        sta zp_src+1
        ldx rif_cnt
        dex
        bne @rif_l4

        ; ── Render line 4 → rnd_bot_linebuf (final bot position) ─────────
        lda zp_src
        sta rnd_bot_lo
        lda zp_src+1
        sta rnd_bot_hi
        jsr ri_render_bot
        lda zp_src
        sta rnd_bot_next_lo
        lda zp_src+1
        sta rnd_bot_next_hi
        ; copy only 1 row (40 bytes) from rnd_bot_linebuf to screen row 24
        lda #<rnd_bot_linebuf
        sta zp_src
        lda #>rnd_bot_linebuf
        sta zp_src+1
        ldy #0
@rif_c40:
        lda (zp_src), y
        sta (zp_dst), y
        iny
        cpy #COLS
        bne @rif_c40

        ; Set COLRAM for row 24
        ldx #39
@rif_c40_col:
        lda rnd_bot_colbuf, x
        sta COLRAM + 24*COLS, x
        dex
        bpl @rif_c40_col

        lda #1
        sta rnd_bot_row
        rts

; ---------------------------------------------------------------------------
;  Shared render helpers (used by render_init, render_init_fill,
;  render_init_at_position)
; ---------------------------------------------------------------------------

        ; helper: render from zp_src into rnd_top_linebuf + fill rnd_top_colbuf
ri_render_top:
        lda zp_dst
        sta ri_dst_save
        lda zp_dst+1
        sta ri_dst_save+1
        lda #<rnd_top_linebuf
        sta zp_dst
        lda #>rnd_top_linebuf
        sta zp_dst+1
        jsr render_compute_line
        jsr render_fill_top_colbuf
        lda ri_dst_save
        sta zp_dst
        lda ri_dst_save+1
        sta zp_dst+1
        rts

        ; helper: render from zp_src into rnd_bot_linebuf + fill rnd_bot_colbuf
ri_render_bot:
        lda zp_dst
        sta ri_dst_save
        lda zp_dst+1
        sta ri_dst_save+1
        lda #<rnd_bot_linebuf
        sta zp_dst
        lda #>rnd_bot_linebuf
        sta zp_dst+1
        jsr render_compute_line
        jsr render_fill_bot_colbuf
        lda ri_dst_save
        sta zp_dst
        lda ri_dst_save+1
        sta zp_dst+1
        rts

        ; helper: copy 120 bytes from (zp_src) to (zp_dst), advance zp_dst by 120
ri_copy120_adv:
        ldy #0
@rc120: lda (zp_src), y
        sta (zp_dst), y
        iny
        cpy #120
        bne @rc120
        lda zp_dst
        clc
        adc #120
        sta zp_dst
        bcc @rc120_ok
        inc zp_dst+1
@rc120_ok:
        rts

rif_cnt:      .byte 0
rif_next_lo:  .byte 0
rif_next_hi:  .byte 0
rif_colrow:   .byte 0
ri_dst_save:  .byte 0, 0

; ---------------------------------------------------------------------------
;  ri_set_colram_3rows — set COLRAM for 3 screen rows from rnd_bot_colbuf
;  Uses rif_colrow as starting row number (0-24).  Applies zone mapping:
;  rows 9-15 get light counterpart, others get base color.
;  Advances rif_colrow by 3.  Clobbers zp_src.
; ---------------------------------------------------------------------------
ri_set_colram_3rows:
        lda rif_colrow
        sta @sc3_row
        lda #3
        sta @sc3_cnt
@sc3_loop:
        ; Compute COLRAM address for this row: COLRAM + row*40
        lda #0
        sta zp_src+1
        lda @sc3_row
        asl             ; *2
        asl             ; *4
        asl             ; *8
        sta zp_src
        asl             ; *16
        rol zp_src+1
        asl             ; *32
        rol zp_src+1
        clc
        adc zp_src      ; *40 lo
        sta zp_src
        lda zp_src+1
        adc #0
        sta zp_src+1
        ; Add COLRAM base
        clc
        lda zp_src
        adc #<COLRAM
        sta zp_src
        lda zp_src+1
        adc #>COLRAM
        sta zp_src+1
        ; Determine if this row is in the inner zone (rows 9-15)
        lda @sc3_row
        cmp #9
        bcc @sc3_base       ; row < 9 → outer → base
        cmp #16
        bcs @sc3_base       ; row >= 16 → outer → base
        ; Inner zone: use light colors
        ldy #39
@sc3_light:
        lda rnd_bot_colbuf, y
        tax
        lda color_to_light, x
        sta (zp_src), y
        dey
        bpl @sc3_light
        jmp @sc3_next
@sc3_base:
        ; Outer zone: use base colors directly
        ldy #39
@sc3_base_l:
        lda rnd_bot_colbuf, y
        sta (zp_src), y
        dey
        bpl @sc3_base_l
@sc3_next:
        inc @sc3_row
        dec @sc3_cnt
        bne @sc3_loop
        ; Advance rif_colrow by 3
        lda rif_colrow
        clc
        adc #3
        sta rif_colrow
        rts
@sc3_row: .byte 0
@sc3_cnt: .byte 0

; ---------------------------------------------------------------------------
;  render_advance_top — advance top cursor one tile row forward
; ---------------------------------------------------------------------------
render_advance_top:
        inc rnd_top_row
        lda rnd_top_row
        cmp #3
        bne @rat_done
        ; Check if we are still in the initial blank-tile phase.
        ; The top 12 screen rows are blank at init (4 blank tiles).
        ; rnd_top_skip counts down from 4; while > 0 we suppress history
        ; pushes so that the top cursor stays in sync with the screen top
        ; without poisoning the history ring with document positions that
        ; are still visible on screen.
        lda rnd_top_skip
        beq @rat_do_push        ; skip exhausted — normal rollover
        dec rnd_top_skip
        bne @rat_full_skip      ; skip still > 0 — blank tile, no render
        ; skip just reached 0: render line 0 into linebuf but do NOT push
        ; to history (line 0 is arriving at the top for the first time).
        jmp @rat_render
@rat_full_skip:
        ; Still in blank region — just reset the row counter and return.
        lda #0
        sta rnd_top_row
        rts
@rat_do_push:
        ; push old rnd_top_lo/hi to top history ring
        ldx rnd_hist_head
        lda rnd_top_lo
        sta rnd_hist_lo, x
        lda rnd_top_hi
        sta rnd_hist_hi, x
        inx
        cpx #240
        bne @rat_nw
        ldx #0
@rat_nw:
        stx rnd_hist_head
        lda rnd_hist_count
        cmp #240
        beq @rat_render
        inc rnd_hist_count
@rat_render:
        ; advance top ptr to next rendered line
        lda rnd_top_next_lo
        sta rnd_top_lo
        lda rnd_top_next_hi
        sta rnd_top_hi
        ; render new top line
        lda rnd_top_lo
        sta zp_src
        lda rnd_top_hi
        sta zp_src+1
        lda #<rnd_top_linebuf
        sta zp_dst
        lda #>rnd_top_linebuf
        sta zp_dst+1
        jsr render_compute_line
        jsr render_fill_top_colbuf
        lda zp_src
        sta rnd_top_next_lo
        lda zp_src+1
        sta rnd_top_next_hi
        lda #0
        sta rnd_top_row
@rat_done:
        rts

; ---------------------------------------------------------------------------
;  render_advance_bot — advance bot cursor one tile row forward
; ---------------------------------------------------------------------------
render_advance_bot:
        inc rnd_bot_row
        lda rnd_bot_row
        cmp #3
        bne @rab_done
        ldx rnd_hist_bot_head
        lda rnd_bot_lo
        sta rnd_hist_bot_lo, x
        lda rnd_bot_hi
        sta rnd_hist_bot_hi, x
        inx
        cpx #240
        bne @rab_nw
        ldx #0
@rab_nw:
        stx rnd_hist_bot_head
        lda rnd_hist_bot_count
        cmp #240
        beq @rab_full
        inc rnd_hist_bot_count
@rab_full:
        lda rnd_bot_next_lo
        sta rnd_bot_lo
        lda rnd_bot_next_hi
        sta rnd_bot_hi
        lda rnd_bot_lo
        sta zp_src
        lda rnd_bot_hi
        sta zp_src+1
        lda #<rnd_bot_linebuf
        sta zp_dst
        lda #>rnd_bot_linebuf
        sta zp_dst+1
        jsr render_compute_line
        jsr render_fill_bot_colbuf
        lda zp_src
        sta rnd_bot_next_lo
        lda zp_src+1
        sta rnd_bot_next_hi
        lda #0
        sta rnd_bot_row
@rab_done:
        rts

; ---------------------------------------------------------------------------
;  render_retreat_top — move top cursor back one tile row
; ---------------------------------------------------------------------------
render_retreat_top:
        dec rnd_top_row
        bmi @rrt_under
        jmp @rrt_done
@rrt_under:
        ; underflowed: was 0, now $FF
        lda rnd_hist_count
        beq @rrt_clamp      ; at document start, clamp to 0
        ; save current rnd_top_lo/hi as new next ptr
        lda rnd_top_lo
        sta rnd_top_next_lo
        lda rnd_top_hi
        sta rnd_top_next_hi
        ; pop from ring: head = (head-1+240) mod 240
        lda rnd_hist_head
        beq @rrt_wrap_h
        dec rnd_hist_head
        jmp @rrt_got_h
@rrt_wrap_h:
        lda #239
        sta rnd_hist_head
@rrt_got_h:
        dec rnd_hist_count
        ldx rnd_hist_head
        lda rnd_hist_lo, x
        sta rnd_top_lo
        lda rnd_hist_hi, x
        sta rnd_top_hi
        ; re-render this line into rnd_top_linebuf
        lda rnd_top_lo
        sta zp_src
        lda rnd_top_hi
        sta zp_src+1
        lda #<rnd_top_linebuf
        sta zp_dst
        lda #>rnd_top_linebuf
        sta zp_dst+1
        jsr render_compute_line
        jsr render_fill_top_colbuf
        lda zp_src
        sta rnd_top_next_lo
        lda zp_src+1
        sta rnd_top_next_hi
        lda #2
        sta rnd_top_row
        rts
@rrt_clamp:
        ; Re-entering blank region above content: restore skip counter,
        ; reset doc pointers to initial top position, and clear the linebuf
        ; so that stale content doesn't appear as duplicate text in the
        ; blank area.  Uses init_top (set at scroll entry) instead of
        ; scroll_start so that F5 resume / F3 jump positions are respected.
        lda rnd_top_skip
        cmp #4
        beq @rrt_skip_ok
        inc rnd_top_skip
@rrt_skip_ok:
        lda #2                      ; retreat to tile row 2 of previous blank line
        sta rnd_top_row
        lda init_top_lo
        sta rnd_top_lo
        sta rnd_top_next_lo
        lda init_top_hi
        sta rnd_top_hi
        sta rnd_top_next_hi
        ; Clear linebuf (blank tile-line) and colbuf
        lda #0
        ldy #0
@rrt_clr:
        sta rnd_top_linebuf, y
        iny
        cpy #120
        bne @rrt_clr
        lda #$0F
        ldy #0
@rrt_clr_col:
        sta rnd_top_colbuf, y
        iny
        cpy #40
        bne @rrt_clr_col
        rts
@rrt_done:
        rts

; ---------------------------------------------------------------------------
;  render_retreat_bot — move bot cursor back one tile row
; ---------------------------------------------------------------------------
render_retreat_bot:
        dec rnd_bot_row
        bpl @rrb_done
        lda rnd_hist_bot_count
        beq @rrb_clamp
        lda rnd_bot_lo
        sta rnd_bot_next_lo
        lda rnd_bot_hi
        sta rnd_bot_next_hi
        lda rnd_hist_bot_head
        beq @rrb_wrap_h
        dec rnd_hist_bot_head
        jmp @rrb_got_h
@rrb_wrap_h:
        lda #239
        sta rnd_hist_bot_head
@rrb_got_h:
        dec rnd_hist_bot_count
        ldx rnd_hist_bot_head
        lda rnd_hist_bot_lo, x
        sta rnd_bot_lo
        lda rnd_hist_bot_hi, x
        sta rnd_bot_hi
        lda rnd_bot_lo
        sta zp_src
        lda rnd_bot_hi
        sta zp_src+1
        lda #<rnd_bot_linebuf
        sta zp_dst
        lda #>rnd_bot_linebuf
        sta zp_dst+1
        jsr render_compute_line
        jsr render_fill_bot_colbuf
        lda zp_src
        sta rnd_bot_next_lo
        lda zp_src+1
        sta rnd_bot_next_hi
        lda #2
        sta rnd_bot_row
        rts
@rrb_clamp:
        lda #0
        sta rnd_bot_row
@rrb_done:
        rts

; ---------------------------------------------------------------------------
;  PAL/NTSC detection result (0=PAL, 1=NTSC)
; ---------------------------------------------------------------------------
is_ntsc:        .byte 0

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
;  scroll_screen_down work buffers: new row 0 and the bottom row of each
;  band (saved before the band overwrites it, read by the next band)
; ---------------------------------------------------------------------------
newrow_buf:  .res 40
ssd_sv0s:    .res 40
ssd_sv0c:    .res 40
ssd_sv1s:    .res 40
ssd_sv1c:    .res 40
ssd_sv2s:    .res 40
ssd_sv2c:    .res 40
ssd_sv3s:    .res 40
ssd_sv3c:    .res 40

; Coarse-scroll pipeline state
next_fine:   .byte 0                    ; fine scroll to show at next vblank
frame_ctr:   .byte 0                    ; incremented every vblank (IRQ state 2)
start_frame: .byte 0                    ; frame_ctr when a coarse copy started
wait_tgt:    .byte 0                    ; raster line wait_beam_past waits for
s2_pixels:   .byte 0                    ; IRQ state 2 scratch

; Configurable colors
cfg_font_color: .byte $0F               ; editor font color (C64 value, default light gray)
cfg_bg_color:   .byte $0B               ; scroll background color (C64 value, default dark gray)

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

; ---------------------------------------------------------------------------
;  Color system lookup tables
; ---------------------------------------------------------------------------
; 2-bit color index → C64 base color (outer zone / editor)
idx_to_color_base:  .byte $0F, $02, $06, $05   ; light gray, red, blue, green
; 2-bit color index → C64 light color (reading zone)
idx_to_color_light: .byte $01, $0A, $0E, $0D   ; white, light red, light blue, light green
; C64 color value → light counterpart (for zone boundary remap)
color_to_light:
        .byte $00,$01,$0A,$03,$04,$0D,$0E,$07   ; 0-7
        .byte $08,$09,$0A,$0B,$0C,$0D,$0E,$01   ; 8-15
; C64 color value → base counterpart (for zone boundary remap)
color_to_base:
        .byte $00,$0F,$02,$03,$04,$05,$06,$07   ; 0-7
        .byte $08,$09,$02,$0B,$0C,$05,$06,$0F   ; 8-15
; C64 color value → 2-bit color index (for editor save encoding)
color_to_idx:
        .byte 0,0,1,0,0,3,2,0                  ; 0-7
        .byte 0,0,1,0,0,3,2,0                  ; 8-15

; BASIC ROM 5-byte float constants
fp_256:         .byte $89,$00,$00,$00,$00       ; 256.0 (for 8.8 conversion)
fp_0_01:        .byte $7A,$23,$D7,$0A,$3D       ; 0.01 (baseSpeed step)
fp_0_05:        .byte $7C,$4C,$CC,$CC,$CD       ; 0.05 (curvature step)
fp_1_20:        .byte $81,$19,$99,$99,$9A       ; 1.20 (initial curvature)
fp_0_15:        .byte $7E,$19,$99,$99,$9A       ; 0.15 (initial baseSpeed)
fp_0_50:        .byte $80,$00,$00,$00,$00       ; 0.50 (min curvature / rounding)
fp_2_0:         .byte $82,$00,$00,$00,$00       ; 2.0 (max curvature)
fp_4_0:         .byte $83,$00,$00,$00,$00       ; 4.0 (max baseSpeed)
fp_ntsc_scale:  .byte $80,$55,$55,$55,$55       ; 5/6 ≈ 0.8333 (NTSC 60fps→PAL 50fps)
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
; --- Page 1: Intro + Scroll + Editor controls ---
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
; Line 7: " # PROMPTER SCREEN:                    "
.byte __,$23,__,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,sc_E,sc_R,__,sc_S,sc_C,sc_R,sc_E,sc_E,sc_N,_co,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 8: blank
.byte BLK
; Line 9: "  KEYS 1 TO 9, 0  SET SPEED            "
.byte __,__,sc_K,sc_E,sc_Y,sc_S,__,_1,__,sc_T,sc_O,__,_9,_c,__,_0,__,__,sc_S,sc_E,sc_T,__,sc_S,sc_P,sc_E,sc_E,sc_D,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 10: "  1=SLOWEST  0=FASTEST                 "
.byte __,__,_1,_eq,sc_S,sc_L,sc_O,sc_W,sc_E,sc_S,sc_T,__,__,_0,_eq,sc_F,sc_A,sc_S,sc_T,sc_E,sc_S,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 11: "  SHIFT LOCK   REVERSE SCROLL          "
.byte __,__,sc_S,sc_H,sc_I,sc_F,sc_T,__,sc_L,sc_O,sc_C,sc_K,__,__,__,sc_R,sc_E,sc_V,sc_E,sc_R,sc_S,sc_E,__,sc_S,sc_C,sc_R,sc_O,sc_L,sc_L,__,__,__,__,__,__,__,__,__,__,__
; Line 12: "  F1  GO TO CONFIG SCREEN              "
.byte __,__,sc_F,_1,__,__,sc_G,sc_O,__,sc_T,sc_O,__,sc_C,sc_O,sc_N,sc_F,sc_I,sc_G,__,sc_S,sc_C,sc_R,sc_E,sc_E,sc_N,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 13: "  F3  OPEN EDITOR                      "
.byte __,__,sc_F,_3,__,__,sc_O,sc_P,sc_E,sc_N,__,sc_E,sc_D,sc_I,sc_T,sc_O,sc_R,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 14: "  T     START FROM THE TOP             "
.byte __,__,sc_T,__,__,__,__,__,sc_S,sc_T,sc_A,sc_R,sc_T,__,sc_F,sc_R,sc_O,sc_M,__,sc_T,sc_H,sc_E,__,sc_T,sc_O,sc_P,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 15: "  ,     GO TO PREV #                  "
.byte __,__,_c,__,__,__,__,__,sc_G,sc_O,__,sc_T,sc_O,__,sc_P,sc_R,sc_E,sc_V,__,$23,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 16: "  .     GO TO NEXT #                  "
.byte __,__,_d,__,__,__,__,__,sc_G,sc_O,__,sc_T,sc_O,__,sc_N,sc_E,sc_X,sc_T,__,$23,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 17: blank
.byte BLK
; Line 18: " # EDITOR SCREEN:                      "
.byte __,$23,__,sc_E,sc_D,sc_I,sc_T,sc_O,sc_R,__,sc_S,sc_C,sc_R,sc_E,sc_E,sc_N,_co,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 19: blank
.byte BLK
; Line 20: "  TYPE TO ENTER TEXT.                   "
.byte __,__,sc_T,sc_Y,sc_P,sc_E,__,sc_T,sc_O,__,sc_E,sc_N,sc_T,sc_E,sc_R,__,sc_T,sc_E,sc_X,sc_T,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 21: "  USE CURSOR KEYS TO MOVE.             "
.byte __,__,sc_U,sc_S,sc_E,__,sc_C,sc_U,sc_R,sc_S,sc_O,sc_R,__,sc_K,sc_E,sc_Y,sc_S,__,sc_T,sc_O,__,sc_M,sc_O,sc_V,sc_E,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 22: "  F7  NEXT PAGE                        "
.byte __,__,sc_F,_7,__,__,sc_N,sc_E,sc_X,sc_T,__,sc_P,sc_A,sc_G,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 23: "  F8  PREVIOUS PAGE                    "
.byte __,__,sc_F,_8,__,__,sc_P,sc_R,sc_E,sc_V,sc_I,sc_O,sc_U,sc_S,__,sc_P,sc_A,sc_G,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__

; --- Page 2: Editor Ctrl keys + Config + new text ---
; Line 0: "  F1  GO TO CONFIG SCREEN              "
.byte __,__,sc_F,_1,__,__,sc_G,sc_O,__,sc_T,sc_O,__,sc_C,sc_O,sc_N,sc_F,sc_I,sc_G,__,sc_S,sc_C,sc_R,sc_E,sc_E,sc_N,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 1: "  F3  CHANGE TEXT COLOR                 "
.byte __,__,sc_F,_3,__,__,sc_C,sc_H,sc_A,sc_N,sc_G,sc_E,__,sc_T,sc_E,sc_X,sc_T,__,sc_C,sc_O,sc_L,sc_O,sc_R,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 2: "  F4  CHANGE BACKGROUND COLOR          "
.byte __,__,sc_F,_4,__,__,sc_C,sc_H,sc_A,sc_N,sc_G,sc_E,__,sc_B,sc_A,sc_C,sc_K,sc_G,sc_R,sc_O,sc_U,sc_N,sc_D,__,sc_C,sc_O,sc_L,sc_O,sc_R,__,__,__,__,__,__,__,__,__,__,__
; Line 3: "  F5  START PROMPTING FROM LAST POS.   "
.byte __,__,sc_F,_5,__,__,sc_S,sc_T,sc_A,sc_R,sc_T,__,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,sc_I,sc_N,sc_G,__,sc_F,sc_R,sc_O,sc_M,__,sc_L,sc_A,sc_S,sc_T,__,sc_P,sc_O,sc_S,_d,__,__,__,__
; Line 4: "  F6  START PROMPTING FROM CURSOR POS. "
.byte __,__,sc_F,_6,__,__,sc_S,sc_T,sc_A,sc_R,sc_T,__,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,sc_I,sc_N,sc_G,__,sc_F,sc_R,sc_O,sc_M,__,sc_C,sc_U,sc_R,sc_S,sc_O,sc_R,__,sc_P,sc_O,sc_S,_d,__,__
; Line 5: "  CTRL+S    SAVE TO DISK               "
.byte __,__,sc_C,sc_T,sc_R,sc_L,_pl,sc_S,__,__,__,__,sc_S,sc_A,sc_V,sc_E,__,sc_T,sc_O,__,sc_D,sc_I,sc_S,sc_K,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 2: "  CTRL+O    LOAD FROM DISK             "
.byte __,__,sc_C,sc_T,sc_R,sc_L,_pl,sc_O,__,__,__,__,sc_L,sc_O,sc_A,sc_D,__,sc_F,sc_R,sc_O,sc_M,__,sc_D,sc_I,sc_S,sc_K,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 3: "  CTRL+N    NEW DOCUMENT               "
.byte __,__,sc_C,sc_T,sc_R,sc_L,_pl,sc_N,__,__,__,__,sc_N,sc_E,sc_W,__,sc_D,sc_O,sc_C,sc_U,sc_M,sc_E,sc_N,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 4: "  CTRL+CLR  CLEAR CURRENT PAGE         "
.byte __,__,sc_C,sc_T,sc_R,sc_L,_pl,sc_C,sc_L,sc_R,__,__,sc_C,sc_L,sc_E,sc_A,sc_R,__,sc_C,sc_U,sc_R,sc_R,sc_E,sc_N,sc_T,__,sc_P,sc_A,sc_G,sc_E,__,__,__,__,__,__,__,__,__,__
; Line 5: blank
.byte BLK
; Line 6: " # CONFIG SCREEN:                      "
.byte __,$23,__,sc_C,sc_O,sc_N,sc_F,sc_I,sc_G,__,sc_S,sc_C,sc_R,sc_E,sc_E,sc_N,_co,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 7: "  UP/DOWN     ADJUST BASE SPEED        "
.byte BLK
; Line 8: "  UP/DOWN     ADJUST BASE SPEED        "
.byte __,__,sc_U,sc_P,_sl,sc_D,sc_O,sc_W,sc_N,__,__,__,__,__,sc_A,sc_D,sc_J,sc_U,sc_S,sc_T,__,sc_B,sc_A,sc_S,sc_E,__,sc_S,sc_P,sc_E,sc_E,sc_D,__,__,__,__,__,__,__,__,__
; Line 9: "  LEFT/RIGHT  ADJUST CURVE             "
.byte __,__,sc_L,sc_E,sc_F,sc_T,_sl,sc_R,sc_I,sc_G,sc_H,sc_T,__,__,sc_A,sc_D,sc_J,sc_U,sc_S,sc_T,__,sc_C,sc_U,sc_R,sc_V,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 10: "  RETURN      START                    "
.byte __,__,sc_R,sc_E,sc_T,sc_U,sc_R,sc_N,__,__,__,__,__,__,sc_S,sc_T,sc_A,sc_R,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 11: "  F3          OPEN EDITOR              "
.byte __,__,sc_F,_3,__,__,__,__,__,__,__,__,__,__,sc_O,sc_P,sc_E,sc_N,__,sc_E,sc_D,sc_I,sc_T,sc_O,sc_R,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 12: "  F5          START SCROLL             "
.byte __,__,sc_F,_5,__,__,__,__,__,__,__,__,__,__,sc_S,sc_T,sc_A,sc_R,sc_T,__,sc_S,sc_C,sc_R,sc_O,sc_L,sc_L,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 13: blank
.byte BLK
; Line 14: " START A NEW DOCUMENT BY               "
.byte __,sc_S,sc_T,sc_A,sc_R,sc_T,__,sc_A,__,sc_N,sc_E,sc_W,__,sc_D,sc_O,sc_C,sc_U,sc_M,sc_E,sc_N,sc_T,__,sc_B,sc_Y,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 15: " PRESSING CTRL+N FROM THE              "
.byte __,sc_P,sc_R,sc_E,sc_S,sc_S,sc_I,sc_N,sc_G,__,sc_C,sc_T,sc_R,sc_L,_pl,sc_N,__,sc_F,sc_R,sc_O,sc_M,__,sc_T,sc_H,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 16: " EDITOR, WHICH CAN BE                  "
.byte __,sc_E,sc_D,sc_I,sc_T,sc_O,sc_R,_c,__,sc_W,sc_H,sc_I,sc_C,sc_H,__,sc_C,sc_A,sc_N,__,sc_B,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 17: " ACCESSED BY PRESSING F3.              "
.byte __,sc_A,sc_C,sc_C,sc_E,sc_S,sc_S,sc_E,sc_D,__,sc_B,sc_Y,__,sc_P,sc_R,sc_E,sc_S,sc_S,sc_I,sc_N,sc_G,__,sc_F,_3,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 18: " FROM THERE YOU CAN ALSO               "
.byte __,sc_F,sc_R,sc_O,sc_M,__,sc_T,sc_H,sc_E,sc_R,sc_E,__,sc_Y,sc_O,sc_U,__,sc_C,sc_A,sc_N,__,sc_A,sc_L,sc_S,sc_O,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 19: " TYPE # SYMBOLS, WHICH SERVE           "
.byte __,sc_T,sc_Y,sc_P,sc_E,__,$23,__,sc_S,sc_Y,sc_M,sc_B,sc_O,sc_L,sc_S,_c,__,sc_W,sc_H,sc_I,sc_C,sc_H,__,sc_S,sc_E,sc_R,sc_V,sc_E,__,__,__,__,__,__,__,__,__,__,__,__
; Line 20: " AS MARKERS THAT YOU CAN               "
.byte __,sc_A,sc_S,__,sc_M,sc_A,sc_R,sc_K,sc_E,sc_R,sc_S,__,sc_T,sc_H,sc_A,sc_T,__,sc_Y,sc_O,sc_U,__,sc_C,sc_A,sc_N,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 21: " JUMP TO WHILE SCROLLING,              "
.byte __,sc_J,sc_U,sc_M,sc_P,__,sc_T,sc_O,__,sc_W,sc_H,sc_I,sc_L,sc_E,__,sc_S,sc_C,sc_R,sc_O,sc_L,sc_L,sc_I,sc_N,sc_G,_c,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 22: " BY PRESSING THE COMMA AND             "
.byte __,sc_B,sc_Y,__,sc_P,sc_R,sc_E,sc_S,sc_S,sc_I,sc_N,sc_G,__,sc_T,sc_H,sc_E,__,sc_C,sc_O,sc_M,sc_M,sc_A,__,sc_A,sc_N,sc_D,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 23: " PERIOD KEYS.                          "
.byte __,sc_P,sc_E,sc_R,sc_I,sc_O,sc_D,__,sc_K,sc_E,sc_Y,sc_S,_d,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__

; --- Page 3: Back to the Future quote ---
; Line 0: blank
.byte BLK
; Line 1: " TO THOSE ASKING: "ARE YOU             "
.byte __,sc_T,sc_O,__,sc_T,sc_H,sc_O,sc_S,sc_E,__,sc_A,sc_S,sc_K,sc_I,sc_N,sc_G,_co,__,$22,sc_A,sc_R,sc_E,__,sc_Y,sc_O,sc_U,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 2: " TELLING ME YOU BUILT A                "
.byte __,sc_T,sc_E,sc_L,sc_L,sc_I,sc_N,sc_G,__,sc_M,sc_E,__,sc_Y,sc_O,sc_U,__,sc_B,sc_U,sc_I,sc_L,sc_T,__,sc_A,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 3: " TELEPROMPTER... OUT OF A              "
.byte __,sc_T,sc_E,sc_L,sc_E,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,sc_E,sc_R,__,_d,_d,__,sc_O,sc_U,sc_T,__,sc_O,sc_F,__,sc_A,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 4: " COMMODORE 64?" ALL I HAVE             "
.byte __,sc_C,sc_O,sc_M,sc_M,sc_O,sc_D,sc_O,sc_R,sc_E,__,_6,_4,$3F,$22,__,sc_A,sc_L,sc_L,__,sc_I,__,sc_H,sc_A,sc_V,sc_E,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 5: " TO SAY IS: "IF YOU'RE GONNA           "
.byte __,sc_T,sc_O,__,sc_S,sc_A,sc_Y,__,sc_I,sc_S,_co,__,$22,sc_I,sc_F,__,sc_Y,sc_O,sc_U,$27,sc_R,sc_E,__,sc_G,sc_O,sc_N,sc_N,sc_A,__,__,__,__,__,__,__,__,__,__,__,__
; Line 6: " BUILD A TELEPROMPTER FOR              "
.byte __,sc_B,sc_U,sc_I,sc_L,sc_D,__,sc_A,__,sc_T,sc_E,sc_L,sc_E,sc_P,sc_R,sc_O,sc_M,sc_P,sc_T,sc_E,sc_R,__,sc_F,sc_O,sc_R,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 7: " TIME TRAVEL, WHY NOT DO IT            "
.byte __,sc_T,sc_I,sc_M,sc_E,__,sc_T,sc_R,sc_A,sc_V,sc_E,sc_L,_c,__,sc_W,sc_H,sc_Y,__,sc_N,sc_O,sc_T,__,sc_D,sc_O,__,sc_I,sc_T,__,__,__,__,__,__,__,__,__,__,__,__,__
; Line 8: " WITH SOME STYLE?"                     "
.byte __,sc_W,sc_I,sc_T,sc_H,__,sc_S,sc_O,sc_M,sc_E,__,sc_S,sc_T,sc_Y,sc_L,sc_E,$3F,$22,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__,__
; Lines 9-23: blank
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
;  Render engine RODATA
;  tile_char_idx[128] — maps C64 screen codes $00-$7F to tile set index (0-50)
;  Screen codes: @=$00, A-Z=$01-$1A, \=$1C, space=$20, 0-9=$30-$39
;  Punctuation: !=$21 "=$22 #=$23 $=$24 %=$25 '=$27 ,=$2C -=$2D .=$2E /=$2F :=$3A ?=$3F
; =============================================================================
tile_char_idx:
;       $x0 $x1 $x2 $x3 $x4 $x5 $x6 $x7 $x8 $x9 $xA $xB $xC $xD $xE $xF
.byte    48,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15  ; $00-$0F (@,A-O)
.byte    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,  0, 50,  0,  0,  0  ; $10-$1F (P-Z,\)
.byte     0, 39, 45, 44, 46, 47,  0, 43,  0,  0,  0,  0, 37, 41, 38, 49  ; $20-$2F (sp,!,",#,$,%,',-,.,/)
.byte    27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 42,  0,  0,  0,  0, 40  ; $30-$3F (0-9,:=3A,?=3F)
.byte     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0  ; $40-$4F
.byte     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0  ; $50-$5F
.byte     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0  ; $60-$6F
.byte     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0  ; $70-$7F

; =============================================================================
;  tile_sets[51][9] — 9 tile indices (top-l,top-c,top-r,mid-l,mid-c,mid-r,
;                                      bot-l,bot-c,bot-r) per character
;  Tile index vocabulary:
;   0=blank  1=top-left  2=top-ctr  3=top-right
;   4=left-vert  5=right-vert  6=bot-left  7=bot-ctr  8=bot-right
;   9=hmid-left  10=hmid-ctr  11=hmid-right  12=full  13=ctr-vert  14=ctr-dot
; =============================================================================
tile_sets:
; Set 0  (blank)
.byte  0, 0, 0,  0, 0, 0,  0, 0, 0
; Set 1  A: top frame + midbar + open legs
.byte  1,27, 3,  9,28,10,  4, 0, 5
; Set 2  B: top frame + mid-bump-right + bot frame
.byte  1,27, 3,  9,28,36,  6,29, 8
; Set 3  C: top bar open-right + left vert + bot bar open-right
.byte  1,27, 0,  4, 0, 0,  6,29, 0
; Set 4  D: frame with sharp left corners
.byte  1,27, 3,  4, 0, 5, 21,29, 8
; Set 5  E: top bar + mid bar left + bot bar
.byte  1,27,32,  9,28, 0,  6,29,33
; Set 6  F: top bar + mid bar left + left vert
.byte  1,27,32,  9,28, 0,  4, 0, 0
; Set 7  G: C + right stub at mid (rounded)
.byte  1,27, 0,  4, 0,18,  6,29, 8
; Set 8  H: two verts + midbar
.byte  1, 0, 3,  9,28,10,  6, 0, 8
; Set 9  I: centered with T/invT junctions
.byte  0,19, 0,  0,12, 0,  0,20, 0
; Set 10 J: top right + right vert + bot frame
.byte  0,27, 3,  0, 0, 5,  6,29, 8
; Set 11 K: left vert + diagonals right + mid bar
.byte  1, 0,25,  9,28, 0,  6, 0,22
; Set 12 L: left vert + bot bar
.byte 15, 0, 0,  4, 0, 0,  6,29, 0
; Set 13 M: top bar with T junction + center stem + open legs
.byte  1,19, 3,  4,12, 5,  4, 0, 5
; Set 14 N: diagonal from TL to BR with verts
.byte 30, 0,16,  4,22, 5,  4, 0,31
; Set 15 O: frame
.byte  1,27, 3,  4, 0, 5,  6,29, 8
; Set 16 P: top frame + mid-right-close + left vert
.byte  1,27, 3,  9,28,14,  4, 0, 0
; Set 17 Q: frame + bottom-right solid mark
.byte  1,27, 3,  4, 0, 5,  6,29,11
; Set 18 R: sharp top-left + mid-right-narrow + right arm
.byte  1,27, 3,  9,28,36,  4, 0, 5
; Set 19 S: top-left + midbar (rounded corners) + bot-right
.byte  1,27,32, 17,28,18, 34,29, 8
; Set 20 T: top bar with T junction + center stem
.byte 35,19,32,  0,12, 0,  0,12, 0
; Set 21 U: open top + bot frame
.byte 15, 0,16,  4, 0, 5,  6,29, 8
; Set 22 V: verts narrowing to U-shape bot
.byte 15, 0,16,  6, 0, 8,  0,26, 0
; Set 23 W: verts + center stem + bot bar with invT junction
.byte 15, 0,16,  4,12, 5,  6,20, 8
; Set 24 X: mirrored corners + cross center
.byte  3, 0, 1,  0,23, 0,  8, 0, 6
; Set 25 Y: diagonal tops merge via Y-junction + center stem
.byte 22, 0,25,  0,24, 0,  0,12, 0
; Set 26 Z: top bar + diagonal mid + bot bar
.byte  2,27, 3,  0,25, 0,  6,29, 7
; Set 27 0: frame
.byte  1,27, 3,  4, 0, 5,  6,29, 8
; Set 28 1: center col with invT bot bar
.byte  0,19, 0,  0, 4, 0,  0, 6, 0
; Set 29 2: top-right + corner mid-right + bot-left
.byte  1,27, 3,  0,28,14,  6,29, 7
; Set 30 3: right-side only open on left
.byte  0,27, 3,  0,28,10,  0,29, 8
; Set 31 4: verts + rounded mid-left + midbar + right leg
.byte 15, 0,16, 17,28,10,  0, 0, 5
; Set 32 5: top-left + mid + corner mid-right + bot-right
.byte  1,27,32,  9,28, 3,  0,29, 8
; Set 33 6: C + midbar + corner mid-right + bot frame
.byte  1,27,32,  9,28, 3,  6,29, 8
; Set 34 7: top bar + right descent
.byte  0,27, 3,  0, 0, 5,  0, 0, 5
; Set 35 8: frame + midbar (= H with closed sides)
.byte  1,27, 3,  9,28,10,  6,29, 8
; Set 36 9: top frame + mid (rounded left) + bot-right
.byte  1,27, 3, 17,28,10,  0,29, 8
; Set 37 ,: dot at bot-left
.byte  0, 0, 0,  0, 0, 0,  6, 0, 0
; Set 38 .: dot at bot-center
.byte  0, 0, 0,  0, 0, 0,  0,13, 0
; Set 39 !: center vert + bot dot
.byte  0,12, 0,  0,12, 0,  0,13, 0
; Set 40 ?: top-right curve + mid + bot dot
.byte  0,27, 3,  0,28, 0,  0,13, 0
; Set 41 -: center midbar
.byte  0, 0, 0,  0,28, 0,  0, 0, 0
; Set 42 :: two dots
.byte  0,13, 0,  0, 0, 0,  0,13, 0
; Set 43 ': apostrophe at top-center
.byte  0,13, 0,  0, 0, 0,  0, 0, 0
; Set 44 #: two horiz bars crossing two verticals
.byte  9,28,10,  4, 0, 5,  9,28,10
; Set 45 ": double-quote ticks at top-center
.byte  0,38, 0,  0, 0, 0,  0, 0, 0
; Set 46 $: S-shape with vertical stroke through center
.byte  1,19,32, 17,37,18, 34,20, 8
; Set 47 %: dots at TL/BR with forward-slash diagonal
.byte 13, 0,25,  0,25, 0, 25, 0,13
; Set 48 @: frame with inner loop, open bottom-right
.byte  1,27, 3,  4,28,18,  6,29, 0
; Set 49 /: forward-slash diagonal (TR to BL)
.byte  0, 0,25,  0,25, 0, 25, 0, 0
; Set 50 \: backslash diagonal (TL to BR)
.byte 22, 0, 0,  0,22, 0,  0, 0,22

; Precomputed pointers into tile_sets (lo and hi bytes)
tile_off_lo:
.byte <(tile_sets +  0*9), <(tile_sets +  1*9), <(tile_sets +  2*9), <(tile_sets +  3*9)
.byte <(tile_sets +  4*9), <(tile_sets +  5*9), <(tile_sets +  6*9), <(tile_sets +  7*9)
.byte <(tile_sets +  8*9), <(tile_sets +  9*9), <(tile_sets + 10*9), <(tile_sets + 11*9)
.byte <(tile_sets + 12*9), <(tile_sets + 13*9), <(tile_sets + 14*9), <(tile_sets + 15*9)
.byte <(tile_sets + 16*9), <(tile_sets + 17*9), <(tile_sets + 18*9), <(tile_sets + 19*9)
.byte <(tile_sets + 20*9), <(tile_sets + 21*9), <(tile_sets + 22*9), <(tile_sets + 23*9)
.byte <(tile_sets + 24*9), <(tile_sets + 25*9), <(tile_sets + 26*9), <(tile_sets + 27*9)
.byte <(tile_sets + 28*9), <(tile_sets + 29*9), <(tile_sets + 30*9), <(tile_sets + 31*9)
.byte <(tile_sets + 32*9), <(tile_sets + 33*9), <(tile_sets + 34*9), <(tile_sets + 35*9)
.byte <(tile_sets + 36*9), <(tile_sets + 37*9), <(tile_sets + 38*9), <(tile_sets + 39*9)
.byte <(tile_sets + 40*9), <(tile_sets + 41*9), <(tile_sets + 42*9), <(tile_sets + 43*9)
.byte <(tile_sets + 44*9), <(tile_sets + 45*9), <(tile_sets + 46*9), <(tile_sets + 47*9)
.byte <(tile_sets + 48*9), <(tile_sets + 49*9), <(tile_sets + 50*9)

tile_off_hi:
.byte >(tile_sets +  0*9), >(tile_sets +  1*9), >(tile_sets +  2*9), >(tile_sets +  3*9)
.byte >(tile_sets +  4*9), >(tile_sets +  5*9), >(tile_sets +  6*9), >(tile_sets +  7*9)
.byte >(tile_sets +  8*9), >(tile_sets +  9*9), >(tile_sets + 10*9), >(tile_sets + 11*9)
.byte >(tile_sets + 12*9), >(tile_sets + 13*9), >(tile_sets + 14*9), >(tile_sets + 15*9)
.byte >(tile_sets + 16*9), >(tile_sets + 17*9), >(tile_sets + 18*9), >(tile_sets + 19*9)
.byte >(tile_sets + 20*9), >(tile_sets + 21*9), >(tile_sets + 22*9), >(tile_sets + 23*9)
.byte >(tile_sets + 24*9), >(tile_sets + 25*9), >(tile_sets + 26*9), >(tile_sets + 27*9)
.byte >(tile_sets + 28*9), >(tile_sets + 29*9), >(tile_sets + 30*9), >(tile_sets + 31*9)
.byte >(tile_sets + 32*9), >(tile_sets + 33*9), >(tile_sets + 34*9), >(tile_sets + 35*9)
.byte >(tile_sets + 36*9), >(tile_sets + 37*9), >(tile_sets + 38*9), >(tile_sets + 39*9)
.byte >(tile_sets + 40*9), >(tile_sets + 41*9), >(tile_sets + 42*9), >(tile_sets + 43*9)
.byte >(tile_sets + 44*9), >(tile_sets + 45*9), >(tile_sets + 46*9), >(tile_sets + 47*9)
.byte >(tile_sets + 48*9), >(tile_sets + 49*9), >(tile_sets + 50*9)

; =============================================================================
;  Sprite data at $3700 — dedicated SPRITES segment
;  Right-pointing (►) for left side, Left-pointing (◄) for right side
;  Each sprite: 24×21 pixels = 63 bytes + 1 pad = 64 bytes
;  Sprite 0 pointer = $3F00/64 = $FC
;  Sprite 1 pointer = $3F40/64 = $FD
; =============================================================================
.segment "SPRITES"

spr_right_tri:
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
        .byte $00,$00,$01           ; Row 0:                         *
        .byte $00,$00,$03           ; Row 1:                        **
        .byte $00,$00,$07           ; Row 2:                       ***
        .byte $00,$00,$0F           ; Row 3:                      ****
        .byte $00,$00,$1F           ; Row 4:                     *****
        .byte $00,$00,$3F           ; Row 5:                    ******
        .byte $00,$00,$7F           ; Row 6:                   *******
        .byte $00,$00,$FF           ; Row 7:                  ********
        .byte $00,$01,$FF           ; Row 8:                 *********
        .byte $00,$03,$FF           ; Row 9:                **********
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
;  Custom charset at $2800 — 256 tiles × 8 bytes = 2048 bytes
;  Tile index vocabulary (used by tile_sets above):
;   0  blank      1  top-left    2  top-ctr    3  top-right
;   4  left-vert  5  right-vert  6  bot-left   7  bot-ctr    8  bot-right
;   9  hmid-left  10 hmid-ctr   11 hmid-right  12 full-blk
;  13  ctr-vert   14 ctr-dot    15 mid-close-r
;  16  top-l-vert 17 top-r-vert 18 hmid-l-close 19 hmid-r-close
;  20  top-ctr-T  21 bot-l-sq
;  22  diag-tlbr  23 cross      24 y-junction  25 diag-trbl
;  26  u-shape
;  27  top-ctr-w  28 hmid-ctr-w 29 bot-ctr-w
;  30  n-tl-diag  31 n-br-diag
;  32  top-r-bar  33 bot-r-bar  34 bot-l-bar  35 top-l-bar
;  36  hmid-r-notch  37 cvert+midbar  38 dquote-ticks
;
;  Padding: 3px top / 2px bottom, 1px margin left/right of each glyph.
;  Horizontal values: $70=01110000 (left 3px, 1px L-margin)
;                     $0E=00001110 (right 3px, 1px R-margin)
;                     $7E=01111110 (full bar, 1px L+R margins)
;                     $38=00111000 (centre 3px)
;  Vertical: top-tiles have rows 0-2 blank (3px top gap);
;            bot-tiles have rows 6-7 blank (2px bottom gap).
;            Mid-tiles carry strokes through all 8 rows (no inner gap).
; =============================================================================
.segment "CHARSET"

; T0 — blank
.byte $00,$00,$00,$00,$00,$00,$00,$00

; T1 — top-left corner  (3px top pad, 3-step outer curve, 1-row transition, 2-row left vert)
.byte $00,$00,$00,$07,$3F,$78,$70,$70

; T2 — top-center  (3px top pad, 2-row top bar, blank below)
.byte $00,$00,$00,$7E,$7E,$00,$00,$00

; T3 — top-right corner  (3px top pad, 3-step outer curve, 1-row transition, 2-row right vert)
.byte $00,$00,$00,$E0,$FC,$1E,$0E,$0E

; T4 — left vertical  (left 3px with 1px L-margin, full 8 rows)
.byte $70,$70,$70,$70,$70,$70,$70,$70

; T5 — right vertical  (right 3px with 1px R-margin, full 8 rows)
.byte $0E,$0E,$0E,$0E,$0E,$0E,$0E,$0E

; T6 — bot-left corner  (2-row left vert, 1-row transition, 3-step outer curve, 2px bot pad)
.byte $70,$70,$78,$3F,$0F,$03,$00,$00

; T7 — bot-center  (4-row blank, 2-row bot bar, 2px bot pad)
.byte $00,$00,$00,$00,$7E,$7E,$00,$00

; T8 — bot-right corner  (2-row right vert, 1-row transition, 3-step outer curve, 2px bot pad)
.byte $0E,$0E,$1E,$FC,$F0,$C0,$00,$00

; T9 — hmid-left  (left vert, 2px transition, midbar rows 2-4, 2px transition, left vert)
.byte $70,$7C,$7F,$7F,$7F,$7C,$70,$70

; T10 — hmid-right  (right vert, 2px transition, midbar rows 2-4, 2px transition, right vert)
.byte $0E,$3E,$FE,$FE,$FE,$3E,$0E,$0E

; T11 — full block  (full bar with 1px L+R margins, all 8 rows)
.byte $7E,$7E,$7E,$7E,$7E,$7E,$7E,$7E

; T12 — center vertical  (centre 3px $38=00111000, full 8 rows)
.byte $38,$38,$38,$38,$38,$38,$38,$38

; T13 — center dot  (centre 3px, rows 3-5, 2px bot pad)
.byte $00,$00,$00,$38,$38,$38,$00,$00

; T14 — mid-close-right (right vert, 2px transition, bar rows 2-3, 3-step outer curve, blank)
;        used in mid-row right of P where nothing continues below
.byte $0E,$3E,$FE,$FE,$F0,$00,$00,$00

; T15 — top-left-vert (3px top gap, then left vert — matches top-gap of T1/T2/T3)
.byte $00,$00,$00,$70,$70,$70,$70,$70

; T16 — top-right-vert (3px top gap, then right vert — matches top-gap of T1/T2/T3)
.byte $00,$00,$00,$0E,$0E,$0E,$0E,$0E

; T17 — hmid-left-close-bot (left vert, 2px transition, bar rows 2-3, 3-step outer curve, blank)
;        used in mid-row left where vert ends and bar extends right (S, 9)
.byte $70,$7C,$7F,$7F,$0F,$00,$00,$00

; T18 — hmid-right-close-top (blank rows 0-1, 3-step outer curve, bar rows 3-4, 2px transition, right vert)
;        used in mid-row right where bar meets vert below (S, G)
.byte $00,$00,$F0,$FE,$FE,$3E,$0E,$0E

; T19 — top-center-T (3px top pad, 2-row full bar, transition, 2-row center vert)
;        T-shape junction: full-width bar with stem descending (I top, T top)
.byte $00,$00,$00,$C7,$FF,$7C,$38,$38

; T20 — bot-center-invT (2-row center vert, transition, 2-row full bar, 2px bot pad)
;        inverted-T junction: stem ascending into full-width bar (I bot, 1 bot)
.byte $38,$38,$38,$7C,$FF,$C7,$00,$00

; T21 — bot-left corner  (3-row left vert, curve into bar, 2px bot pad)
;        used in D
.byte $70,$70,$70,$78,$3F,$07,$00,$00

; T22 — diagonal TL-BR (4px stroke from top-left to bottom-right, full width)
;        used in N, Z, X, Y corners
.byte $00,$E0,$F0,$78,$3C,$1E,$0F,$07

; T23 — cross (4px diagonals TL-BR + TR-BL crossing at center)
;        used in mid-center of X
.byte $00,$E7,$FF,$7E,$3C,$7E,$FF,$E7

; T24 — Y-junction (4px arms converging into 3px center vert)
;        used in mid-center of Y
.byte $E7,$FF,$7E,$3C,$38,$38,$38,$38

; T25 — diagonal TR-BL (4px stroke from top-right to bottom-left, full width)
;        Y-axis mirror of T22, used in X, Y corners
.byte $00,$07,$0F,$1E,$3C,$78,$F0,$E0

; T26 — U-shape (3px left+right verts to tile edges, rounded bottom bar, 2px bot pad)
;        used in bot-center of V
.byte $E7,$E7,$E7,$E7,$7E,$3C,$00,$00

; T27 — top-center-wide (3px top pad, 2-row full-width bar, blank below)
;        full-width version of T2 for center column
.byte $00,$00,$00,$FF,$FF,$00,$00,$00

; T28 — hmid-center-wide (blank rows 0-1, 3-row full-width bar, blank rows 5-7)
;        full-width version for center column
.byte $00,$00,$FF,$FF,$FF,$00,$00,$00

; T29 — bot-center-wide (4-row blank, 2-row full-width bar, 2px bot pad)
;        full-width version of T7 for center column
.byte $00,$00,$00,$00,$FF,$FF,$00,$00

; T30 — N top-left (45° diagonal TL-BR + left vert, pointy top-left)
;        diagonal merges with left vert connecting to tile below
.byte $00,$60,$70,$78,$7C,$7E,$7F,$77

; T31 — N bot-right (45° diagonal TL-BR + right vert, pointy bot-right)
;        diagonal merges with right vert connecting to tile above
.byte $EE,$FE,$7E,$3E,$1E,$0E,$06,$00

; T32 — top-right-bar (3px top pad, 2-row bar extended left, blank below)
;        like T2 but bar extends to col 0
.byte $00,$00,$00,$FE,$FE,$00,$00,$00

; T33 — bot-right-bar (4-row blank, 2-row bar extended left, 2px bot pad)
;        like T7 but bar extends to col 0
.byte $00,$00,$00,$00,$FE,$FE,$00,$00

; T34 — bot-left-bar (4-row blank, 2-row bar extended right, 2px bot pad)
;        like T7 but bar extends to col 7
.byte $00,$00,$00,$00,$7F,$7F,$00,$00

; T35 — top-left-bar (3px top pad, 2-row bar extended right, 3-row blank)
;        like T2 but bar extends to col 7
.byte $00,$00,$00,$7F,$7F,$00,$00,$00

; T36 — hmid-right-notch (like T10 but col 6 removed from bar rows 2-4 only)
;        used in mid-row right of R, B — notch aligns with mid-center bar
.byte $0E,$3E,$FC,$FC,$FC,$3E,$0E,$0E

; T37 — center-vert-plus-midbar (center 3px vert all rows + full-width bar rows 2-4)
;        used in center of $ (S-shape with vertical stroke)
.byte $38,$38,$FF,$FF,$FF,$38,$38,$38

; T38 — double-quote ticks (two 2px-wide strokes side by side, rows 3-5)
;        used in top-center of "
.byte $00,$00,$00,$66,$66,$66,$00,$00

; T39-T223 zero-filled (T224-T255 reserved for sprite data at $3F00)
.res (224-39)*8, 0

; =============================================================================
;  BSS segment — runtime-only document buffer (not stored in PRG file)
; =============================================================================
.segment "BSS"

save_header:    .res 1              ; total_pages (saved to disk as first byte)
doc_buffer:     .res 9600 + 1000    ; 10 pages × 960 bytes + 1000 scroll trail

; ---------------------------------------------------------------------------
;  Render engine state — large-character scroll mode
; ---------------------------------------------------------------------------
rnd_top_linebuf: .res 120           ; 3 tile rows × 40 cols for current top rendered line
rnd_bot_linebuf: .res 120           ; 3 tile rows × 40 cols for current bottom rendered line
rnd_top_colbuf:  .res 40            ; base color per column for top rendered line
rnd_bot_colbuf:  .res 40            ; base color per column for bottom rendered line
rnd_hist_lo:    .res 240            ; top history ring: lo byte of doc ptr at line starts
rnd_hist_hi:    .res 240            ; top history ring: hi byte
rnd_hist_head:  .res 1              ; top ring write index (0-239)
rnd_hist_count: .res 1              ; top ring valid entries (0-240, fits in one byte)
rnd_hist_bot_lo:  .res 240          ; bot history ring: lo byte
rnd_hist_bot_hi:  .res 240          ; bot history ring: hi byte
rnd_hist_bot_head:.res 1            ; bot ring write index (0-239)
rnd_hist_bot_count:.res 1           ; bot ring valid entries

; Word-wrap temporaries (used only inside render_compute_line)
rnd_wk_char:    .res 13             ; screen codes of chars on current rendered line (with color bits 6-7)
rnd_wk_x:       .res 13             ; x tile-positions of each char (after centering)
rnd_wk_color:   .res 13             ; C64 base color per rendered char
rnd_wk_len:     .res 1              ; number of chars on line (0-13)
rnd_wk_wid:     .res 1              ; running rendered width (tile columns)
rnd_wk_wlen:    .res 1              ; current word length (chars)
rnd_wk_wwidth:  .res 1              ; current word width (tile columns = wlen*3)
rnd_wk_sep:     .res 1              ; separator to add before this word (0 or 1)
rnd_wk_first:   .res 1              ; 0=first word on line not yet placed, 1=already placed one

; Pointers to start of rendered line AFTER current top/bot linebuf
rnd_top_next_lo: .res 1            ; doc ptr lo of rendered line after current top linebuf
rnd_top_next_hi: .res 1
rnd_bot_next_lo: .res 1            ; doc ptr lo of rendered line after current bot linebuf
rnd_bot_next_hi: .res 1
rnd_top_skip:    .res 1            ; blank-tile rollover skip count (counts down from 4 at init)
rows_from_start_lo: .res 1        ; 16-bit coarse-row distance from starting position (lo)
rows_from_start_hi: .res 1        ;   (hi) — clamped at 0, prevents reverse past doc start
max_rows_fwd_lo: .res 1           ; 16-bit forward scroll limit (lo) = 3 × rendered line count
max_rows_fwd_hi: .res 1           ;   (hi)
fwd_limit_reached: .res 1        ; nonzero → at forward scroll limit (used by IRQ to avoid flicker)

; Scroll position memory
saved_rows_lo:     .res 1        ; saved rows_from_start_lo for F5 resume
saved_rows_hi:     .res 1        ; saved rows_from_start_hi for F5 resume
saved_fine_scroll: .res 1        ; saved fine_scroll for F5 resume
scroll_has_saved:  .res 1        ; nonzero = saved position is valid
scroll_entry_mode: .res 1        ; 0=fresh, 1=F5 resume, 2=F3 jump-to-cursor
target_rows_lo:    .res 1        ; target rows_from_start for positioning
target_rows_hi:    .res 1
reverse_floor_lo:  .res 1        ; minimum rows_from_start (reverse scroll limit)
reverse_floor_hi:  .res 1
init_top_lo:       .res 1        ; doc ptr of first rendered line at scroll entry
init_top_hi:       .res 1
