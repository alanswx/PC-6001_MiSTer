#============================================================================
#  NEC PC-6001 Verilator simulation
#
#    make            # headless sim            -> ./obj_dir_headless/Vtop
#    make test       # regression tests (run_tests.sh)
#    make clean
#
#  The machine (rtl/pc6001.sv) is SystemVerilog and goes to Verilator as is.
#  The CPU is the VHDL T80 (rtl/T80_v350, as SMC777_MiSTer), turned into a
#  Verilog netlist by "ghdl synth" with the generics of its instance fixed.
#
#  Requires: ghdl (5.x, synth built in), verilator (5.x), python3.
#============================================================================

V      = verilator
GHDL   = ghdl
RTL    = ../rtl
GEN    = gen
WORK   = ghdl_work

GHDL_FLAGS = --std=08 -fsynopsys -fexplicit -frelaxed -Wno-hide -Wno-shared -Wno-binding --workdir=$(WORK)

T80_SRC = $(RTL)/T80_v350/T80_ALU.vhd $(RTL)/T80_v350/T80_Reg.vhd $(RTL)/T80_v350/T80_MCode.vhd \
	$(RTL)/T80_v350/T80.vhd $(RTL)/T80_v350/T80s.vhd
GEN_V = $(GEN)/t80s.v

JT49_SRC = $(RTL)/jt49/jt49_bus.v $(RTL)/jt49/jt49.v $(RTL)/jt49/jt49_cen.v $(RTL)/jt49/jt49_div.v \
	$(RTL)/jt49/jt49_eg.v $(RTL)/jt49/jt49_exp.v $(RTL)/jt49/jt49_noise.v

V_SRC = sim.v $(RTL)/pc6001.sv $(RTL)/pc6001_vdg.sv $(RTL)/pc6001_sub.sv $(RTL)/tape_overlay.sv $(RTL)/pc6031.sv $(RTL)/upd765_lite.sv $(RTL)/d88_media.sv $(RTL)/dpram_tdp.sv $(RTL)/i8255_m0.sv $(RTL)/touch_panel.sv $(RTL)/touch_mouse.sv $(RTL)/pc6001_composite.sv $(RTL)/composite_decoder.sv $(JT49_SRC) $(GEN_V)
V_INC = $(RTL)/pc6001_keytable.svh $(RTL)/pc6001_intfont.svh

V_OPT = -O3 -I$(RTL) --x-assign fast --x-initial fast --noassert --savable \
	-Wno-fatal -Wno-PINMISSING -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
	-Wno-UNSIGNED -Wno-CMPCONST -Wno-DECLFILENAME -Wno-MULTIDRIVEN -Wno-LATCH \
	-Wno-TIMESCALEMOD -Wno-COMBDLY -Wno-INITIALDLY -Wno-BLKANDNBLK -Wno-CASEX

# EXTRA: more Verilator options
V_OPT += $(EXTRA)

CXXFLAGS = -O3 -std=c++17
# Tape turbo factor (rtl/pc6001.sv TURBO); any other value than 7 builds into its own directory
TURBO   ?= 7
HL_DIR   = obj_dir_headless$(if $(filter-out 7,$(TURBO)),_t$(TURBO))
HL_EXE   = ./$(HL_DIR)/Vtop

all: headless

headless: $(HL_EXE)

# T80s as rtl/pc6001.sv instantiates it: Mode 0 (Z80), T2Write 1, IOWait 1.
$(WORK)/.analysed: $(T80_SRC) Makefile
	@mkdir -p $(WORK)
	$(GHDL) -a $(GHDL_FLAGS) $(T80_SRC)
	@touch $@

$(GEN)/t80s.v: $(WORK)/.analysed fix_port_aliases.py
	@mkdir -p $(GEN)
	$(GHDL) synth $(GHDL_FLAGS) -gMode=0 -gT2Write=1 -gIOWait=1 --out=verilog T80s > $@.tmp
	$(GHDL) synth $(GHDL_FLAGS) -gMode=0 -gT2Write=1 -gIOWait=1 --out=vhdl T80s > $(GEN)/t80s_netlist.vhd
	python3 fix_port_aliases.py $@.tmp $(GEN)/t80s_netlist.vhd
	@# VHDL names that are (System)Verilog keywords.
	perl -pi -e 's/\b(do|config)\b/$${1}_v/g' $@.tmp
	@mv $@.tmp $@

netlist: $(GEN_V)

$(HL_EXE): $(V_SRC) $(V_INC) sim_headless.cpp ps2_keys.h Makefile
	$V -cc $(V_OPT) -GTURBO=$(TURBO) --exe --build -j 0 --Mdir $(HL_DIR) --top-module top \
		-CFLAGS "$(CXXFLAGS)" $(V_SRC) sim_headless.cpp -o Vtop

test: headless
	./run_tests.sh

clean:
	rm -rf $(HL_DIR) $(GEN) $(WORK) out

.PHONY: all headless netlist test clean
