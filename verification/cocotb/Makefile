# cocotb port-level long-random regression for wfq_tag_sort_engine.
# Equivalent of the Stage 5 "long" suite (tb_wfq_engine_acceptance RUN_MODE=1,
# driven by scripts/run_stage5.py --suite long), reimplemented as a black-box
# cocotb testbench. See README.md for the check mapping and known differences.

# Usage (activate the RTL environment first: source .../activate_rtl_env.sh):
#   make                                   # PTR=10 DEPTH=1024 FLOW=9 SEED=12345 TARGET=100000
#   make SEED=5381 TARGET=20000            # single shorter run
#   py -3 run_long.py [--quick]            # full 2 configs x 10 seeds driver

SIM ?= icarus
TOPLEVEL ?= wfq_tag_sort_engine
TOPLEVEL_LANG ?= verilog
COCOTB_TEST_MODULES ?= test_long_random

RTL_DIR := $(abspath ../../rtl)
VERILOG_SOURCES := $(wildcard $(RTL_DIR)/*.v)

PTR_WIDTH ?= 10
MEM_DEPTH ?= 1024
FLOW_ID_WIDTH ?= 9
SEED ?= 12345
TARGET ?= 100000
export SEED TARGET PTR_WIDTH MEM_DEPTH FLOW_ID_WIDTH

# cocotb's Makefile does not rebuild when only -P parameters change, so give
# every parameter combination its own build directory (SEED/TARGET are runtime
# only and share the binary).
SIM_BUILD ?= sim_build_ptr$(PTR_WIDTH)_depth$(MEM_DEPTH)_flow$(FLOW_ID_WIDTH)

COMPILE_ARGS += -g2001 -I $(RTL_DIR)/include
COMPILE_ARGS += -P$(TOPLEVEL).PTR_WIDTH=$(PTR_WIDTH)
COMPILE_ARGS += -P$(TOPLEVEL).MEM_DEPTH=$(MEM_DEPTH)
COMPILE_ARGS += -P$(TOPLEVEL).FLOW_ID_WIDTH=$(FLOW_ID_WIDTH)

include $(shell cocotb-config --makefiles)/Makefile.sim
