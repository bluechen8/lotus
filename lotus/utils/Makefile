BUILDDIR = ./build
INCLUDEPATHS = .:%/Libraries:../xram/
BSC_SEARCH = -p ${INCLUDEPATHS}
BUILDFLAGS = ${BSC_SEARCH} ${DEBUG_EN} -bdir ${BUILDDIR} -fdir ${BUILDDIR} -simdir ${BUILDDIR} -vdir ${BUILDDIR}

gear: clean
	mkdir -p ${BUILDDIR}
	bsc -check-assert -D SIM_PARAMS -D WITH_BLUESIM  -aggressive-conditions -show-schedule ${BUILDFLAGS} -sim -g mkGearBoxL2S -u GearBoxUtils.bsv

sip: clean
	mkdir -p ${BUILDDIR}
	bsc -check-assert -D SIM_PARAMS -D WITH_BLUESIM -D SIP_TRACE -aggressive-conditions -show-schedule ${BUILDFLAGS} -sim -g mkTestSIPPipe -u Sip.bsv
	bsc -sim -D WITH_BLUESIM ${BUILDFLAGS} -Xl ../xram/bdpiMem.o -e mkTestSIPPipe -o ${BUILDDIR}/sim_mkTestSIPPipe

sipnet: clean
	bsc -p .:%/Libraries:../xram/ -aggressive-conditions -opt-undetermined-vals -unspecified-to X -show-schedule -verilog -g mkTestSIPNet -u Sip.bsv
	sed -i '1s|^|`timescale 1ps/1ps |' mkTestSIPNet.v

clean:
	rm -rf build ../*/*.bo *.sched
# end
