// -----------------------------------------------------------------------------
// udp_rx.sv — Ethernet II / IPv4 / UDP header parser and filter (core_clk).
//
// Byte-serial FSM, one byte per cycle, no stalls. Each state owns a section of
// the header and a byte counter that restarts on entry:
//
//   S_ETH   14 B  dst MAC, src MAC, EtherType (must be 0x0800)
//   S_IP    20 B  version 4, IHL >= 5, protocol 17 (UDP)
//   S_IPOPT       skip (IHL-5)*4 bytes of IP options, if any
//   S_UDP    8 B  dst port must match cfg_udp_port; capture UDP length
//   S_PAY         forward (UDP length - 8) bytes of payload
//   S_DRAIN       swallow the rest of the frame (padding, FCS, or rejects)
//
// The IPv4 header checksum and UDP checksum are not verified: the Ethernet FCS
// already covers the whole frame, and the frame-level verdict (f_ok) arrives
// after the FCS is checked.
//
// Cut-through: payload is forwarded before the FCS is known. f_done/f_ok is
// the late verdict that downstream uses to commit or roll back.
// -----------------------------------------------------------------------------
module udp_rx (
  input  logic        clk,
  input  logic        rst,
  input  logic        cfg_enable,
  input  logic [15:0] cfg_udp_port,
  // frame byte stream (from rx_cdc)
  input  logic        s_valid,
  input  logic [7:0]  s_data,
  input  logic        s_last,
  input  logic        s_err,
  // UDP payload stream
  output logic        p_valid,
  output logic [7:0]  p_data,
  output logic        p_first,
  output logic        p_last,
  // late frame verdict
  output logic        f_done,
  output logic        f_ok,
  output logic        f_acc,        // frame reached the payload stage
  // statistics pulses
  output logic        st_frame,
  output logic        st_fcs_err,
  output logic        st_filtered
);
  typedef enum logic [2:0] {S_ETH, S_IP, S_IPOPT, S_UDP, S_PAY, S_DRAIN} state_t;
  state_t      st;
  logic [10:0] cnt;
  logic [7:0]  hi;
  logic [3:0]  ihl;
  logic [5:0]  opt_len;
  logic [15:0] dport, ulen;
  logic [10:0] plen;
  logic        acc;

  always_ff @(posedge clk) begin
    p_valid     <= 1'b0;
    p_first     <= 1'b0;
    p_last      <= 1'b0;
    f_done      <= 1'b0;
    st_frame    <= 1'b0;
    st_fcs_err  <= 1'b0;
    st_filtered <= 1'b0;

    if (rst) begin
      st  <= S_ETH;
      cnt <= '0;
      acc <= 1'b0;
      f_ok <= 1'b0;
      f_acc <= 1'b0;
    end else if (s_valid) begin
      cnt <= cnt + 11'd1;

      case (st)
        S_ETH: begin
          if (cnt == 11'd12) hi <= s_data;
          if (cnt == 11'd13) begin
            cnt <= '0;
            st  <= ({hi, s_data} == 16'h0800 && cfg_enable) ? S_IP : S_DRAIN;
          end
        end

        S_IP: begin
          if (cnt == 11'd0) begin
            ihl <= s_data[3:0];
            if (s_data[7:4] != 4'd4 || s_data[3:0] < 4'd5) st <= S_DRAIN;
          end
          if (cnt == 11'd9 && s_data != 8'd17) st <= S_DRAIN;
          if (cnt == 11'd19) begin
            cnt     <= '0;
            opt_len <= {ihl - 4'd5, 2'b00};
            st      <= (ihl == 4'd5) ? S_UDP : S_IPOPT;
          end
        end

        S_IPOPT: begin
          if (cnt == {5'd0, opt_len} - 11'd1) begin
            cnt <= '0;
            st  <= S_UDP;
          end
        end

        S_UDP: begin
          case (cnt)
            11'd2: hi    <= s_data;
            11'd3: dport <= {hi, s_data};
            11'd4: hi    <= s_data;
            11'd5: ulen  <= {hi, s_data};
            11'd7: begin
              cnt  <= '0;
              plen <= ulen[10:0] - 11'd8;
              if (dport == cfg_udp_port && ulen > 16'd8 && ulen < 16'd1481) begin
                st  <= S_PAY;
                acc <= 1'b1;
              end else begin
                st  <= S_DRAIN;
              end
            end
            default: ;
          endcase
        end

        S_PAY: begin
          p_valid <= 1'b1;
          p_data  <= s_data;
          p_first <= (cnt == 11'd0);
          if (cnt == plen - 11'd1) begin
            p_last <= 1'b1;
            st     <= S_DRAIN;
          end
        end

        S_DRAIN: ;

        default: st <= S_DRAIN;
      endcase

      // End of frame overrides everything: report the verdict and re-arm.
      if (s_last) begin
        st          <= S_ETH;
        cnt         <= '0;
        acc         <= 1'b0;
        f_done      <= 1'b1;
        f_ok        <= ~s_err;
        f_acc       <= acc;
        st_frame    <= 1'b1;
        st_fcs_err  <= s_err;
        st_filtered <= ~s_err & ~acc;
      end
    end
  end
endmodule
