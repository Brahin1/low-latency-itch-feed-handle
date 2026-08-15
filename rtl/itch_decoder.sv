// -----------------------------------------------------------------------------
// itch_decoder.sv — Nasdaq TotalView-ITCH 5.0 message decoder (core_clk).
//
// Datapath
//   1. Capture: each message byte is written into a 48-byte array at its
//      offset (a 48-way write decoder, no shifting).
//   2. Early filter: the Stock Locate (bytes 1-2) is known at byte 2, so the
//      watchlist compare is resolved and registered ~20-40 cycles before the
//      message ends. It is off the end-of-message path entirely.
//   3. Decode: one cycle after the last byte, every field is a fixed slice of
//      the array; a per-type mux selects which slice feeds each output.
//   4. Output register: record valid 2 cycles after the last message byte.
//
// Watchlist learning
//   ITCH order messages (E, X, D, U...) carry no symbol, only the 16-bit Stock
//   Locate. The locate for each symbol is announced once per day in the Stock
//   Directory ('R') message. When an 'R' arrives whose symbol matches a
//   configured watch slot, the slot learns that locate. After that every
//   message is filtered by a 4 x 16-bit locate compare.
//
// Supported record types: A F E C X D U P (order and trade flow).
// Also consumed: R (learning), S (system event). Anything else is counted and
// skipped using the MoldUDP64 length, so unknown types never desynchronise.
// -----------------------------------------------------------------------------
module itch_decoder (
  input  logic         clk,
  input  logic         rst,
  input  logic         cfg_pass_all,
  input  logic         cfg_relearn,        // pulse: forget learned locates
  input  logic [3:0]   cfg_watch_en,
  input  logic [255:0] cfg_watch_sym,      // slot i = [64*i +: 64], 8 ASCII bytes, space padded
  // message stream (from moldudp64_rx)
  input  logic         m_valid,
  input  logic [7:0]   m_data,
  input  logic         m_first,
  input  logic         m_last,
  input  logic [63:0]  m_seq,
  input  logic         f_done,
  input  logic         f_ok,
  input  logic         f_acc,
  // learned table (for register readback)
  output logic [3:0]   learned_v,
  output logic [63:0]  learned_loc,        // slot i = [16*i +: 16]
  // decoded record
  output logic         r_valid,
  output logic [7:0]   r_type,
  output logic [15:0]  r_locate,
  output logic [47:0]  r_ts,
  output logic [63:0]  r_ref,
  output logic [63:0]  r_new_ref,
  output logic [7:0]   r_side,
  output logic [31:0]  r_shares,
  output logic [31:0]  r_price,
  output logic [63:0]  r_stock,
  output logic [63:0]  r_match,
  output logic [63:0]  r_seq,
  output logic [1:0]   r_sym_idx,
  // frame commit marker (after the frame's last record)
  output logic         r_fend,
  output logic         r_fend_ok,
  // statistics pulses
  output logic         st_msg,
  output logic         st_len_err,
  output logic         st_rec
);
  localparam logic [7:0] T_A = 8'h41, T_F = 8'h46, T_E = 8'h45, T_C = 8'h43,
                         T_X = 8'h58, T_D = 8'h44, T_U = 8'h55, T_P = 8'h50,
                         T_R = 8'h52, T_S = 8'h53;

  // ---------------- 1. capture ----------------
  logic [7:0] mb [0:47];
  logic [5:0] off, woff;
  assign woff = m_first ? 6'd0 : off;

  always_ff @(posedge clk) begin
    if (rst) begin
      off <= '0;
    end else if (m_valid) begin
      off <= (woff == 6'd63) ? 6'd63 : woff + 6'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (m_valid && woff < 6'd48) mb[woff] <= m_data;
  end

  // ---------------- 2. early locate filter ----------------
  logic [15:0] loc_now;
  logic [3:0]  hit;
  logic        loc_hit;
  logic [1:0]  loc_idx;
  assign loc_now = {mb[1], m_data};

  always_comb begin
    for (int i = 0; i < 4; i = i + 1)
      hit[i] = learned_v[i] & cfg_watch_en[i] & (learned_loc[16*i +: 16] == loc_now);
  end

  always_ff @(posedge clk) begin
    if (m_valid && woff == 6'd2) begin
      loc_hit <= |hit;
      loc_idx <= hit[0] ? 2'd0 : hit[1] ? 2'd1 : hit[2] ? 2'd2 : 2'd3;
    end
  end

  // ---------------- 3. decode ----------------
  logic       done_q;
  logic [5:0] len_q;
  logic [63:0] seq_q;
  always_ff @(posedge clk) begin
    if (rst) done_q <= 1'b0;
    else     done_q <= m_valid & m_last;
    len_q <= woff + 6'd1;
    seq_q <= m_seq;
  end

  // Fixed field slices (big-endian, offsets from the ITCH 5.0 spec).
  wire [15:0] f_loc   = {mb[1], mb[2]};
  wire [47:0] f_ts    = {mb[5], mb[6], mb[7], mb[8], mb[9], mb[10]};
  wire [63:0] f_q11   = {mb[11], mb[12], mb[13], mb[14], mb[15], mb[16], mb[17], mb[18]};
  wire [7:0]  f_b19   =  mb[19];
  wire [31:0] f_u19   = {mb[19], mb[20], mb[21], mb[22]};
  wire [63:0] f_q19   = {mb[19], mb[20], mb[21], mb[22], mb[23], mb[24], mb[25], mb[26]};
  wire [31:0] f_u20   = {mb[20], mb[21], mb[22], mb[23]};
  wire [63:0] f_q23   = {mb[23], mb[24], mb[25], mb[26], mb[27], mb[28], mb[29], mb[30]};
  wire [63:0] f_q24   = {mb[24], mb[25], mb[26], mb[27], mb[28], mb[29], mb[30], mb[31]};
  wire [31:0] f_u27   = {mb[27], mb[28], mb[29], mb[30]};
  wire [31:0] f_u31   = {mb[31], mb[32], mb[33], mb[34]};
  wire [31:0] f_u32   = {mb[32], mb[33], mb[34], mb[35]};
  wire [63:0] f_q36   = {mb[36], mb[37], mb[38], mb[39], mb[40], mb[41], mb[42], mb[43]};

  logic        known, is_rec;
  logic [5:0]  exp_len;
  logic [63:0] d_ref, d_new, d_stock, d_match;
  logic [31:0] d_shares, d_price;
  logic [7:0]  d_side;

  always_comb begin
    known = 1'b1; is_rec = 1'b0; exp_len = 6'd0;
    d_ref = '0; d_new = '0; d_stock = '0; d_match = '0;
    d_shares = '0; d_price = '0; d_side = '0;
    case (mb[0])
      T_A, T_F: begin   // Add Order (36) / Add Order with MPID (40)
        exp_len = (mb[0] == T_A) ? 6'd36 : 6'd40; is_rec = 1'b1;
        d_ref = f_q11; d_side = f_b19; d_shares = f_u20; d_stock = f_q24; d_price = f_u32;
      end
      T_E: begin        // Order Executed (31)
        exp_len = 6'd31; is_rec = 1'b1;
        d_ref = f_q11; d_shares = f_u19; d_match = f_q23;
      end
      T_C: begin        // Order Executed With Price (36)
        exp_len = 6'd36; is_rec = 1'b1;
        d_ref = f_q11; d_shares = f_u19; d_match = f_q23; d_price = f_u32;
      end
      T_X: begin        // Order Cancel (23)
        exp_len = 6'd23; is_rec = 1'b1;
        d_ref = f_q11; d_shares = f_u19;
      end
      T_D: begin        // Order Delete (19)
        exp_len = 6'd19; is_rec = 1'b1;
        d_ref = f_q11;
      end
      T_U: begin        // Order Replace (35)
        exp_len = 6'd35; is_rec = 1'b1;
        d_ref = f_q11; d_new = f_q19; d_shares = f_u27; d_price = f_u31;
      end
      T_P: begin        // Trade, non-cross (44)
        exp_len = 6'd44; is_rec = 1'b1;
        d_ref = f_q11; d_side = f_b19; d_shares = f_u20; d_stock = f_q24;
        d_price = f_u32; d_match = f_q36;
      end
      T_R: exp_len = 6'd39;   // Stock Directory
      T_S: exp_len = 6'd12;   // System Event
      default: known = 1'b0;
    endcase
  end

  // ---------------- 4. output + learning ----------------
  logic fend_pend, fend_pend_ok;

  always_ff @(posedge clk) begin
    r_valid    <= 1'b0;
    r_fend     <= 1'b0;
    st_msg     <= 1'b0;
    st_len_err <= 1'b0;
    st_rec     <= 1'b0;

    if (rst || cfg_relearn) begin
      learned_v <= '0;
    end

    if (rst) begin
      fend_pend <= 1'b0;
    end else begin
      if (done_q) begin
        st_msg <= 1'b1;
        if (known && len_q != exp_len) begin
          st_len_err <= 1'b1;
        end else begin
          if (mb[0] == T_R) begin
            for (int i = 0; i < 4; i = i + 1) begin
              if (cfg_watch_en[i] && f_q11 == cfg_watch_sym[64*i +: 64]) begin
                learned_v[i]            <= 1'b1;
                learned_loc[16*i +: 16] <= f_loc;
              end
            end
          end
          if (is_rec && (cfg_pass_all || loc_hit)) begin
            r_valid   <= 1'b1;
            st_rec    <= 1'b1;
            r_type    <= mb[0];
            r_locate  <= f_loc;
            r_ts      <= f_ts;
            r_ref     <= d_ref;
            r_new_ref <= d_new;
            r_side    <= d_side;
            r_shares  <= d_shares;
            r_price   <= d_price;
            r_stock   <= d_stock;
            r_match   <= d_match;
            r_seq     <= seq_q;
            r_sym_idx <= cfg_pass_all && !loc_hit ? 2'd0 : loc_idx;
          end
        end
      end

      // Commit marker for frames that produced payload. Normally the last
      // record is long gone by the time the FCS verdict arrives; if the two
      // ever meet in one cycle, the marker waits one cycle so it stays last.
      if (f_done && f_acc) begin
        if (done_q) begin
          fend_pend    <= 1'b1;
          fend_pend_ok <= f_ok;
        end else begin
          r_fend    <= 1'b1;
          r_fend_ok <= f_ok;
        end
      end else if (fend_pend) begin
        fend_pend <= 1'b0;
        r_fend    <= 1'b1;
        r_fend_ok <= fend_pend_ok;
      end
    end
  end
endmodule
