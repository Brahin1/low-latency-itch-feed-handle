# =============================================================================
# insert_ila.tcl — add two Integrated Logic Analyzers to the synthesized netlist.
# Run inside an open synthesized design (build.tcl does this when ILA=1).
#
#   ILA_RX   (rx_clk,   125 MHz): what the PHY is actually giving us
#   ILA_CORE (core_clk, 200 MHz): what the parser does with it
#
# Why two cores: an ILA samples on exactly one clock. Probing rx_clk signals
# from a core_clk ILA would itself be an unsynchronized crossing and show
# garbage. One ILA per domain.
# =============================================================================
proc add_probe {core nets} {
  set nets [get_nets -hier -filter "NAME =~ $nets"]
  set p [create_debug_port $core probe]
  set_property port_width [llength $nets] $p
  connect_debug_port $p $nets
}

# ---------------- rx_clk domain ----------------
create_debug_core u_ila_rx ila
set_property C_DATA_DEPTH 4096     [get_debug_cores u_ila_rx]
set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores u_ila_rx]
connect_debug_port u_ila_rx/clk [get_nets -hier -filter {NAME =~ *u_rgmii/rx_clk}]
set_property port_width 8 [get_debug_ports u_ila_rx/probe0]
connect_debug_port u_ila_rx/probe0 [get_nets -hier -filter {NAME =~ *u_rgmii/gmii_rxd[*]}]
add_probe u_ila_rx {*u_rgmii/gmii_rx_dv}
add_probe u_ila_rx {*u_rgmii/gmii_rx_er}
add_probe u_ila_rx {*u_mac/st[*]}
add_probe u_ila_rx {*u_mac/m_last}
add_probe u_ila_rx {*u_mac/m_err}
add_probe u_ila_rx {*u_cdc/full}
add_probe u_ila_rx {*u_cdc/ovf_evt}

# ---------------- core_clk domain ----------------
create_debug_core u_ila_core ila
set_property C_DATA_DEPTH 8192     [get_debug_cores u_ila_core]
set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores u_ila_core]
connect_debug_port u_ila_core/clk [get_nets -hier -filter {NAME =~ *fh/core_clk}]
set_property port_width 8 [get_debug_ports u_ila_core/probe0]
connect_debug_port u_ila_core/probe0 [get_nets -hier -filter {NAME =~ *u_cdc/s_data[*]}]
add_probe u_ila_core {*u_cdc/s_valid}
add_probe u_ila_core {*u_cdc/s_last}
add_probe u_ila_core {*u_cdc/s_err}
add_probe u_ila_core {*u_udp/st[*]}
add_probe u_ila_core {*u_mold/st[*]}
add_probe u_ila_core {*u_mold/st_gap}
add_probe u_ila_core {*u_mold/st_dup}
add_probe u_ila_core {*u_itch/r_valid}
add_probe u_ila_core {*u_itch/r_type[*]}
add_probe u_ila_core {*u_itch/r_fend}
add_probe u_ila_core {*u_itch/r_fend_ok}
add_probe u_ila_core {*u_itch/st_len_err}

implement_debug_core
write_debug_probes -force [file normalize [file dirname [info script]]/out/feed_handler.ltx]
