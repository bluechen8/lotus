SHELL:=/bin/bash

.PHONY: all clean Core

all: Top

DIRS = $(shell find ../ -maxdepth 1 -type d | tr '\n' ':')

BSC_SEARCH = -p .:%/Libraries:$(DIRS)
MSC_SEARCH = -p ../xram/:../utils/

bsv:
	make -C ../xram/ bdpiMem.o
	msc ${MSC_SEARCH} --bscOpts ' -D WITH_BLUESIM -Xl ../../xram/bdpiMem.o ' -o bsv Core.ms
	bsc -D NUM_TILES_DEFINE=1 $(BSC_SEARCH)  -check-assert -D WITH_BLUESIM  -aggressive-conditions -show-schedule -sim -g mkCoreBsv -u CoreBsv.bsv

# FIXME(dsm): If this fails, try switching between ../xram/bdpiMem.o and xram/bdpiMem.o. This is some bsc path heisenbug, where it doesn't catch the path during elaboration even though it should. In my setup, xram/bdpiMem.o worked fine until I started building with verilator as well; then it stopped working, even on a clean build!
Top: *.ms
	make -C ../xram/ bdpiMem.o
	rm -f *.{ba,bo} && msc ${MSC_SEARCH} --bscOpts ' -check-assert -D WITH_BLUESIM -Xl ../../xram/bdpiMem.o ' Top.ms Top

test: Top
	./test.py a,f,p,s1,s2,s3,b,u

Core: Core.ms
	msc $< $@

clean:
	rm -rf *.v *.bo *.ba *.cxx *.o *.h *.so mem.vmh
	rm -rf test_out
	rm -rf synthDir
	rm -rf Core
	rm -rf DecodeTB
	rm -rf tmp_msc_*

superclean: clean
	make -C sw clean

xsim:
	rm -f *.{ba,bo} && msc -o v --bscOpts ' -check-assert -opt-undetermined-vals -unspecified-to X ' Top.ms Top
	xvlog xsim_tb.v Top.v $$(dirname $$(which bsc))/../lib/Verilog.Vivado/BRAM1BELoad.v
	xvlog --sv XR*.sv
	xelab xsim_tb -debug all
	#xelab xsim_tb --O3
	xsim -R work.xsim_tb

verilate:
	rm -f *.{ba,bo} && msc -o bsv Top.ms Top
	bsc -D NUM_TILES_DEFINE=1 -check-assert -aggressive-conditions -verilog -g mkTop -u Top.bsv
	bsc -vsim verilator -e mkTop -o vTop -Xv XRAM.sv XRegFile.sv
	rm Top.bsv
