// -----------------------------------------------------------------------------
// async_fifo.sv — dual-clock FIFO with Gray-coded pointers (Cummings style).
//
// * Pointers are AW+1 bits: the extra MSB distinguishes full from empty.
// * Only Gray-coded pointers cross domains, so at most one bit is in flight
//   per source clock and a 2-flop synchronizer cannot produce an illegal value.
// * The synchronized pointer is always stale by ~2 cycles, which makes both
//   flags *pessimistic*: full may linger after a read, empty may linger after
//   a write. Pessimistic is safe; optimistic would corrupt data.
// * Storage is small (16 x 10 bits by default) so it infers LUTRAM with an
//   asynchronous read port: show-ahead (first-word-fall-through) behaviour,
//   rdata is valid whenever empty == 0.
// -----------------------------------------------------------------------------
module async_fifo #(
  parameter int W  = 10,
  parameter int AW = 4               // depth = 2**AW
) (
  // write side
  input  logic         wclk,
  input  logic         wrst,
  input  logic         wr_en,
  input  logic [W-1:0] wdata,
  output logic         full,
  // read side
  input  logic         rclk,
  input  logic         rrst,
  input  logic         rd_en,
  output logic [W-1:0] rdata,
  output logic         empty,
  output logic [AW:0]  rlevel          // approximate occupancy seen from read side
);
  localparam int D = 1 << AW;

  logic [W-1:0] mem [0:D-1];

  // ---------------- write domain ----------------
  logic [AW:0] wbin, wgray, wbin_n, wgray_n;
  logic [AW:0] rgray_w;                         // read pointer, synced into wclk

  assign wbin_n  = wbin + {{AW{1'b0}}, (wr_en & ~full)};
  assign wgray_n = (wbin_n >> 1) ^ wbin_n;

  always_ff @(posedge wclk) begin
    if (wrst) begin
      wbin  <= '0;
      wgray <= '0;
      full  <= 1'b0;
    end else begin
      wbin  <= wbin_n;
      wgray <= wgray_n;
      // Full when the next write pointer equals the read pointer with the two
      // MSBs inverted (writer has lapped the reader by exactly D entries).
      full  <= (wgray_n == {~rgray_w[AW:AW-1], rgray_w[AW-2:0]});
    end
  end

  always_ff @(posedge wclk) begin
    if (wr_en && !full) mem[wbin[AW-1:0]] <= wdata;
  end

  sync_2ff #(.W(AW+1)) u_sync_r2w (.clk(wclk), .rst(wrst), .d(rgray), .q(rgray_w));

  // ---------------- read domain ----------------
  logic [AW:0] rbin, rgray, rbin_n, rgray_n;
  logic [AW:0] wgray_r;                         // write pointer, synced into rclk

  assign rbin_n  = rbin + {{AW{1'b0}}, (rd_en & ~empty)};
  assign rgray_n = (rbin_n >> 1) ^ rbin_n;

  always_ff @(posedge rclk) begin
    if (rrst) begin
      rbin  <= '0;
      rgray <= '0;
      empty <= 1'b1;
    end else begin
      rbin  <= rbin_n;
      rgray <= rgray_n;
      empty <= (rgray_n == wgray_r);
    end
  end

  assign rdata = mem[rbin[AW-1:0]];

  sync_2ff #(.W(AW+1)) u_sync_w2r (.clk(rclk), .rst(rrst), .d(wgray), .q(wgray_r));

  // Occupancy for statistics only (Gray -> binary on the synced write pointer).
  function automatic logic [AW:0] gray2bin(input logic [AW:0] g);
    logic [AW:0] b;
    b[AW] = g[AW];
    for (int i = AW - 1; i >= 0; i = i - 1) b[i] = b[i+1] ^ g[i];
    gray2bin = b;
  endfunction

  assign rlevel = gray2bin(wgray_r) - rbin;
endmodule
