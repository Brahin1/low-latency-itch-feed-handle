// -----------------------------------------------------------------------------
// axil_regs.sv — AXI4-Lite control/status slave (core_clk domain).
//
// The register file lives in core_clk on purpose: the only hand-written CDC in
// the design is then the rx_clk -> core_clk data FIFO. The clock crossing to the
// PS (FCLK0, 100 MHz) is done by the SmartConnect in the block design.
//
// Simplifications: 32-bit full-word writes only (WSTRB ignored), one
// outstanding transaction per channel, OKAY responses only.
//
// Register map (byte offsets)
//   0x000 ID          RO  0x49544348 ("ITCH")
//   0x004 CTRL        RW  [0] enable [1] pass_all [2] clear_stats (self-clear)
//                         [3] relearn (self-clear)
//   0x008 UDP_PORT    RW  [15:0]
//   0x00C WATCH_EN    RW  [3:0]
//   0x010+8i WATCH_SYM_HI[i] RW  symbol bytes 0..3 (first char in [31:24])
//   0x014+8i WATCH_SYM_LO[i] RW  symbol bytes 4..7
//   0x030+4i LEARNED[i]      RO  [31] valid, [15:0] stock locate
//   0x040.. counters          RO  see STAT_* below
//   0x070 EXP_SEQ_LO  RO   committed expected MoldUDP64 sequence
//   0x074 EXP_SEQ_HI  RO
//   0x078 FIFO_MAX    RO   max rx CDC FIFO occupancy seen
//   0x080 REC_COUNT   RO   records waiting (including head)
//   0x084 REC_POP     WO   any write pops the head record
//   0x0C0+4w REC_W[w] RO   head record, 16 words
// -----------------------------------------------------------------------------
module axil_regs (
  input  logic         clk,
  input  logic         rst,
  // AXI4-Lite slave
  input  logic [11:0]  s_awaddr,
  input  logic         s_awvalid,
  output logic         s_awready,
  input  logic [31:0]  s_wdata,
  input  logic [3:0]   s_wstrb,
  input  logic         s_wvalid,
  output logic         s_wready,
  output logic [1:0]   s_bresp,
  output logic         s_bvalid,
  input  logic         s_bready,
  input  logic [11:0]  s_araddr,
  input  logic         s_arvalid,
  output logic         s_arready,
  output logic [31:0]  s_rdata,
  output logic [1:0]   s_rresp,
  output logic         s_rvalid,
  input  logic         s_rready,
  // configuration out
  output logic         cfg_enable,
  output logic         cfg_pass_all,
  output logic         cfg_relearn,
  output logic [15:0]  cfg_udp_port,
  output logic [3:0]   cfg_watch_en,
  output logic [255:0] cfg_watch_sym,
  // status in
  input  logic [3:0]   learned_v,
  input  logic [63:0]  learned_loc,
  input  logic [63:0]  exp_seq,
  input  logic [4:0]   fifo_level,
  input  logic [11:0]  stat_pulse,      // one bit per counter, see below
  // record queue
  input  logic [511:0] rec_head,
  input  logic [10:0]  rec_count,
  output logic         rec_pop
);
  // stat_pulse bit -> counter at 0x040 + 4*bit
  //  0 frames  1 fcs_err  2 filtered  3 mold_pkts  4 msgs  5 gaps
  //  6 dup_msgs  7 len_err  8 fifo_ovf  9 records  10 rec_drop  11 heartbeats
  localparam int NSTAT = 12;

  logic [31:0] stat [0:NSTAT-1];
  logic        clr_stats;
  logic [4:0]  fifo_max;

  // ---------------- write channel ----------------
  logic wr_fire;
  assign s_awready = !s_bvalid && s_awvalid && s_wvalid;
  assign s_wready  = s_awready;
  assign wr_fire   = s_awready;          // AW and W accepted together
  assign s_bresp   = 2'b00;

  always_ff @(posedge clk) begin
    clr_stats   <= 1'b0;
    cfg_relearn <= 1'b0;
    rec_pop     <= 1'b0;
    if (rst) begin
      s_bvalid      <= 1'b0;
      cfg_enable    <= 1'b0;
      cfg_pass_all  <= 1'b0;
      cfg_udp_port  <= 16'd0;
      cfg_watch_en  <= 4'd0;
      cfg_watch_sym <= '0;
    end else begin
      if (s_bvalid && s_bready) s_bvalid <= 1'b0;
      if (wr_fire) begin
        s_bvalid <= 1'b1;
        case (s_awaddr[11:2])
          10'h001: begin
            cfg_enable   <= s_wdata[0];
            cfg_pass_all <= s_wdata[1];
            clr_stats    <= s_wdata[2];
            cfg_relearn  <= s_wdata[3];
          end
          10'h002: cfg_udp_port <= s_wdata[15:0];
          10'h003: cfg_watch_en <= s_wdata[3:0];
          10'h004: cfg_watch_sym[64*0+32 +: 32] <= s_wdata;
          10'h005: cfg_watch_sym[64*0    +: 32] <= s_wdata;
          10'h006: cfg_watch_sym[64*1+32 +: 32] <= s_wdata;
          10'h007: cfg_watch_sym[64*1    +: 32] <= s_wdata;
          10'h008: cfg_watch_sym[64*2+32 +: 32] <= s_wdata;
          10'h009: cfg_watch_sym[64*2    +: 32] <= s_wdata;
          10'h00A: cfg_watch_sym[64*3+32 +: 32] <= s_wdata;
          10'h00B: cfg_watch_sym[64*3    +: 32] <= s_wdata;
          10'h021: rec_pop <= 1'b1;
          default: ;
        endcase
      end
    end
  end

  // ---------------- counters ----------------
  always_ff @(posedge clk) begin
    for (int i = 0; i < NSTAT; i = i + 1) begin
      if (rst || clr_stats)   stat[i] <= '0;
      else if (stat_pulse[i]) stat[i] <= stat[i] + 32'd1;
    end
    if (rst || clr_stats)          fifo_max <= '0;
    else if (fifo_level > fifo_max) fifo_max <= fifo_level;
  end

  // ---------------- read channel ----------------
  logic [31:0] rd_mux;
  always_comb begin
    rd_mux = 32'h0;
    if (s_araddr[11:6] == 6'h03) begin                       // 0x0C0-0x0FC
      rd_mux = rec_head[32*s_araddr[5:2] +: 32];
    end else if (s_araddr[11:2] >= 10'h010 && s_araddr[11:2] < 10'(16 + NSTAT)) begin
      rd_mux = stat[s_araddr[5:2]];
    end else begin
      case (s_araddr[11:2])
        10'h000: rd_mux = 32'h49544348;
        10'h001: rd_mux = {29'd0, 1'b0, cfg_pass_all, cfg_enable};
        10'h002: rd_mux = {16'd0, cfg_udp_port};
        10'h003: rd_mux = {28'd0, cfg_watch_en};
        10'h004: rd_mux = cfg_watch_sym[64*0+32 +: 32];
        10'h005: rd_mux = cfg_watch_sym[64*0    +: 32];
        10'h006: rd_mux = cfg_watch_sym[64*1+32 +: 32];
        10'h007: rd_mux = cfg_watch_sym[64*1    +: 32];
        10'h008: rd_mux = cfg_watch_sym[64*2+32 +: 32];
        10'h009: rd_mux = cfg_watch_sym[64*2    +: 32];
        10'h00A: rd_mux = cfg_watch_sym[64*3+32 +: 32];
        10'h00B: rd_mux = cfg_watch_sym[64*3    +: 32];
        10'h00C: rd_mux = {learned_v[0], 15'd0, learned_loc[16*0 +: 16]};
        10'h00D: rd_mux = {learned_v[1], 15'd0, learned_loc[16*1 +: 16]};
        10'h00E: rd_mux = {learned_v[2], 15'd0, learned_loc[16*2 +: 16]};
        10'h00F: rd_mux = {learned_v[3], 15'd0, learned_loc[16*3 +: 16]};
        10'h01C: rd_mux = exp_seq[31:0];
        10'h01D: rd_mux = exp_seq[63:32];
        10'h01E: rd_mux = {27'd0, fifo_max};
        10'h020: rd_mux = {21'd0, rec_count};
        default: rd_mux = 32'hDEAD_BEEF;
      endcase
    end
  end

  assign s_arready = !s_rvalid;
  assign s_rresp   = 2'b00;

  always_ff @(posedge clk) begin
    if (rst) begin
      s_rvalid <= 1'b0;
    end else begin
      if (s_rvalid && s_rready) s_rvalid <= 1'b0;
      if (s_arvalid && s_arready) begin
        s_rvalid <= 1'b1;
        s_rdata  <= rd_mux;
      end
    end
  end

  logic unused;
  assign unused = ^{s_wstrb, s_awaddr[1:0], s_araddr[1:0]};
endmodule
