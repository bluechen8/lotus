
INCLUDEPATHS = .:%:%/Libraries:../utils/
BSC_SEARCH = -p ${INCLUDEPATHS}

BUILDDIR = ./build

BUILDFLAGS = ${DEBUG_EN} -bdir ${BUILDDIR} -fdir ${BUILDDIR} -simdir ${BUILDDIR} -vdir ${BUILDDIR}

sim:
	mkdir -p ${BUILDDIR}
	bsc $(BSC_SEARCH) -check-assert -aggressive-conditions -show-schedule ${BUILDFLAGS} -sim -g mkTestSwitch -u Switch.bsv
	bsc -sim -e mkTestSwitch ${BUILDFLAGS} -o ${BUILDDIR}/sim_switch
	${BUILDDIR}/sim_switch

sim2:
	mkdir -p ${BUILDDIR}
	bsc $(BSC_SEARCH) -check-assert -aggressive-conditions -show-schedule ${BUILDFLAGS} -sim -g mkTestPSwitch -u Switch.bsv
	bsc -sim -e mkTestPSwitch ${BUILDFLAGS} -o ${BUILDDIR}/sim_switch
	${BUILDDIR}/sim_switch
