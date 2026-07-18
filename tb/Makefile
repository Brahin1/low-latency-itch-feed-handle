# cocotb 2.x + Icarus Verilog 12
#   make TEST=fifo       # async FIFO unit test
#   make WAVES=1         # dump an FST waveform for GTKWave/Surfer

SIM            ?= icarus
TOPLEVEL_LANG  ?= verilog
TEST           ?= fifo
RTL            := $(abspath ../rtl)

COMPILE_ARGS   += -g2012
SIM_BUILD      := sim_build_$(TEST)
export PYTHONPATH := $(abspath ../tools):$(PYTHONPATH)

ifeq ($(TEST),fifo)
  VERILOG_SOURCES      = $(RTL)/cdc_prims.sv $(RTL)/async_fifo.sv
  COCOTB_TOPLEVEL      = async_fifo
  COCOTB_TEST_MODULES  = test_async_fifo
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
