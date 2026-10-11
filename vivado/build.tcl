# =============================================================================
# build.tcl — Vivado project + block design + implementation for the PZ7020.
#
#   vivado -mode batch -source vivado/build.tcl
#
# Needs from Puzhi's download package:
#   vendor/pz7020_ps7_preset.tcl  PS7 configuration (33.333 MHz PS clock,
#                                 MT41K256M16TW-107IT DDR3 x16, MIO map for
#                                 UART / SD / PS Ethernet on GEM0)
#
# Block design
#   processing_system7 --M_AXI_GP0 (FCLK0 100 MHz)--> smartconnect (2 clocks)
#                                                         |  (core_clk)
#   clk_wiz: FCLK0 -> 200 MHz core_clk                    v
#   proc_sys_reset (core_clk)  ------------------->  feed_handler_top (module ref)
#   RGMII RX pins made external
# =============================================================================
set root    [file normalize [file dirname [info script]]/..]
set part    xc7z020clg400-2
set proj    feed_handler
set outdir  $root/vivado/out

create_project $proj $outdir/$proj -part $part -force
set_property target_language Verilog [current_project]

add_files -norecurse [glob $root/rtl/*.sv]
set_property file_type SystemVerilog [get_files *.sv]
add_files -fileset constrs_1 -norecurse $root/constraints/pz7020_feed.xdc
update_compile_order -fileset sources_1

# ---------------- block design ----------------
create_bd_design system

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7
source $root/vendor/pz7020_ps7_preset.tcl        ;# sets CONFIG.* on ps7
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} \
                         CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100}] [get_bd_cells ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" Master "Disable" Slave "Disable"} [get_bd_cells ps7]

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz
set_property -dict [list CONFIG.PRIM_IN_FREQ {100.000} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
                         CONFIG.USE_RESET {false}] [get_bd_cells clk_wiz]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins clk_wiz/clk_in1]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_core
connect_bd_net [get_bd_pins clk_wiz/clk_out1]     [get_bd_pins rst_core/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]     [get_bd_pins rst_core/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz/locked]        [get_bd_pins rst_core/dcm_locked]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ps
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]         [get_bd_pins rst_ps/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]     [get_bd_pins rst_ps/ext_reset_in]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_sc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells axi_sc]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_sc/S00_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_pins axi_sc/aclk] [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins clk_wiz/clk_out1]  [get_bd_pins axi_sc/aclk1]
connect_bd_net [get_bd_pins rst_ps/interconnect_aresetn] [get_bd_pins axi_sc/aresetn]

create_bd_cell -type module -reference feed_handler_top fh
connect_bd_net [get_bd_pins clk_wiz/clk_out1]       [get_bd_pins fh/core_clk]
connect_bd_net [get_bd_pins rst_core/peripheral_reset] [get_bd_pins fh/core_rst]
connect_bd_intf_net [get_bd_intf_pins axi_sc/M00_AXI] [get_bd_intf_pins fh/s_axil]
foreach p {rgmii_rxc rgmii_rxd rgmii_rx_ctl} {
  make_bd_pins_external [get_bd_pins fh/$p]
  set_property name $p [get_bd_ports ${p}_0]
}

assign_bd_address -target_address_space /ps7/Data [get_bd_addr_segs fh/s_axil/reg0] -range 4K -offset 0x43C00000
validate_bd_design
save_bd_design

make_wrapper -files [get_files system.bd] -top
add_files -norecurse [glob $outdir/$proj/$proj.gen/sources_1/bd/system/hdl/system_wrapper.v]
set_property top system_wrapper [current_fileset]

# ---------------- implementation ----------------
launch_runs synth_1 -jobs 8
wait_on_run synth_1
open_run synth_1
if {[file exists $root/vivado/insert_ila.tcl] && [info exists ::env(ILA)]} {
  source $root/vivado/insert_ila.tcl
}
report_utilization -hierarchical -file $outdir/util_synth_hier.rpt

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1

report_timing_summary -max_paths 20 -report_unconstrained -file $outdir/timing_summary.rpt
report_timing -sort_by group -max_paths 10 -path_type full -file $outdir/timing_top10.rpt
report_utilization -file $outdir/util.rpt
report_utilization -hierarchical -file $outdir/util_hier.rpt
report_clock_interaction -file $outdir/clock_interaction.rpt
report_cdc -details -file $outdir/cdc.rpt
report_methodology -file $outdir/methodology.rpt
report_power -file $outdir/power.rpt

write_hw_platform -fixed -include_bit -force $outdir/feed_handler.xsa
puts "Done. Bitstream + XSA in $outdir"
