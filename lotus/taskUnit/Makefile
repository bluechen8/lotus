
CACHE_SRCS = TaskUnit.bsv
CACHE_SRCS += ../xram/XRAMUtils.bsv ../xram/XRAM.bsv ../xram/bdpiMem.o ../utils/NonBlockingPipe.bsv

VNAME = mkTaskUnit

DIRS = $(shell find ../ -maxdepth 1 -type d | tr '\n' ':')
INCLUDEPATHS = %:%/Libraries:$(DIRS)
BSC_SEARCH = -p ${INCLUDEPATHS}

BUILDDIR = ./build

BUILDFLAGS = ${DEBUG_EN} -bdir ${BUILDDIR} -fdir ${BUILDDIR} -simdir ${BUILDDIR} -vdir ${BUILDDIR}

bdpiMem.o: ../xram/bdpiMem.cpp
	g++ -O3 -c ../xram/bdpiMem.cpp -o bdpiMem.o

TestPrioQueue: PrioQueue.bsv TestPrioQueue.bsv bdpiMem.o
	rm -f *.bo *.ba ../xram/*.bo ../xram/*.ba && bsc -p "+:../xram" -check-assert -aggressive-conditions -show-schedule -D WITH_BLUESIM -sim -g mkTestPrioQueue -u TestPrioQueue.bsv && bsc -p "+:../xram" -sim -e mkTestPrioQueue -Xl bdpiMem.o && (./a.out | python3 CheckPrioQueue.py)

clean:
	rm -rf build/*.so
	rm -rf build/*.bo
	rm -rf build/*.v
	rm -f *.sched
	rm -f *.so
	rm -f *.bo
	rm -f *.v
	mkdir -p build

