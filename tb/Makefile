# cocotb 2.x + Icarus Verilog 12
#   make                 # end-to-end tests (feed_handler_top)
#   make TEST=fifo       # async FIFO unit test
#   make WAVES=1         # dump an FST waveform for GTKWave/Surfer

SIM            ?= icarus
TOPLEVEL_LANG  ?= verilog
TEST           ?= top
RTL            := $(abspath ../rtl)

COMPILE_ARGS   += -g2012
SIM_BUILD      := sim_build_$(TEST)
export PYTHONPATH := $(abspath ../tools):$(PYTHONPATH)

ifeq ($(TEST),fifo)
  VERILOG_SOURCES      = $(RTL)/cdc_prims.sv $(RTL)/async_fifo.sv
  COCOTB_TOPLEVEL      = async_fifo
  COCOTB_TEST_MODULES  = test_async_fifo
else
  VERILOG_SOURCES      = $(RTL)/cdc_prims.sv $(RTL)/async_fifo.sv $(RTL)/rgmii_rx.sv \
                         $(RTL)/eth_mac_rx.sv $(RTL)/rx_cdc.sv $(RTL)/udp_rx.sv \
                         $(RTL)/moldudp64_rx.sv $(RTL)/itch_decoder.sv $(RTL)/rec_fifo.sv \
                         $(RTL)/axil_regs.sv $(RTL)/feed_handler_top.sv
  COCOTB_TOPLEVEL      = feed_handler_top
  COCOTB_TEST_MODULES  = test_top
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
