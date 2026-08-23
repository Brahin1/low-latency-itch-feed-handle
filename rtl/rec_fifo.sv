// -----------------------------------------------------------------------------
// rec_fifo.sv — single-clock record queue between the decoder and the ARM.
//
// Storage is written/read in always_ff with a registered read so Vivado infers
// block RAM (512 x 512 bits = 8 x RAMB36). A one-entry output register gives
// first-word-fall-through behaviour: `head` is valid whenever `head_valid`,
// so AXI-Lite reads of the head record have no side effects. `pop` advances.
// -----------------------------------------------------------------------------
module rec_fifo #(
  parameter int W  = 512,
  parameter int AW = 9
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          wr_en,
  input  logic [W-1:0]  wdata,
  output logic          full,
  input  logic          pop,
  output logic [W-1:0]  head,
  output logic          head_valid,
  output logic [AW+1:0] count
);
  localparam int D = 1 << AW;

  logic [W-1:0] mem [0:D-1];
  logic [AW:0]  wptr, rptr;
  logic         mem_empty, load;

  assign mem_empty = (wptr == rptr);
  assign full      = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
  assign load      = !mem_empty && (!head_valid || pop);

  always_ff @(posedge clk) begin
    if (wr_en && !full) mem[wptr[AW-1:0]] <= wdata;
    if (load)           head <= mem[rptr[AW-1:0]];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      wptr       <= '0;
      rptr       <= '0;
      head_valid <= 1'b0;
    end else begin
      if (wr_en && !full) wptr <= wptr + 1'b1;
      if (load) begin
        rptr       <= rptr + 1'b1;
        head_valid <= 1'b1;
      end else if (pop) begin
        head_valid <= 1'b0;
      end
    end
  end

  assign count = {1'b0, wptr - rptr} + {{(AW+1){1'b0}}, head_valid};
endmodule
