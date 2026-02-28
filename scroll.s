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
do_coarse:      .res 1              ; non-zero = coarse scroll pending
csel_pass:      .res 1              ; 0 = first IRQ (re-arm), 1 = second (do work)

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

        ; --- Horizontal scroll: 38-col mode, no scroll ---
        lda #$00                    ; CSEL=0, XSCROLL=0
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

; Main idle loop — 6-cycle iteration (LDA zp=3, BEQ=3 taken)
; This bounds IRQ jitter to 0-2 cycles from a 3-cycle instruction.
@forever:
        lda do_coarse               ; 3 cy
        beq @forever                ; 3 cy (taken)
        lda #0
        sta do_coarse
        jsr scroll_screen_up
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

        ; Colour RAM: rows 0-7 = white (bytes 0-319)
        ;            rows 8-14 = light gray (bytes 320-599)
        ;            rows 15-24 = white (bytes 600-999)
        ; Split across pages since X is 8-bit only.

        ; Bytes 0-255: rows 0-6 (all white)
        lda #WHITE
        ldx #0
@cr0:   sta COLRAM, x
        inx
        bne @cr0

        ; Bytes 256-319: rest of row7 (still white), 0-63 past page 1
        lda #WHITE
        ldx #0
@cr1a:  sta COLRAM+256, x
        inx
        cpx #64
        bne @cr1a

        ; Bytes 320-511: rows 8-12 completely within page 1+2 overlap
        ;   (320-511 = page 1 offsets 64-255 = bytes 320..511 → light gray)
        lda #LIGHT_GRAY
        ldx #64
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
        beq @state3                 ; most time-critical — check first
        cmp #1
        beq @state1
        cmp #2
        beq @state2

        ; --- State 0: zone start (raster 119) ---
        lda #DARK_GRAY
        sta VIC_BG
        sta VIC_BORDER              ; border matches bg — appears transparent
        lda #RASTER_ZONE_OFF

        ; Next: CSEL first pass at raster 137
        lda #RASTER_CSEL_1ST
        sta VIC_RASTER
        lda #3
        sta irq_state
        lda #0
        sta csel_pass
        jmp $EA31

@state1:
        ; --- State 1: zone end (raster 175) ---
        lda #0
        sta VIC_BG
        sta VIC_BORDER              ; border back to black
        lda #RASTER_SCROLL
        sta VIC_RASTER
        lda #2
        sta irq_state
        jmp $EA31

@state2:
        ; --- State 2: scroll update (raster 250) ---
        ; Reset next IRQ to zone start, return FAST — no heavy work here.
        lda #RASTER_ZONE_ON
        sta VIC_RASTER
        lda #0
        sta irq_state

        ; Decrement fine scroll and update $D011 immediately
        dec fine_scroll
        lda fine_scroll
        bpl @update

        ; Coarse scroll needed — just set the flag, main loop handles it
        lda #7
        sta fine_scroll
        lda #7
        ora #%00010000
        sta VIC_CTRL1
        lda #1
        sta do_coarse
        jmp $EA31

@update:
        lda fine_scroll
        ora #%00010000
        sta VIC_CTRL1
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

        ; --- Pass 1 (raster 137): re-arm for raster 138, exit fast ---
        lda #1
        sta csel_pass
        lda #RASTER_CSEL_2ND
        sta VIC_RASTER
        ; Stay in state 3
        jmp $EA31

@csel_pass2:
        ; --- Pass 2 (raster 138): stable entry, ≤2-cycle jitter ---
        ; Reset pass for next frame
        lda #0
        sta csel_pass

        ; Cycle accounting from raster 138 trigger to here:
        ;   CPU IRQ ack + KERNAL push/dispatch = 36 cycles (fixed)
        ;   our handler: sta $D019(4) + lda irq_state(3) + cmp #3(2) +
        ;     beq(3) + lda csel_pass(3) + bne(3) = 18 cycles
        ;   TOTAL: 36 + 18 = 54 cycles ± 0-2 jitter
        ;
        ; We're at cycle ~54 of raster 138.
        ; Target: start LDA for first dodge at cycle 48 of raster 139.
        ;   STA write at cycle 48+2+3 = 53. ✓ (within dodge window)
        ; Gap: (63 - 54) + 48 = 57 cycles from here to LDA start.
        ; But we need LDA #val (2 cy) before the STA, so we account for
        ; the LDA in the gap:  57 - 2 = 55 cycles of pure waste before LDA.
        ; But wait — we also need to include the LDA+STA in the sequence.
        ; Let me recount:
        ;   From cycle 54 of raster 138:
        ;     Remaining in raster 138: 63 - 54 = 9 cycles
        ;     Full raster 139: 63 cycles
        ;     Target: write at cycle 54 of raster 139
        ;     Total cycles to write: 9 + 54 = 63 cycles
        ;     Minus the LDA(2)+STA(4)=6 that produce the write: 63-6 = 57 waste
        ;   But the STA 4th cycle (write) is at the 6th cycle from LDA start.
        ;   Hmm, STA abs write is at cycle 4 of STA = cycle 2+4=6 from LDA.
        ;   Actually: LDA takes 2 cycles (cycles 0-1), STA starts at cycle 2,
        ;   STA writes on its 4th cycle = cycle 5 from LDA start.
        ;   So from LDA start to write = 5 cycles.
        ;   Target write at 63: LDA starts at 63-5 = 58.
        ;   Waste: 58 cycles of NOPs.
        ;   58/2 = 29 NOPs.

        ; -- 29 NOPs = 58 cycles --
        .repeat 29
        nop
        .endrepeat

        ; First dodge: LDA + STA writes CSEL=0 at ~cycle 54 of raster 139.
        ; This prevents the right border FF from being set → line 140 has
        ; no left border.
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
