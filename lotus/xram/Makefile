default: bTestXRAM1 vTestXRAM1 bTestXRAM2 vTestXRAM2 bTestXRegFile1 vTestXRegFile1

bdpiMem.o: bdpiMem.cpp Makefile
	g++ -O3 -c bdpiMem.cpp -o bdpiMem.o

bTestXRAM%: XRAM.bsv TestXRAM.bsv bdpiMem.o
	rm -f *.bo *.ba && bsc -check-assert -aggressive-conditions -show-schedule -D WITH_BLUESIM -sim -g $(subst bTest,mkTest,$@) -u TestXRAM.bsv && bsc -sim -e $(subst bTest,mkTest,$@) -Xl bdpiMem.o -o $@

vTestXRAM%: XRAM.bsv TestXRAM.bsv XRAM.sv
	rm -f *.bo *.ba && bsc -check-assert -aggressive-conditions -show-schedule -verilog -g $(subst vTest,mkTest,$@) -u TestXRAM.bsv && bsc -vsim verilator -e  $(subst vTest,mkTest,$@) -Xv XRAM.sv -o $@

bTestXRegFile%: XRegFile.bsv TestXRegFile.bsv bdpiMem.o
	rm -f *.bo *.ba && bsc -check-assert -aggressive-conditions -show-schedule -D WITH_BLUESIM -sim -g $(subst bTest,mkTest,$@) -u TestXRegFile.bsv && bsc -sim -e $(subst bTest,mkTest,$@) -Xl bdpiMem.o -o $@

vTestXRegFile%: XRegFile.bsv TestXRegFile.bsv XRegFile.sv
	rm -f *.bo *.ba && bsc -check-assert -aggressive-conditions -show-schedule -verilog -g $(subst vTest,mkTest,$@) -u TestXRegFile.bsv && bsc -vsim verilator -e  $(subst vTest,mkTest,$@) -Xv XRegFile.sv -o $@

clean:
	rm -f *.bo *.ba *.o *.sched mkTest* model_mkTest* imported_BDPI_functions.h
	rm -rf bTest* vTest*
	rm -rf obj_dir_*
