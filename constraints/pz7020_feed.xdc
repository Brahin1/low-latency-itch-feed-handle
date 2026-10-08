## =============================================================================
## pz7020_feed.xdc — PZ7020-StarLite, PL-side Gigabit Ethernet feed handler
##
## Pins from the PZ7020 pin table / schematic (PL Ethernet section).
## PHY: Realtek RTL8211F-CG, MDIO address 2, bank 34 at 3.3 V.
## RX_CLK (N18) is a clock-capable pin, which the BUFG/IDDR path needs.
## The feed handler only receives, so the TX pins are left unconstrained.
## =============================================================================

## ---------------- PL Ethernet PHY (RGMII receive) ----------------
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports rgmii_rxc]
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports rgmii_rx_ctl]
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports {rgmii_rxd[0]}]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports {rgmii_rxd[1]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {rgmii_rxd[2]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {rgmii_rxd[3]}]
## The PHY reset is tied to the board's reset key, not to an FPGA pin.

## ---------------- Clocks ----------------
## RGMII receive clock: 125 MHz at 1000 Mb/s, recovered by the PHY.
create_clock -period 8.000 -name rgmii_rxc [get_ports rgmii_rxc]
## core_clk (200 MHz) and the PS FCLK0 (100 MHz) are created by the block
## design IP (clk_wiz / processing_system7) and propagate automatically.

## ---------------- RGMII input timing ----------------
## Center-aligned DDR source-synchronous input (Vivado language template):
## the RTL8211F's internal RX delay (RXDLY) is enabled, so it delays RXC ~2 ns
## and the clock edge lands in the middle of the data eye.
## dv_* = data valid window around each edge, from the PHY datasheet
## (RGMII v2.0 spec: TsetupR / TholdR >= 1.0 ns with internal delay).
set rx_ports [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
set dv_bre 1.0 ;# valid before rising edge
set dv_are 1.0 ;# valid after  rising edge
set dv_bfe 1.0 ;# valid before falling edge
set dv_afe 1.0 ;# valid after  falling edge
set_input_delay -clock rgmii_rxc -max [expr {4.0 - $dv_bfe}] $rx_ports
set_input_delay -clock rgmii_rxc -min $dv_are                   $rx_ports
set_input_delay -clock rgmii_rxc -max [expr {4.0 - $dv_bre}] $rx_ports -clock_fall -add_delay
set_input_delay -clock rgmii_rxc -min $dv_afe                   $rx_ports -clock_fall -add_delay
## If the PHY is NOT in internal-delay mode, the clock arrives edge-aligned with
## data and this setup will fail hold. Fix: IDELAYE2 (~2 ns, IDELAYCTRL with a
## 200 MHz refclk) on each data pin, or re-strap / MDIO-configure the PHY.

## ---------------- Clock-domain crossings ----------------
## Why not set_clock_groups -asynchronous? It would cut *every* path between the
## domains, including the Gray-coded pointer buses. Those still need their
## bit-to-bit skew bounded to less than one clock period, or the receiving
## domain could sample two pointer bits changing "at the same time", which is
## exactly the failure Gray coding exists to prevent. set_max_delay
## -datapath_only keeps the bound while ignoring the meaningless clock
## relationship. 5.0 ns = one period of the faster (core) clock.

set core_clk [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clk_wiz*/clk_out1}]]

# Gray pointers, both directions
set_max_delay -datapath_only 5.000 \
  -from [get_cells -hier -filter {NAME =~ *u_cdc/u_fifo/wgray_reg*}] \
  -to   [get_cells -hier -filter {NAME =~ *u_cdc/u_fifo/u_sync_w2r/meta_reg*}]
set_max_delay -datapath_only 5.000 \
  -from [get_cells -hier -filter {NAME =~ *u_cdc/u_fifo/rgray_reg*}] \
  -to   [get_cells -hier -filter {NAME =~ *u_cdc/u_fifo/u_sync_r2w/meta_reg*}]

# LUTRAM written on rx_clk, read asynchronously on core_clk. An entry is only
# read >= 2 core cycles after the synchronized write pointer says it exists.
set_max_delay -datapath_only 5.000 \
  -from [get_cells -hier -filter {NAME =~ *u_cdc/u_fifo/mem_reg*}] -to $core_clk

# Overflow event toggle synchronizer
set_max_delay -datapath_only 5.000 \
  -from [get_cells -hier -filter {NAME =~ *u_cdc/u_ovf_sync/tog_reg}] \
  -to   [get_cells -hier -filter {NAME =~ *u_cdc/u_ovf_sync/s1_reg}]

# Reset bridge into rx_clk: asynchronous assertion only.
set_false_path -to [get_pins -hier -filter {NAME =~ *u_rx_rst/r_reg*/PRE}]
