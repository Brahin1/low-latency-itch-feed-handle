// -----------------------------------------------------------------------------
// moldudp64_rx.sv — MoldUDP64 de-framer with sequence tracking (core_clk).
//
// Packet:   Session(10) | Sequence(8, BE) | MessageCount(2, BE) | blocks...
// Block:    MessageLength(2, BE) | Message(MessageLength)
// Count 0x0000 = heartbeat, 0xFFFF = end of session (no messages follow).
//
// Sequence handling (the sequence number belongs to the first message in the
// packet; message i carries seq+i):
//   * first packet after reset          -> adopt its sequence, no gap
//   * packet seq  > expected            -> gap: count it, jump forward
//   * packet seq  < expected            -> leading messages are duplicates
//                                          (e.g. the other feed of an A/B pair):
//                                          consume them silently, count them
// Duplicate detection is done once per packet: dup_left = expected - seq, then
// a 17-bit down-counter per message, instead of a 64-bit compare per message.
//
// Speculation: expected-sequence state advances as messages stream through
// (cut-through), but is only *committed* on a good frame verdict. A frame that
// fails its FCS rolls the state back to the last committed value.
// -----------------------------------------------------------------------------
module moldudp64_rx (
  input  logic        clk,
  input  logic        rst,
  // payload stream (from udp_rx)
  input  logic        p_valid,
  input  logic [7:0]  p_data,
  input  logic        p_first,
  input  logic        p_last,
  input  logic        f_done,
  input  logic        f_ok,
  input  logic        f_acc,
  // message byte stream
  output logic        m_valid,
  output logic [7:0]  m_data,
  output logic        m_first,
  output logic        m_last,
  output logic [63:0] m_seq,
  // verdict, delayed one cycle to stay ordered behind the messages
  output logic        o_done,
  output logic        o_ok,
  output logic        o_acc,
  // status / statistics
  output logic [63:0] exp_seq_o,
  output logic        st_pkt,
  output logic        st_hb,
  output logic        st_gap,
  output logic        st_dup
);
  typedef enum logic [2:0] {S_HDR, S_LEN0, S_LEN1, S_MSG, S_DRAIN} state_t;
  state_t      st;
  logic [4:0]  hcnt;
  logic [4:0]  h;              // effective header index this cycle
  logic [63:0] pkt_seq, cur_seq;
  logic [7:0]  cnt_hi, len_hi;
  logic [15:0] msg_left, mlen, mcnt;
  logic [63:0] exp_seq, exp_seq_c;
  logic        seq_ok, seq_ok_c;
  logic        seq_gt;
  logic [63:0] diff;
  logic [16:0] dup_left;
  logic        cur_dup;

  assign h = p_first ? 5'd0 : hcnt;

  always_ff @(posedge clk) begin
    m_valid <= 1'b0;
    m_first <= 1'b0;
    m_last  <= 1'b0;
    st_pkt  <= 1'b0;
    st_hb   <= 1'b0;
    st_gap  <= 1'b0;
    st_dup  <= 1'b0;
    o_done  <= f_done;
    o_ok    <= f_ok;
    o_acc   <= f_acc;

    if (rst) begin
      st        <= S_HDR;
      hcnt      <= '0;
      seq_ok    <= 1'b0;
      seq_ok_c  <= 1'b0;
      exp_seq   <= '0;
      exp_seq_c <= '0;
      o_done    <= 1'b0;
    end else begin
      if (p_valid) begin
        case (p_first ? S_HDR : st)
          S_HDR: begin
            hcnt <= h + 5'd1;
            if (h >= 5'd10 && h <= 5'd17) pkt_seq <= {pkt_seq[55:0], p_data};
            if (h == 5'd18) begin
              // pkt_seq completed on the previous edge: resolve the 64-bit
              // compare/subtract one cycle early so it is off the h==19 path.
              cnt_hi <= p_data;
              seq_gt <= (pkt_seq > exp_seq);
              diff   <= exp_seq - pkt_seq;
            end
            if (h == 5'd19) begin
              msg_left <= {cnt_hi, p_data};
              cur_seq  <= pkt_seq;
              if ({cnt_hi, p_data} == 16'h0000 || {cnt_hi, p_data} == 16'hFFFF) begin
                st    <= S_DRAIN;
                st_hb <= 1'b1;
              end else begin
                st     <= S_LEN0;
                st_pkt <= 1'b1;
                if (!seq_ok) begin
                  seq_ok   <= 1'b1;
                  exp_seq  <= pkt_seq;
                  dup_left <= '0;
                end else if (seq_gt) begin
                  st_gap   <= 1'b1;
                  exp_seq  <= pkt_seq;
                  dup_left <= '0;
                end else begin
                  dup_left <= (diff[63:16] != 48'd0) ? 17'h1FFFF : {1'b0, diff[15:0]};
                end
              end
            end
          end

          S_LEN0: begin
            len_hi <= p_data;
            st     <= S_LEN1;
          end

          S_LEN1: begin
            mlen    <= {len_hi, p_data};
            mcnt    <= '0;
            cur_dup <= (dup_left != 17'd0);
            st      <= ({len_hi, p_data} == 16'd0) ? S_DRAIN : S_MSG;
          end

          S_MSG: begin
            if (!cur_dup) begin
              m_valid <= 1'b1;
              m_data  <= p_data;
              m_first <= (mcnt == 16'd0);
              m_last  <= (mcnt == mlen - 16'd1);
              m_seq   <= cur_seq;
            end
            mcnt <= mcnt + 16'd1;
            if (mcnt == mlen - 16'd1) begin
              if (cur_dup) begin
                st_dup <= 1'b1;
                if (dup_left != 17'h1FFFF) dup_left <= dup_left - 17'd1;
              end else begin
                exp_seq <= cur_seq + 64'd1;
              end
              cur_seq  <= cur_seq + 64'd1;
              msg_left <= msg_left - 16'd1;
              st       <= (msg_left == 16'd1) ? S_DRAIN : S_LEN0;
            end
          end

          default: ;   // S_DRAIN
        endcase

        // Payload ended early (malformed / truncated): stop parsing this packet.
        if (p_last && !(st == S_MSG && mcnt == mlen - 16'd1)) st <= S_DRAIN;
      end

      // Late verdict: commit or roll back the speculative sequence state.
      if (f_done) begin
        st <= S_HDR;
        if (f_ok) begin
          exp_seq_c <= exp_seq;
          seq_ok_c  <= seq_ok;
        end else begin
          exp_seq   <= exp_seq_c;
          seq_ok    <= seq_ok_c;
        end
      end
    end
  end

  assign exp_seq_o = exp_seq_c;
endmodule
