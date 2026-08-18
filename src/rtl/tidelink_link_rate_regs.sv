//-----------------------------------------------------------------------------
// SoCLabs TideLink Link-Rate Control Registers
//
// APB register bank for the D2D link-rate knob. It lives in TideLink's fourth
// top-level APB quadrant (apb_paddr[14:13] == 2'b11), which was decoded by
// nothing before this block existed and lands at SoC 0x2E03_6000 on the
// ethernet chiplet. Its one job is to supply tidelink_link_clk_div.ratio_i
// from software, through a STICKY SOURCE MUX in the parent, so that the
// existing tidelink_top port link_clk_div_ratio_i remains authoritative until
// software writes CTRL for the very first time.
//
// Register map -- byte offsets within the bank:
//
//   0x000 LINK_RATE_ID    RO  32'h4C43_4401  ("LCD" + version 01)
//   0x004 LINK_RATE_CTRL  RW  [2:0]   ratio_req  0=/1 1=/2 2=/4 3=/8 4=/16
//                             [31:3]  RAZ/WI
//                             Writes are ACCEPTED ONLY WHILE !role_locked_i,
//                             and only at a word-aligned address (paddr[1:0]
//                             == 2'b00) in byte lane 0 -- see property 7.
//   0x008 LINK_RATE_STAT  RO  [2:0]   ratio_eff      divider ratio_o, resynced
//                             [3]     code_match     eff == req (once src=1)
//                                                    NOT "the clock has handed
//                                                    over" -- see property 8.
//                             [4]     role_locked    live write-window state
//                             [7:5]   ratio_req      what this bank drives
//                             [8]     src_sticky     SW has written >= once
//                             [9]     write_refused  sticky, see below
//                             [12:10] max_ratio      the EFFECTIVE MAX_RATIO
//                                                    (MAX_RATIO_Q, i.e. after
//                                                    the divider-ceiling clamp)
//                             [13]    ratio_clamped  sticky, see below
//                             [31:14] zero
//
// WHY THIS EXISTS
//   The D2D bit rate IS whatever clock arrives at user_hsclk -- there is no
//   PLL in WlinkGPIOPHY, and the forwarded pad clock is the far receiver's eye
//   reference. tidelink_link_clk_div can lower it, but on the shipping die its
//   ratio_i is tied to a constant at the wrapper, so the capability exists and
//   is unreachable. This bank makes it reachable from the SWD/PS side with the
//   CPUs halted and the link down, which is exactly the state a marginal-eye
//   bring-up is in when it needs to slow the link down.
//
// DESIGN PROPERTIES -- these are the reasons for the shape of this RTL.
//
//   1. WRITES ARE LEGAL ONLY BEFORE ROLE-LOCK, AND THE RTL ENFORCES IT, WITH
//      NO ONE-CYCLE HOLE AT THE LOCK EDGE.
//      A rate change re-times the transmit side and invalidates the phase
//      solution the link is running on, so it is only safe while the PHY is
//      still held in POR, i.e. before role_locked_o rises. That is a
//      SEQUENCING rule, and a sequencing rule that only exists in a bring-up
//      script is one script edit away from being violated on silicon.
//
//      A purely combinational accept gate is NOT sufficient. role_locked_i is
//      an hclk flop; ctrl_accept_ph and the request flop both sample it just
//      BEFORE an hclk edge, so a CTRL write whose APB access phase ends on the
//      very edge at which role_lock latches sees role_locked_i == 0 and
//      commits -- changing the rate at the exact cycle the link goes live.
//      (Reproduced: the write landed, ratio_o == 3, src_sticky == 1,
//      write_refused == 0, with role_locked_i == 1 immediately afterwards.)
//
//      So the commit is TWO-PHASE. The access phase produces a pending write
//      (ctrl_pend_r) only if role_locked_i was low then; the pending write is
//      committed one hclk later, and ONLY if role_locked_i is still low. The
//      accept condition is therefore an AND of the pre-edge and post-edge
//      values of role_locked_i, which no single edge can straddle. A write
//      killed in the second phase is recorded in write_refused exactly like
//      one refused in the first. Cost: the CTRL readback reflects the write
//      one hclk later than the access phase -- which is still before the
//      earliest APB transfer that could read it back (setup + access = 2
//      hclk), so no host-visible sequence changes.
//
//      There is deliberately NO warm/live change path -- see property 2.
//
//   2. A REFUSED WRITE IS ACKED, NOT ERRORED, AND IT IS RECORDED.
//      Silently ignoring a write that software believes landed is how a
//      bring-up run ends up chasing a "PHY problem" that is really a rate that
//      never changed. write_refused is sticky for the whole POR scope so the
//      evidence survives to whenever the host next reads STAT -- the host
//      typically polls STAT long after the offending write. It is not W1C:
//      there is no legitimate reason to erase it inside a run, and a clear
//      path is one more thing a script can get wrong.
//
//   3. THE ACK IS UNCONDITIONAL, ONE CYCLE, EVERYWHERE IN THE 8 KB.
//      pready is a hard 1'b1 and pslverr a hard 1'b0 for every access in the
//      quadrant -- hits, misses, reads of undefined offsets, writes to RO
//      words, and writes rejected by the alignment/strobe gate of property 7.
//      tidelink_top's bounded-stall watchdog (ext_txn / EXT_STALL_LIMIT)
//      covers quadrant 01 ONLY; quadrant 11 has no PS-hang protection, and the
//      Zynq M_AXI_GP that the KR260 host drives this through has no bus
//      timeout. A quadrant that can stall the PS for ever is strictly worse
//      than a quadrant that is absent.
//
//   4. THE BANK DOES NOT ALIAS ACROSS ITS APERTURE.
//      in_bank requires the whole address above bit 3 to be zero, so the three
//      words answer at exactly 0x6000/0x6004/0x6008 and nowhere else. This
//      breaks with the config quadrant's precedent, where a paddr[8:5] decode
//      aliases a 512-byte map 16x across 8 KB. That is tolerable for an
//      observation register. It is not tolerable for a clock knob, which
//      should not be reachable by 2000-odd wrong addresses.
//
//   5. MAX_RATIO IS A SIGNOFF HONESTY MECHANISM, NOT A CONVENIENCE, AND IT IS
//      CLAMPED TO WHAT THE DIVIDER CAN ACTUALLY DO.
//      Only the ratios that STA has actually built constraint modes for are
//      certified. MAX_RATIO clamps the accepted request to that set, BEFORE
//      the register, so a readback compare can never chase a target the
//      divider will never reach.
//
//      tidelink_link_clk_div's own ceiling is 3'd4 (/16): its ratio_q clamps
//      anything above 4 down to 4, so ratio_o can never read 5, 6 or 7. A
//      MAX_RATIO of 5, 6 or 7 therefore used to let CTRL hold a code the
//      divider structurally cannot report, and STAT.code_match -- eff == req
//      -- became UNREACHABLE FOR EVER. (Reproduced at MAX_RATIO=3'd5: after
//      writing CTRL=5, 500 consecutive STAT polls returned req=5, eff=4,
//      code_match=0; a host "poll until settled" loop does not terminate.)
//      MAX_RATIO_Q below re-clamps the parameter to the divider's ceiling, and
//      STAT[12:10] reports MAX_RATIO_Q rather than the raw parameter, so the
//      host is told the truth about what it may ask for.
//
//      MAX_RATIO = 3'd0 removes the request flops entirely (see the generate
//      below) and pins the driven ratio to /1 structurally, leaving the bank
//      present and readable -- that is the escape hatch if a constraint freeze
//      arrives before the divided modes are signed off.
//
//   6. THE ratio_eff READBACK IS A CDC AND IS TREATED AS ONE.
//      ratio_eff_i is tidelink_link_clk_div.ratio_o, which lives in the
//      divider's clk_in (user_ref_clk) domain, not hclk. Two flops for
//      metastability, THEN a third holding flop, and the seen-twice filter
//      compares the two POST-synchroniser stages (eff_sync_r vs eff_hold_r)
//      only. The earlier shape compared eff_meta_r -- the stage-1 flop, the
//      one that is allowed to be metastable -- against eff_sync_r, and used
//      that comparison as eff_r's clock enable. That is precisely what 2FF
//      discipline forbids: a metastable stage-1 output fanning into
//      combinational logic can drive an enable to an indeterminate level and
//      corrupt the stage it gates. Stage 1 now fans out to exactly one place,
//      stage 2, and to nothing else.
//
//      The filter itself is retained: without it a multi-bit code caught
//      mid-transition can be read out as a third, never-programmed ratio --
//      which in a status register is worse than useless, because a bring-up
//      script branches on it.
//
//      KNOWN, NOT FIXED HERE: tidelink_link_clk_div has the identical
//      stage-1-in-the-comparator shape on its ratio_i capture
//      (tidelink_link_clk_div.sv:98, `if (ratio_sync_r == ratio_meta_r)`).
//      That file is outside the scope of this change and its unit bench is
//      signed off against the current text; it needs the same three-stage
//      restructure and should be raised separately.
//
//   7. A CTRL WRITE MUST PROVE IT TARGETS THE RATIO BYTE.
//      The ratio lives in byte lane 0 of the word at offset 0x004. Two
//      independent things say whether an access targets that byte, because
//      two bridge styles exist in this tree: the byte address (paddr[1:0]) and
//      the write strobe (pstrb[0]). Both are now required.
//
//      Without the alignment term, offsets 0x005/0x006/0x007 decoded as CTRL
//      writes, because the word select is paddr[3:2] and paddr[1:0] was sunk
//      as "the byte offset inside an aligned word". (Reproduced: a lane-1 byte
//      write to 0x005 set src_sticky, handing the divider's ratio_i over to
//      this bank; a lane-3 byte write to 0x007 carrying 32'h0000_0004 drove
//      ratio_o to 3'd4, i.e. it CHANGED THE LINK RATE to /16 from an access
//      that targeted neither the CTRL word's byte 0 nor lane 0.)
//
//      USE_PSTRB now DEFAULTS ON. The previous default was off, on the
//      argument that a tb_top which declares pstrb and never drives it would
//      make the knob intermittently inert. That argument points the wrong way
//      for a clock knob: with the strobe ignored, an unintended byte write
//      CHANGES THE LINK RATE (demonstrated above) -- a live-link rate change,
//      the one thing this block exists to prevent. With the strobe honoured,
//      an undriven pstrb makes the knob INERT: the rate does not change, the
//      link keeps running at whatever it was, and the failure is a write that
//      visibly did not land rather than a link that silently retimed. Inert is
//      the recoverable direction; retimed is not. Both in-tree benches that
//      can reach this bank drive pstrb = 4'hF (cocotb/tidelink_top_pair
//      tb_top.sv wires m_apb_pstrb/s_apb_pstrb and the APBMaster in
//      test_tidelink_pair_doorbell.py sets 0xF), so the default costs them
//      nothing. Set USE_PSTRB = 1'b0 only for an integration whose bridge
//      genuinely has no strobe, and understand that alignment is then the only
//      remaining guard.
//
//   8. STAT[3] IS code_match, NOT "settled", AND THE NAME IS THE FIX.
//      The bit means exactly one thing: the resynchronised divider ratio code
//      equals the code this bank is requesting, and this bank owns the ratio.
//      It does NOT mean the divided clock has handed over and is running.
//
//      tidelink_link_clk_div.ratio_o is a combinational clamp of the divider's
//      captured ratio_r. It changes as soon as the ratio CODE is adopted --
//      which is before, and independent of, the bypass<->divided leg interlock
//      (byp_en_r / div_en_r) that actually moves clk_out. That interlock costs
//      up to two negedges of each leg, i.e. up to ~2 divided periods, and
//      clk_out is LOW for that whole window. Measured on a /1 -> /16 change
//      with a 5 ns clk_in: the flag rose 30 ns after the last link_hsclk edge,
//      inside a 187.5 ns edge-to-edge gap (nominal /16 period is 80 ns) -- the
//      PHY reference was stopped, and a bit called "settled" was reading 1.
//
//      This bank CANNOT observe the handover: it is given ratio_eff_i and
//      nothing else, and clk_out does not reach it. Making the bit mean what
//      "settled" says would require tidelink_link_clk_div to export a
//      leg-enable / clock-active status (e.g. byp_en_r | div_en_r,
//      resynchronised here), which is a change to a file this change does not
//      own. Until that exists, the honest thing is a name that states the
//      weaker fact, so a host reading STAT is not told something the RTL never
//      checked. A host that must know the clock is live should poll a
//      link-side liveness indication, not this bit.
//
// RESET SCOPES -- THIS IS A SAFETY PROPERTY, NOT A STYLE CHOICE
//   THE RULE: state that determines the rate the divider is running is reset
//   by poresetn, because the divider is. State that only mirrors the divider's
//   live output is reset by hresetn, because it re-derives itself within three
//   hclk of release.
//
//   tidelink_top instantiates u_link_clk_div with .rst_n(poresetn) -- and
//   deliberately so: the PHY's reset is held longer than the fabric's
//   precisely so the PHY survives a warm reset. This bank's ratio_req_r and
//   src_sticky_r drive that divider's ratio_i through the parent's sticky
//   source mux. Resetting them on hresetn therefore made the pair a RESET
//   DOMAIN CROSSING: an hresetn pulse cleared src_sticky_r, the parent's mux
//   fell back to the link_clk_div_ratio_i strap, and the divider -- still out
//   of reset, still clocking the PHY -- retimed a running link.
//
//   Reproduced, with poresetn held HIGH throughout: after a software request
//   of /4 and role-lock, a 3-hclk hresetn pulse took link_hsclk from a 20 ns
//   period to a 5 ns period (a 4x rate INCREASE on a live link), src_sticky
//   fell to 0, and the knob could not repair it because role_locked_i was by
//   then 1 and every further CTRL write was refused. That is the exact
//   violation of the central rule -- the rate changed while the link was up --
//   and it needed no software error at all.
//
//   WHY THIS SHAPE AND NOT "HOLD ADOPTION ACROSS A WARM RESET". Holding
//   adoption means masking the reset with state, e.g. an async reset net of
//   the form (hresetn | src_sticky_r) or (hresetn | role_locked_i). Both were
//   rejected. The first is a reset driven by a flop inside its own reset
//   scope: at power-up, before hresetn has ever asserted, src_sticky_r is
//   undefined, and if it powers up as 1 the reset is masked FOR EVER and the
//   bank hands the divider a random ratio -- a worse failure than the one
//   being fixed. The second races: role_locked_i is itself an hresetn-scoped
//   flop, so it falls in the same instant hresetn does and the mask is gone
//   exactly when it is needed. Both also produce a reset net driven by
//   ordinary logic, which reset-tree synthesis, DFT and reset-domain-crossing
//   signoff all have to be argued around. Putting the flops in the POR domain
//   needs no argument: the state and the thing it controls are then in ONE
//   reset scope, and the crossing does not exist.
//
//   CONSEQUENCE, DOCUMENTED AND BOUNDED. The ratio_eff resynchroniser stays on
//   hresetn, so for up to three hclk after hresetn release STAT.ratio_eff
//   reads 0 (/1) while the divider is still running divided, and code_match
//   reads 0. It fails in the safe direction -- it under-claims -- and the
//   window closes before the earliest APB read that a just-released fabric can
//   issue. Do not read STAT as authoritative inside it.
//
//   The parent must connect poresetn. tidelink_top has it as a port already
//   (it drives u_link_clk_div with it); the instantiation inside
//   `if (LINK_RATE_REGS_PRESENT)` passes it straight down.
//
// NOTE ON role_locked_i AND CLOCK DOMAINS
//   role_locked_i is NOT synchronised here, on purpose. In tidelink_top the
//   chiplet controller that sources it is instantiated with .apb_clk(hclk) and
//   .app_clk(hclk), so it is already an hclk signal. Adding a 2-flop
//   synchroniser to a same-domain level would open a two-cycle window AFTER
//   role-lock in which a CTRL write is still accepted -- the exact failure the
//   gate exists to prevent. If a future integration ever clocks the controller
//   from something other than hclk, a synchroniser MUST be added here, and it
//   must be one that closes the window early (e.g. gate on raw OR synced),
//   not one that merely delays it. Note that the two-phase commit of property
//   1 makes the gate strictly EARLIER, never later, so it composes with such a
//   synchroniser rather than fighting it.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
`default_nettype none

module tidelink_link_rate_regs #(
    // Width of the paddr slice handed down from the parent. The bank only ever
    // looks at paddr[12:0]; bits 14:13 are the quadrant select and are already
    // implicit in psel, so passing the full 15-bit apb_paddr is safe and so is
    // passing paddr[12:0]. Must be >= 5 (an aperture below 32 B cannot hold
    // the three words).
    parameter APB_ADDR_W = 13,
    parameter SYS_DATA_W = 32,

    // Highest ratio code software may request. 3'd4 = all divider modes
    // (/1 /2 /4 /8 /16) reachable; 3'd1 = /1 and /2 only; 3'd0 = pinned /1.
    //
    // Values above 3'd4 are re-clamped to 3'd4 by MAX_RATIO_Q below, because
    // the divider itself cannot report a code above 4 and an unreachable
    // request target makes STAT.code_match unreachable for ever (property 5).
    //
    // DO NOT raise this past the set the SDC has constraint modes for without
    // saying so out loud. The whole point of the parameter is that the
    // reachable ratio set and the certified ratio set are the same statement.
    parameter [2:0] MAX_RATIO = 3'd4,

    // Honour pstrb on the CTRL write. DEFAULTS ON -- see property 7 for the
    // reasoning, which is that an ignored strobe lets an unintended byte write
    // change the link rate, while an undriven strobe merely makes the knob
    // inert. Turn it off only for a bridge that genuinely has no strobe.
    parameter USE_PSTRB = 1'b1,

    // Bank identity. Exists so host tooling can tell "bank present" from the
    // pre-change "reserved quadrant reads back zero" without probing
    // behaviour -- several PS tools must run against both submodule pins
    // during the migration.
    parameter [31:0] ID_VALUE = 32'h4C43_4401   // "LCD" + version 01
) (
    input  wire                    hclk,

    // Fabric / warm reset. Resets the ratio_eff observation pipeline ONLY.
    // It must NOT reset anything that determines the rate -- see RESET SCOPES.
    input  wire                    hresetn,

    // Power-on reset, the SAME reset tidelink_top gives u_link_clk_div.rst_n.
    // Everything that determines or describes the rate in force is in this
    // scope, so a warm reset cannot retime a running link.
    input  wire                    poresetn,

    // APB3/APB4 subordinate. psel is qualified by the parent with
    // apb_paddr[14:13] == 2'b11, so everything arriving here is ours.
    input  wire                    psel,
    input  wire                    penable,
    input  wire                    pwrite,
    input  wire [APB_ADDR_W-1:0]   paddr,
    input  wire [SYS_DATA_W-1:0]   pwdata,
    input  wire [SYS_DATA_W/8-1:0] pstrb,
    output reg  [SYS_DATA_W-1:0]   prdata,
    output wire                    pready,
    output wire                    pslverr,

    // Write window. High once the Wlink controller has latched its role; from
    // that point a rate change would re-time a running link, so CTRL writes
    // are refused. Same clock domain as hclk -- see the header note.
    input  wire                    role_locked_i,

    // tidelink_link_clk_div.ratio_o -- the ratio actually in force. Crosses
    // from the divider's clk_in domain; resynchronised below.
    input  wire [2:0]              ratio_eff_i,

    // To the parent's 2:1 sticky source mux feeding u_link_clk_div.ratio_i.
    output wire [2:0]              ratio_o,
    // Mux select: 0 => the link_clk_div_ratio_i port stays authoritative,
    // 1 => software has spoken and this bank owns the ratio. Never falls back
    // to 0, because "the port wins again" after a software write is a state no
    // bring-up script could reason about -- and, since this flop is now in the
    // POR scope, a warm reset cannot force that fall-back either.
    output wire                    src_sticky_o
);

    // -------------------------------------------------------------------------
    // Effective MAX_RATIO (property 5)
    //
    // The divider's own ceiling is 3'd4: tidelink_link_clk_div.sv:106 clamps
    // ratio_q to 4, so ratio_o -- and therefore ratio_eff_i here -- can never
    // read 5, 6 or 7. Accepting a request above 4 would park CTRL on a code
    // the status path cannot ever echo.
    // -------------------------------------------------------------------------
    localparam [2:0] MAX_RATIO_Q = (MAX_RATIO > 3'd4) ? 3'd4 : MAX_RATIO;

    // synopsys translate_off
    initial begin
        if (MAX_RATIO > 3'd4)
            $display("%m: NOTE MAX_RATIO=%0d exceeds the tidelink_link_clk_div ceiling; clamped to %0d",
                     MAX_RATIO, MAX_RATIO_Q);
    end
    // synopsys translate_on

    // -------------------------------------------------------------------------
    // Address decode
    //
    // Word select is paddr[3:2]; everything above bit 3 must be zero for the
    // bank to answer (property 4). BANK_MSB saturates at 12 so that handing
    // this module the full 15-bit apb_paddr does not drag the quadrant-select
    // bits into the compare, which would make the bank permanently unhittable.
    // -------------------------------------------------------------------------
    localparam BANK_MSB = ((APB_ADDR_W - 1) > 12) ? 12 : (APB_ADDR_W - 1);

    localparam [1:0] WORD_ID   = 2'd0;   // 0x000
    localparam [1:0] WORD_CTRL = 2'd1;   // 0x004
    localparam [1:0] WORD_STAT = 2'd2;   // 0x008

    wire [1:0] word     = paddr[3:2];
    wire       in_bank  = (paddr[BANK_MSB:4] == '0);

    // APB ACCESS phase. pready is a hard 1'b1 (property 3), so the access
    // phase is exactly one hclk and a write cannot be double-applied; there is
    // no need for the setup-phase-write trick used elsewhere in this tree.
    wire apb_access = psel & penable;
    wire apb_write  = apb_access &  pwrite & in_bank;

    // Property 7: an access only reaches the ratio if BOTH the byte address
    // and the write strobe say it targets byte lane 0 of the CTRL word.
    wire aligned    = (paddr[1:0] == 2'b00);
    wire byte0_en   = (USE_PSTRB == 1'b0) | pstrb[0];

    wire [2:0] pw_ratio = pwdata[2:0];

    // -------------------------------------------------------------------------
    // CTRL write: two-phase commit (property 1)
    //
    // Phase 1 (access edge): a well-formed CTRL write with role_locked_i low
    // becomes a PENDING write. A well-formed CTRL write with role_locked_i
    // high is refused outright and recorded.
    // Phase 2 (next edge): the pending write commits only if role_locked_i is
    // STILL low. If role-lock latched on the phase-1 edge -- the one-cycle
    // hole -- it is high here, the write is killed, and it is recorded as
    // refused exactly as a phase-1 refusal would have been.
    // -------------------------------------------------------------------------
    wire ctrl_write_req = apb_write & (word == WORD_CTRL) & aligned & byte0_en;
    wire ctrl_accept_ph = ctrl_write_req & ~role_locked_i;
    wire ctrl_refuse_ph = ctrl_write_req &  role_locked_i;

    reg  ctrl_pend_r;
    reg  ctrl_pend_clamp_r;

    always @(posedge hclk or negedge poresetn) begin
        if (!poresetn) begin
            ctrl_pend_r       <= 1'b0;
            ctrl_pend_clamp_r <= 1'b0;
        end else begin
            ctrl_pend_r       <= ctrl_accept_ph;
            // Captured unconditionally alongside ctrl_pend_r, from the same
            // edge, and only ever consumed while ctrl_pend_r is set.
            ctrl_pend_clamp_r <= (pw_ratio > MAX_RATIO_Q);
        end
    end

    wire ctrl_commit    = ctrl_pend_r & ~role_locked_i;
    wire ctrl_late_kill = ctrl_pend_r &  role_locked_i;

    // -------------------------------------------------------------------------
    // Requested ratio  --  POR SCOPE (see RESET SCOPES)
    //
    // Clamped to MAX_RATIO_Q on the way IN, not on the way out, so that CTRL
    // reads back the value that is actually being asked for and a host-side
    // "wait until ratio_eff == what I wrote" loop can terminate. The divider
    // clamps >4 to /16 internally as well; that is a second line, not this one.
    // -------------------------------------------------------------------------
    wire [2:0] ratio_req_w;

    generate
        if (MAX_RATIO_Q == 3'd0) begin : g_ratio_pinned
            // Property 5 escape hatch. No flops, no mux input, nothing for a
            // synthesis tool to leave reachable: the bank is present and
            // readable, and the ratio it can ask for is structurally /1.
            //
            // Note the consequence, which is intended: once software writes,
            // src_sticky_o still rises and this constant /1 overrides whatever
            // the link_clk_div_ratio_i port was strapping. /1 is the bypass
            // configuration that mission-mode signoff analysed, so being
            // forced there by a write is the safe direction.
            assign ratio_req_w = 3'd0;
        end else begin : g_ratio_req
            // Declared inside the arm that consumes it: on the pinned build
            // there is no request path at all, and a clamp net left dangling
            // there would be dead logic in every downstream tool's report.
            wire [2:0] ratio_wr =
                (pw_ratio > MAX_RATIO_Q) ? MAX_RATIO_Q : pw_ratio;
            reg [2:0] ratio_pend_r;
            reg [2:0] ratio_req_r;
            always @(posedge hclk or negedge poresetn) begin
                if (!poresetn) begin
                    ratio_pend_r <= 3'd0;
                    ratio_req_r  <= 3'd0;     // /1 bypass out of POR
                end else begin
                    ratio_pend_r <= ratio_wr;
                    if (ctrl_commit)
                        ratio_req_r <= ratio_pend_r;
                end
            end
            assign ratio_req_w = ratio_req_r;
        end
    endgenerate

    assign ratio_o = ratio_req_w;

    // -------------------------------------------------------------------------
    // Source-sticky  --  POR SCOPE
    //
    // Updated on the SAME edge as ratio_req_r, so there is no cycle in which
    // the parent's mux has switched to this bank while the bank is still
    // presenting its reset value. That matters: the divider's ratio capture
    // filter would see a /1 -> target transition either way, but a one-cycle
    // spurious /1 on a link that had been strapped to a divided ratio is a
    // real rate glitch, not a cosmetic one.
    //
    // In the POR scope because it, jointly with ratio_req_r, IS the rate the
    // divider runs at. Clearing it on hresetn is what let a warm reset hand
    // the ratio back to the strap under a live link.
    // -------------------------------------------------------------------------
    reg src_sticky_r;
    always @(posedge hclk or negedge poresetn) begin
        if (!poresetn)
            src_sticky_r <= 1'b0;
        else if (ctrl_commit)
            src_sticky_r <= 1'b1;
    end
    assign src_sticky_o = src_sticky_r;

    // -------------------------------------------------------------------------
    // Sticky status flags  --  POR SCOPE
    //
    // write_refused: a CTRL write arrived after role-lock and was dropped,
    //   whether it was refused in the access phase or killed at the commit
    //   edge by property 1's second check.
    // ratio_clamped: a CTRL write asked for more than MAX_RATIO_Q. Distinguishes
    //   "you are running /4 because you asked for /4" from "you are running /4
    //   because the build will not give you /16", which CTRL readback alone
    //   only tells you if the host remembers what it wrote.
    //
    // Both are in the POR scope because they are evidence ABOUT a rate that
    // itself outlives hresetn: a ratio_clamped that a warm reset erased would
    // leave the host reading a surviving ratio_req with no record that it was
    // not the value it asked for.
    // -------------------------------------------------------------------------
    reg write_refused_r;
    reg ratio_clamped_r;
    always @(posedge hclk or negedge poresetn) begin
        if (!poresetn) begin
            write_refused_r <= 1'b0;
            ratio_clamped_r <= 1'b0;
        end else begin
            if (ctrl_refuse_ph || ctrl_late_kill)
                write_refused_r <= 1'b1;
            if (ctrl_commit && ctrl_pend_clamp_r)
                ratio_clamped_r <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // ratio_eff resynchronisation (property 6)  --  hresetn SCOPE
    //
    // Three stages. eff_meta_r and eff_sync_r are the 2FF synchroniser proper;
    // eff_meta_r's ONLY fan-out is eff_sync_r. eff_hold_r is a plain delay of
    // eff_sync_r, and the seen-twice filter compares eff_sync_r against
    // eff_hold_r -- both post-synchroniser, both settled -- so nothing
    // metastable can reach the enable that gates eff_r.
    //
    // Functionally identical to the previous shape: eff_r still only adopts a
    // value that was presented on two consecutive samples, so a multi-bit code
    // caught mid-transition is never decoded as a third, never-programmed
    // ratio. The cost is one extra hclk of readback latency.
    //
    // In the hresetn scope on purpose: it is a mirror of a live output, not a
    // determinant of it, and it re-derives itself in three hclk after release.
    // -------------------------------------------------------------------------
    reg [2:0] eff_meta_r;
    reg [2:0] eff_sync_r;
    reg [2:0] eff_hold_r;
    reg [2:0] eff_r;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            eff_meta_r <= 3'd0;      // matches the divider's RATIO_RESET (/1)
            eff_sync_r <= 3'd0;
            eff_hold_r <= 3'd0;
            eff_r      <= 3'd0;
        end else begin
            eff_meta_r <= ratio_eff_i;
            eff_sync_r <= eff_meta_r;
            eff_hold_r <= eff_sync_r;
            if (eff_sync_r == eff_hold_r)
                eff_r <= eff_sync_r;
        end
    end

    // STAT[3]. code_match, NOT "settled" -- property 8. It says the divider is
    // reporting the code this bank is asking for, and nothing about whether
    // the divider's bypass<->divided leg interlock has finished moving clk_out.
    //
    // Qualified by src_sticky_r on purpose: before the first committed write
    // this bank is not driving the divider, so comparing its reset request
    // against the port-driven effective ratio would report a meaningless (and
    // often accidentally true) match.
    wire code_match_w = src_sticky_r & (eff_r == ratio_req_w);

    // -------------------------------------------------------------------------
    // Read data
    // -------------------------------------------------------------------------
    wire [31:0] stat_w = {
        18'd0,               // [31:14]
        ratio_clamped_r,     // [13]
        MAX_RATIO_Q,         // [12:10]  effective, post-ceiling-clamp
        write_refused_r,     // [9]
        src_sticky_r,        // [8]
        ratio_req_w,         // [7:5]
        role_locked_i,       // [4]
        code_match_w,        // [3]
        eff_r                // [2:0]
    };

    always @(*) begin
        prdata = {SYS_DATA_W{1'b0}};
        if (in_bank) begin
            case (word)
                WORD_ID:   prdata = ID_VALUE;
                WORD_CTRL: prdata = {29'd0, ratio_req_w};
                WORD_STAT: prdata = stat_w;
                default:   prdata = {SYS_DATA_W{1'b0}};   // 0x00C: RAZ
            endcase
        end
    end

    // Property 3: hard, unconditional, everywhere.
    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    // Deliberately unconsumed inputs. The ratio lives in pwdata[2:0] and byte
    // lane 0; the upper pwdata bits and the upper strobes are RAZ/WI, and
    // pstrb[0] itself is unused when USE_PSTRB is 0. paddr is sunk whole
    // rather than sliced: which of its bits exist depends on APB_ADDR_W, so a
    // fixed slice would be wrong at some legal parameterisation, and sinking
    // bits that ARE used is harmless in a reduction sink.
    wire _unused_ok = &{1'b0, pwdata[SYS_DATA_W-1:3], pstrb, paddr, 1'b0};

endmodule

`default_nettype wire
