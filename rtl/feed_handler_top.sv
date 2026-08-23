// -----------------------------------------------------------------------------
// feed_handler_top.sv — wire-to-record ITCH 5.0 feed handler for the PZ7020.
//
//   PL GbE PHY --RGMII--> rgmii_rx -> eth_mac_rx      [rx_clk, 125 MHz, PHY-recovered]
//                                        |
//                                   rx_cdc (async FIFO, Gray pointers)
//                                        |
//        udp_rx -> moldudp64_rx -> itch_decoder -> record stream   [core_clk, 200 MHz]
//                                                   |          \
//                                             rec_fifo (BRAM)   rec_* ports (in-fabric consumer)
//                                                   |
//                                             axil_regs <--AXI4-Lite-- SmartConnect <-- PS (ARM)
//
// No processor touches a packet between the PHY pins and the decoded record.
// -----------------------------------------------------------------------------
module feed_handler_top #(
  parameter int REC_AW = 9                    // record queue depth = 2**REC_AW
) (
  input  logic         core_clk,
  input  logic         core_rst,              // synchronous to core_clk (proc_sys_reset)

  // PL-side Gigabit Ethernet PHY
  input  logic         rgmii_rxc,
  input  logic [3:0]   rgmii_rxd,
  input  logic         rgmii_rx_ctl,

  // AXI4-Lite slave (core_clk)
  input  logic [11:0]  s_axil_awaddr,
  input  logic         s_axil_awvalid,
  output logic         s_axil_awready,
  input  logic [31:0]  s_axil_wdata,
  input  logic [3:0]   s_axil_wstrb,
  input  logic         s_axil_wvalid,
  output logic         s_axil_wready,
  output logic [1:0]   s_axil_bresp,
  output logic         s_axil_bvalid,
  input  logic         s_axil_bready,
  input  logic [11:0]  s_axil_araddr,
  input  logic         s_axil_arvalid,
  output logic         s_axil_arready,
  output logic [31:0]  s_axil_rdata,
  output logic [1:0]   s_axil_rresp,
  output logic         s_axil_rvalid,
  input  logic         s_axil_rready,

  // Decoded record stream (for an in-fabric consumer, and the testbench)
  output logic         rec_valid,
  output logic [7:0]   rec_type,
  output logic [15:0]  rec_locate,
  output logic [47:0]  rec_ts,
  output logic [63:0]  rec_ref,
  output logic [63:0]  rec_new_ref,
  output logic [7:0]   rec_side,
  output logic [31:0]  rec_shares,
  output logic [31:0]  rec_price,
  output logic [63:0]  rec_stock,
  output logic [63:0]  rec_match,
  output logic [63:0]  rec_seq,
  output logic [1:0]   rec_sym_idx,
  output logic         rec_fend,
  output logic         rec_fend_ok
);
  // ---------------- rx_clk domain ----------------
  logic       rx_clk, rx_rst;
  logic [7:0] gmii_d;
  logic       gmii_dv, gmii_er;
  logic       mac_valid, mac_last, mac_err;
  logic [7:0] mac_data;

  rgmii_rx u_rgmii (
    .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
    .rx_clk(rx_clk), .gmii_rxd(gmii_d), .gmii_rx_dv(gmii_dv), .gmii_rx_er(gmii_er));

  // The PL PHY's reset is tied to the board reset key, not an FPGA pin, so the
  // rx_clk domain just follows core_rst through an async-assert bridge.
  reset_sync u_rx_rst (.clk(rx_clk), .arst(core_rst), .rst(rx_rst));

  eth_mac_rx u_mac (
    .clk(rx_clk), .rst(rx_rst),
    .rx_d(gmii_d), .rx_dv(gmii_dv), .rx_er(gmii_er),
    .m_valid(mac_valid), .m_data(mac_data), .m_last(mac_last), .m_err(mac_err));

  // ---------------- CDC ----------------
  logic       s_valid, s_last, s_err, st_ovf;
  logic [7:0] s_data;
  logic [4:0] fifo_level;

  rx_cdc #(.AW(4)) u_cdc (
    .rx_clk(rx_clk), .rx_rst(rx_rst),
    .m_valid(mac_valid), .m_data(mac_data), .m_last(mac_last), .m_err(mac_err),
    .clk(core_clk), .rst(core_rst),
    .s_valid(s_valid), .s_data(s_data), .s_last(s_last), .s_err(s_err),
    .st_ovf(st_ovf), .level(fifo_level));

  // ---------------- core_clk parse pipeline ----------------
  logic         cfg_enable, cfg_pass_all, cfg_relearn;
  logic [15:0]  cfg_udp_port;
  logic [3:0]   cfg_watch_en;
  logic [255:0] cfg_watch_sym;

  logic        p_valid, p_first, p_last, f_done, f_ok, f_acc;
  logic [7:0]  p_data;
  logic        st_frame, st_fcs_err, st_filtered;

  udp_rx u_udp (
    .clk(core_clk), .rst(core_rst),
    .cfg_enable(cfg_enable), .cfg_udp_port(cfg_udp_port),
    .s_valid(s_valid), .s_data(s_data), .s_last(s_last), .s_err(s_err),
    .p_valid(p_valid), .p_data(p_data), .p_first(p_first), .p_last(p_last),
    .f_done(f_done), .f_ok(f_ok), .f_acc(f_acc),
    .st_frame(st_frame), .st_fcs_err(st_fcs_err), .st_filtered(st_filtered));

  logic        m_valid, m_first, m_last, o_done, o_ok, o_acc;
  logic [7:0]  m_data;
  logic [63:0] m_seq, exp_seq;
  logic        st_pkt, st_hb, st_gap, st_dup;

  moldudp64_rx u_mold (
    .clk(core_clk), .rst(core_rst),
    .p_valid(p_valid), .p_data(p_data), .p_first(p_first), .p_last(p_last),
    .f_done(f_done), .f_ok(f_ok), .f_acc(f_acc),
    .m_valid(m_valid), .m_data(m_data), .m_first(m_first), .m_last(m_last), .m_seq(m_seq),
    .o_done(o_done), .o_ok(o_ok), .o_acc(o_acc),
    .exp_seq_o(exp_seq),
    .st_pkt(st_pkt), .st_hb(st_hb), .st_gap(st_gap), .st_dup(st_dup));

  logic [3:0]  learned_v;
  logic [63:0] learned_loc;
  logic        st_msg, st_len_err, st_rec;

  itch_decoder u_itch (
    .clk(core_clk), .rst(core_rst),
    .cfg_pass_all(cfg_pass_all), .cfg_relearn(cfg_relearn),
    .cfg_watch_en(cfg_watch_en), .cfg_watch_sym(cfg_watch_sym),
    .m_valid(m_valid), .m_data(m_data), .m_first(m_first), .m_last(m_last), .m_seq(m_seq),
    .f_done(o_done), .f_ok(o_ok), .f_acc(o_acc),
    .learned_v(learned_v), .learned_loc(learned_loc),
    .r_valid(rec_valid), .r_type(rec_type), .r_locate(rec_locate), .r_ts(rec_ts),
    .r_ref(rec_ref), .r_new_ref(rec_new_ref), .r_side(rec_side), .r_shares(rec_shares),
    .r_price(rec_price), .r_stock(rec_stock), .r_match(rec_match), .r_seq(rec_seq),
    .r_sym_idx(rec_sym_idx), .r_fend(rec_fend), .r_fend_ok(rec_fend_ok),
    .st_msg(st_msg), .st_len_err(st_len_err), .st_rec(st_rec));

  // ---------------- record queue ----------------
  logic [31:0]  cyc;
  always_ff @(posedge core_clk) cyc <= core_rst ? 32'd0 : cyc + 32'd1;

  logic [511:0] rec_word, rec_head;
  logic         rec_full, rec_head_valid, rec_pop, rec_wr;
  logic [REC_AW+1:0] rec_count;

  // 16 x 32-bit words, word w at [32*w +: 32]
  always_comb begin
    rec_word = '0;
    if (rec_valid) begin
      rec_word[32*0  +: 32] = {rec_type, rec_side, rec_locate};
      rec_word[32*1  +: 32] = {14'd0, rec_sym_idx, rec_ts[47:32]};
      rec_word[32*2  +: 32] = rec_ts[31:0];
      rec_word[32*3  +: 32] = rec_ref[63:32];
      rec_word[32*4  +: 32] = rec_ref[31:0];
      rec_word[32*5  +: 32] = rec_new_ref[63:32];
      rec_word[32*6  +: 32] = rec_new_ref[31:0];
      rec_word[32*7  +: 32] = rec_shares;
      rec_word[32*8  +: 32] = rec_price;
      rec_word[32*9  +: 32] = rec_stock[63:32];
      rec_word[32*10 +: 32] = rec_stock[31:0];
      rec_word[32*11 +: 32] = rec_match[63:32];
      rec_word[32*12 +: 32] = rec_match[31:0];
      rec_word[32*13 +: 32] = rec_seq[63:32];
      rec_word[32*14 +: 32] = rec_seq[31:0];
    end else begin
      // frame commit marker: type 0xFF, bit 0 of the side byte = frame OK
      rec_word[32*0  +: 32] = {8'hFF, 7'd0, rec_fend_ok, 16'd0};
    end
    rec_word[32*15 +: 32] = cyc;
  end

  // The decoder never raises rec_valid and rec_fend in the same cycle.
  assign rec_wr = rec_valid | rec_fend;

  rec_fifo #(.W(512), .AW(REC_AW)) u_recq (
    .clk(core_clk), .rst(core_rst),
    .wr_en(rec_wr), .wdata(rec_word), .full(rec_full),
    .pop(rec_pop), .head(rec_head), .head_valid(rec_head_valid), .count(rec_count));

  // ---------------- control / status ----------------
  logic [11:0] stat_pulse;
  assign stat_pulse = {st_hb, rec_wr & rec_full, st_rec, st_ovf, st_len_err, st_dup,
                       st_gap, st_msg, st_pkt, st_filtered, st_fcs_err, st_frame};

  axil_regs u_regs (
    .clk(core_clk), .rst(core_rst),
    .s_awaddr(s_axil_awaddr), .s_awvalid(s_axil_awvalid), .s_awready(s_axil_awready),
    .s_wdata(s_axil_wdata), .s_wstrb(s_axil_wstrb), .s_wvalid(s_axil_wvalid),
    .s_wready(s_axil_wready), .s_bresp(s_axil_bresp), .s_bvalid(s_axil_bvalid),
    .s_bready(s_axil_bready), .s_araddr(s_axil_araddr), .s_arvalid(s_axil_arvalid),
    .s_arready(s_axil_arready), .s_rdata(s_axil_rdata), .s_rresp(s_axil_rresp),
    .s_rvalid(s_axil_rvalid), .s_rready(s_axil_rready),
    .cfg_enable(cfg_enable), .cfg_pass_all(cfg_pass_all), .cfg_relearn(cfg_relearn),
    .cfg_udp_port(cfg_udp_port), .cfg_watch_en(cfg_watch_en), .cfg_watch_sym(cfg_watch_sym),
    .learned_v(learned_v), .learned_loc(learned_loc), .exp_seq(exp_seq),
    .fifo_level(fifo_level), .stat_pulse(stat_pulse),
    .rec_head(rec_head), .rec_count(rec_count[10:0]), .rec_pop(rec_pop));

  logic unused;
  assign unused = rec_head_valid;   // head validity is implied by REC_COUNT != 0
endmodule
