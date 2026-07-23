// -----------------------------------------------------------------------------
// rgmii_rx.sv — RGMII (1000 Mb/s) receive: 4-bit DDR -> 8-bit SDR GMII.
//
// RGMII packs a GMII byte into one 125 MHz clock:
//   rising edge : rxd[3:0] = data[3:0],  rx_ctl = RX_DV
//   falling edge: rxd[3:0] = data[7:4],  rx_ctl = RX_DV ^ RX_ER
//
// In synthesis each pin goes through an IDDR in SAME_EDGE_PIPELINED mode, so
// both halves of the byte appear together on the rising edge. The PHY is
// assumed to run in RGMII-ID mode (it delays RXC ~2 ns internally so the clock
// edge is centred in the data eye). If your PHY is strapped for no internal
// delay, add an IDELAYE2 on each data pin instead — see the XDC.
//
// For simulation an equivalent behavioural model is used.
// -----------------------------------------------------------------------------
module rgmii_rx (
  input  logic       rgmii_rxc,
  input  logic [3:0] rgmii_rxd,
  input  logic       rgmii_rx_ctl,
  output logic       rx_clk,
  output logic [7:0] gmii_rxd,
  output logic       gmii_rx_dv,
  output logic       gmii_rx_er
);
  logic [3:0] q_rise, q_fall;
  logic       ctl_rise, ctl_fall;

`ifdef SYNTHESIS
  BUFG u_bufg (.I(rgmii_rxc), .O(rx_clk));

  for (genvar i = 0; i < 4; i = i + 1) begin : g_iddr
    IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .SRTYPE("SYNC")) u_iddr (
      .Q1(q_rise[i]), .Q2(q_fall[i]), .C(rx_clk), .CE(1'b1),
      .D(rgmii_rxd[i]), .R(1'b0), .S(1'b0));
  end

  IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .SRTYPE("SYNC")) u_iddr_ctl (
    .Q1(ctl_rise), .Q2(ctl_fall), .C(rx_clk), .CE(1'b1),
    .D(rgmii_rx_ctl), .R(1'b0), .S(1'b0));
`else
  // Behavioural IDDR, SAME_EDGE_PIPELINED: Q1/Q2 both update on the rising edge
  // and hold the rising/falling samples of the *previous* clock cycle.
  assign rx_clk = rgmii_rxc;
  logic [3:0] r_d, f_d;
  logic       r_c, f_c;
  always_ff @(posedge rx_clk) begin r_d <= rgmii_rxd; r_c <= rgmii_rx_ctl; end
  always_ff @(negedge rx_clk) begin f_d <= rgmii_rxd; f_c <= rgmii_rx_ctl; end
  always_ff @(posedge rx_clk) begin
    q_rise <= r_d; ctl_rise <= r_c;
    q_fall <= f_d; ctl_fall <= f_c;
  end
`endif

  always_ff @(posedge rx_clk) begin
    gmii_rxd   <= {q_fall, q_rise};
    gmii_rx_dv <= ctl_rise;
    gmii_rx_er <= ctl_rise ^ ctl_fall;
  end
endmodule
