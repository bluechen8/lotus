CACHE_SRCS = L2Cache.bsv L2CacheBank.bsv ../xram/XRAMUtils.bsv ../switch/Switch.bsv ../utils/NonBlockingPipe.bsv ../utils/ShiftFIFO.bsv ../utils/SkidFIFO.bsv ../config/LotusGlobalConfig.bsv ../xram/XRAM.bsv ../xram/bdpiMem.o
VNAME = mkL2Cache

TBSRCS = TestL2Cache.bsv
SIMNAME = mkTestL2Cache

INCLUDEPATHS = .:%/Libraries:../xram/:../switch/:../utils/:../config/
BSC_SEARCH = -p ${INCLUDEPATHS}

BUILDDIR = ./build

DEFINES = -D NUM_TILES_DEFINE=1 -D NUM_CORES_PER_TILE_DEFINE=8 -D NUM_TASKS_PER_TILE_DEFINE=4096

BUILDFLAGS = ${DEBUG_EN} -bdir ${BUILDDIR} -fdir ${BUILDDIR} -simdir ${BUILDDIR} -vdir ${BUILDDIR}

default: sim

../xram/bdpiMem.o: ../xram/bdpiMem.cpp Makefile
	g++ -O3 -c ../xram/bdpiMem.cpp -o ../xram/bdpiMem.o

topsim: $(TBSRCS) $(CACHE_SRCS) clean
	which bsc
	bsc $(BSC_SEARCH) $(DEFINES) -check-assert -D SIM_PARAMS -D WITH_BLUESIM  -aggressive-conditions -show-schedule ${BUILDFLAGS} -sim -g ${SIMNAME} -u $<
	bsc -sim -e ${SIMNAME} -D WITH_BLUESIM  ${BUILDFLAGS} -Xl ../xram/bdpiMem.o -o ${BUILDDIR}/sim_${SIMNAME}

topveri: $(CACHE_SRCS) clean
	bsc $(BSC_SEARCH) $(DEFINES) -check-assert -aggressive-conditions -opt-undetermined-vals -unspecified-to X -show-schedule -verilog -g ${VNAME} -u $<
	../../../scripts/postprocess_bsc_verilog.py --noRegReset < mkL2CacheBank.v > tmp.v
	mv tmp.v mkL2CacheBank.v
	../../../scripts/postprocess_bsc_verilog.py --noRegReset < mkL2Cache.v > tmp.v
	mv tmp.v mkL2Cache.v

synth: topveri
	vivado -mode batch -source ooc.tcl -tclargs ${BUILDDIR}  | tee ${BUILDDIR}/vivado.log

sim: topsim
	${BUILDDIR}/sim_${SIMNAME}

simd: DEBUG_EN := -D DEBUG_PRINTS
simd: topsim
	${BUILDDIR}/sim_${SIMNAME}

clean:
	rm -rf ../*/*.bo
	rm -rf build/*.so
	rm -rf build/*.bo
	rm -rf build/*.v
	rm -f *.sched
	rm -f *.so
	rm -f *.bo
	rm -f *.v
	mkdir -p build
