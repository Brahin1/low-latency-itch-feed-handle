// -----------------------------------------------------------------------------
// itch_decoder.sv — Nasdaq TotalView-ITCH 5.0 message decoder (core_clk).
//
// Datapath
//   1. Capture: each message byte is written into a 48-byte array at its
//      offset (a 48-way write decoder, no shifting).
//   2. Decode: one cycle after the last byte, every field is a fixed slice of
//      the array; a per-type mux selects which slice feeds each output.
//   3. Output register: record valid 2 cycles after the last message byte.
//
// Supported record types: A F E C X D (order flow).
// Also consumed: R (stock directory), S (system event). Anything else is
// counted and skipped using the MoldUDP64 length, so unknown types never
// desynchronise.
// -----------------------------------------------------------------------------
module itch_decoder (
  input  logic         clk,
  input  logic         rst,
  // message stream (from moldudp64_rx)
  input  logic         m_valid,
  input  logic [7:0]   m_data,
  input  logic         m_first,
  input  logic         m_last,
  input  logic [63:0]  m_seq,
  input  logic         f_done,
  input  logic         f_ok,
  input  logic         f_acc,
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

  // ---------------- 2. decode ----------------
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
      T_U: exp_len = 6'd35;   // Order Replace (TODO: record)
      T_P: exp_len = 6'd44;   // Trade (TODO: record)
      T_R: exp_len = 6'd39;   // Stock Directory
      T_S: exp_len = 6'd12;   // System Event
      default: known = 1'b0;
    endcase
  end

  // ---------------- 3. output ----------------
  logic fend_pend, fend_pend_ok;

  always_ff @(posedge clk) begin
    r_valid    <= 1'b0;
    r_fend     <= 1'b0;
    st_msg     <= 1'b0;
    st_len_err <= 1'b0;
    st_rec     <= 1'b0;

    if (rst) begin
      fend_pend <= 1'b0;
    end else begin
      if (done_q) begin
        st_msg <= 1'b1;
        if (known && len_q != exp_len) begin
          st_len_err <= 1'b1;
        end else begin
          if (is_rec) begin
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
