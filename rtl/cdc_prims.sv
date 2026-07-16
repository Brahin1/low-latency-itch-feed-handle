// -----------------------------------------------------------------------------
// cdc_prims.sv — the three clock-domain-crossing primitives used in this design.
//
//   sync_2ff   : level / Gray-coded bus (at most one bit changes per source clock)
//   pulse_sync : single-cycle event, via toggle + XOR edge detect
//   reset_sync : asynchronous assert, synchronous deassert
//
// Every first-stage flop carries ASYNC_REG so Vivado (a) packs both stages into
// the same slice to maximise MTBF and (b) classifies the crossing as "Safe" in
// report_cdc.
// -----------------------------------------------------------------------------

module sync_2ff #(
  parameter int W = 1
) (
  input  logic         clk,
  input  logic         rst,
  input  logic [W-1:0] d,
  output logic [W-1:0] q
);
  (* ASYNC_REG = "TRUE" *) logic [W-1:0] meta;
  (* ASYNC_REG = "TRUE" *) logic [W-1:0] sync;

  always_ff @(posedge clk) begin
    if (rst) begin
      meta <= '0;
      sync <= '0;
    end else begin
      meta <= d;
      sync <= meta;
    end
  end

  assign q = sync;
endmodule


// Toggle synchronizer. Source events must be spaced >= 3 destination clocks
// apart; in this design the only user is the FIFO-overflow event, which fires
// at most once per Ethernet frame (>= 84 byte-times apart).
module pulse_sync (
  input  logic src_clk,
  input  logic src_rst,
  input  logic src_pulse,
  input  logic dst_clk,
  input  logic dst_rst,
  output logic dst_pulse
);
  logic tog;
  always_ff @(posedge src_clk) begin
    if (src_rst)        tog <= 1'b0;
    else if (src_pulse) tog <= ~tog;
  end

  (* ASYNC_REG = "TRUE" *) logic s1;
  (* ASYNC_REG = "TRUE" *) logic s2;
  logic s3;
  always_ff @(posedge dst_clk) begin
    if (dst_rst) begin
      s1 <= 1'b0; s2 <= 1'b0; s3 <= 1'b0;
    end else begin
      s1 <= tog;  s2 <= s1;   s3 <= s2;
    end
  end

  assign dst_pulse = s2 ^ s3;
endmodule


module reset_sync (
  input  logic clk,
  input  logic arst,   // active-high, from any domain
  output logic rst     // active-high, deasserts synchronously to clk
);
  (* ASYNC_REG = "TRUE" *) logic [1:0] r;
  always_ff @(posedge clk or posedge arst) begin
    if (arst) r <= 2'b11;
    else      r <= {r[0], 1'b0};
  end
  assign rst = r[1];
endmodule
