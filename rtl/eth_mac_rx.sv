// -----------------------------------------------------------------------------
// eth_mac_rx.sv — minimal receive MAC in the rx_clk (125 MHz) domain.
//
//  * Strips preamble (any number of 0x55) and the SFD (0xD5).
//  * Streams every byte after the SFD, *including the 4 FCS bytes*: the
//    downstream parser knows where the UDP payload ends from the UDP length
//    field, so it never needs the FCS removed. That keeps this block
//    cut-through: the only delay is one byte, needed to know which byte is last.
//  * Computes CRC-32 over all bytes including the FCS. For a good frame the
//    reflected CRC register ends at the residue 0xDEBB20E3.
//  * m_err on the last byte = FCS bad | RX_ER seen | runt (< 64 bytes).
// -----------------------------------------------------------------------------
module eth_mac_rx (
  input  logic       clk,
  input  logic       rst,
  input  logic [7:0] rx_d,
  input  logic       rx_dv,
  input  logic       rx_er,
  output logic       m_valid,
  output logic [7:0] m_data,
  output logic       m_last,
  output logic       m_err
);
  localparam logic [31:0] CRC_RESIDUE = 32'hDEBB20E3;

  // Byte-wise reflected CRC-32 (poly 0x04C11DB7, LSB first). Unrolls to an
  // XOR network: each output bit depends on <= 14 inputs -> 2-3 LUT levels.
  function automatic logic [31:0] crc32_byte(input logic [31:0] c, input logic [7:0] d);
    logic [31:0] r;
    r = c ^ {24'h0, d};
    for (int i = 0; i < 8; i = i + 1) r = r[0] ? ((r >> 1) ^ 32'hEDB88320) : (r >> 1);
    crc32_byte = r;
  endfunction

  typedef enum logic [1:0] {S_IDLE, S_PRE, S_DATA, S_DROP} state_t;
  state_t      st;
  logic [7:0]  hold;
  logic        have_hold;
  logic [31:0] crc;
  logic [10:0] cnt;
  logic        er_seen;

  always_ff @(posedge clk) begin
    m_valid <= 1'b0;
    m_last  <= 1'b0;
    m_err   <= 1'b0;
    if (rst) begin
      st        <= S_IDLE;
      have_hold <= 1'b0;
    end else begin
      case (st)
        S_IDLE: if (rx_dv) begin
          if (rx_d == 8'h55) st <= S_PRE;
          else if (rx_d == 8'hD5) begin
            st <= S_DATA; crc <= '1; cnt <= '0; have_hold <= 1'b0; er_seen <= 1'b0;
          end else st <= S_DROP;
        end

        S_PRE: begin
          if (!rx_dv)              st <= S_IDLE;
          else if (rx_d == 8'hD5) begin
            st <= S_DATA; crc <= '1; cnt <= '0; have_hold <= 1'b0; er_seen <= 1'b0;
          end
          else if (rx_d != 8'h55)  st <= S_DROP;
        end

        S_DATA: begin
          if (rx_dv) begin
            crc       <= crc32_byte(crc, rx_d);
            cnt       <= (cnt == '1) ? cnt : cnt + 11'd1;
            er_seen   <= er_seen | rx_er;
            hold      <= rx_d;
            have_hold <= 1'b1;
            if (have_hold) begin
              m_valid <= 1'b1;
              m_data  <= hold;
            end
          end else begin
            // DV fell: the held byte was the last one of the frame.
            st <= S_IDLE;
            if (have_hold) begin
              m_valid <= 1'b1;
              m_data  <= hold;
              m_last  <= 1'b1;
              m_err   <= er_seen | (crc != CRC_RESIDUE) | (cnt < 11'd64);
            end
          end
        end

        S_DROP: if (!rx_dv) st <= S_IDLE;

        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
