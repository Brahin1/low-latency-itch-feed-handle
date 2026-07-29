// -----------------------------------------------------------------------------
// rx_cdc.sv — moves the byte stream from rx_clk (PHY-recovered 125 MHz) into
// core_clk (local 200 MHz). This is the only asynchronous data crossing in
// the design.
//
// FIFO word = {last, err, data[7:0]}.
//
// A feed handler must never back-pressure the wire, so on overflow it drops and
// accounts rather than stalling:
//   * the first byte that finds the FIFO full marks the frame as "dropping";
//   * the rest of that frame is discarded;
//   * a terminator word {last=1, err=1} is queued as soon as there is room, so
//     the parser always sees a frame boundary and flags the frame bad.
// With core_clk faster than rx_clk this path should never trigger; the counter
// exists to prove it didn't.
// -----------------------------------------------------------------------------
module rx_cdc #(
  parameter int AW = 4
) (
  // rx_clk domain
  input  logic       rx_clk,
  input  logic       rx_rst,
  input  logic       m_valid,
  input  logic [7:0] m_data,
  input  logic       m_last,
  input  logic       m_err,
  // core_clk domain
  input  logic       clk,
  input  logic       rst,
  output logic       s_valid,
  output logic [7:0] s_data,
  output logic       s_last,
  output logic       s_err,
  output logic       st_ovf,       // one pulse per frame that lost bytes
  output logic [AW:0] level        // FIFO occupancy (read side view)
);
  logic       wr_en, full, empty;
  logic [9:0] wdata, rdata;
  logic       dropping, term_pend, ovf_evt;

  // ---------------- write side (rx_clk) ----------------
  always_comb begin
    wr_en = 1'b0;
    wdata = {m_last, m_err, m_data};
    if (term_pend && !full) begin
      wr_en = 1'b1;
      wdata = {1'b1, 1'b1, 8'h00};           // abort terminator
    end else if (m_valid && !dropping && !term_pend && !full) begin
      wr_en = 1'b1;
    end
  end

  always_ff @(posedge rx_clk) begin
    ovf_evt <= 1'b0;
    if (rx_rst) begin
      dropping  <= 1'b0;
      term_pend <= 1'b0;
    end else begin
      if (term_pend && !full) term_pend <= 1'b0;
      if (m_valid && (dropping || term_pend || full)) begin
        // This byte is lost.
        if (!dropping) ovf_evt <= 1'b1;
        if (m_last) begin
          dropping  <= 1'b0;
          term_pend <= 1'b1;
        end else begin
          dropping  <= 1'b1;
        end
      end
    end
  end

  async_fifo #(.W(10), .AW(AW)) u_fifo (
    .wclk(rx_clk), .wrst(rx_rst), .wr_en(wr_en), .wdata(wdata), .full(full),
    .rclk(clk),    .rrst(rst),    .rd_en(!empty), .rdata(rdata), .empty(empty),
    .rlevel(level));

  pulse_sync u_ovf_sync (
    .src_clk(rx_clk), .src_rst(rx_rst), .src_pulse(ovf_evt),
    .dst_clk(clk),    .dst_rst(rst),    .dst_pulse(st_ovf));

  // ---------------- read side (core_clk) ----------------
  // Always drain: the parser consumes one byte per cycle and never stalls.
  always_ff @(posedge clk) begin
    if (rst) s_valid <= 1'b0;
    else     s_valid <= !empty;
    {s_last, s_err, s_data} <= rdata;
  end
endmodule
