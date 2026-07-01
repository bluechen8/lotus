test_sip:
	xvlog --sv sip.sv test_sip.sv && xelab TestSIP -debug all -R

test_sip_bsv:
	make -C ../utils sipnet
	xvlog ../utils/mkTestSIPNet.v
	xvlog -d TEST_SIP_BSV --sv ../xram/XRegFile.sv sip.sv test_sip.sv && xelab TestSIP -debug all -R

VIVADO_DATA_DIR = $$(dirname $$(dirname $$(which vivado)))/data/

test_sip_cdc:
	xvlog --sv sip_cdc.sv test_sip_cdc.sv $(VIVADO_DATA_DIR)/verilog/src/glbl.v && xelab -L xpm TestSIPCDC glbl -debug all -R
