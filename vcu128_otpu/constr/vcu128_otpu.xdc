# VCU128 Rev1.0 (xcvu37p-fsvh2892-2L-e): openTPU, HBM2, 40G Ethernet on QSFP1.
# Pins from the VCU128 master XDC (Sources and documents/vcu128/helper/vcu128_Rev1.0_.xdc)
# and UG1302. Clock-domain crossings: constr/vcu128_cdc.tcl (late, implementation only).

# Fabric clocks: QDR4_CLK_100MHZ (U96, SiT9120 100 MHz), bank 69 -> MMCM (core_clk, uclk)
set_property PACKAGE_PIN BJ4 [get_ports QDR4_CLK_100MHZ_P]
set_property PACKAGE_PIN BK3 [get_ports QDR4_CLK_100MHZ_N]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {QDR4_CLK_100MHZ_P QDR4_CLK_100MHZ_N}]
create_clock -name sys_clk100 -period 10.000 [get_ports QDR4_CLK_100MHZ_P]

# HBM reference: DDR4_CLK_100MHZ (U76, "HBM/DDR4 component memory clock"), bank 66
set_property PACKAGE_PIN BH51 [get_ports DDR4_CLK_100MHZ_P]
set_property PACKAGE_PIN BJ51 [get_ports DDR4_CLK_100MHZ_N]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {DDR4_CLK_100MHZ_P DDR4_CLK_100MHZ_N}]
create_clock -name hbm_ref_clk -period 10.000 [get_ports DDR4_CLK_100MHZ_P]

# CPU_RESET (SW4), active high
set_property PACKAGE_PIN BM29 [get_ports CPU_RESET]
set_property IOSTANDARD LVCMOS12 [get_ports CPU_RESET]
set_false_path -from [get_ports CPU_RESET]

# User LEDs, bank 67
set_property PACKAGE_PIN BH24 [get_ports {GPIO_LED[0]}]
set_property PACKAGE_PIN BG24 [get_ports {GPIO_LED[1]}]
set_property PACKAGE_PIN BG25 [get_ports {GPIO_LED[2]}]
set_property PACKAGE_PIN BF25 [get_ports {GPIO_LED[3]}]
set_property PACKAGE_PIN BF26 [get_ports {GPIO_LED[4]}]
set_property PACKAGE_PIN BF27 [get_ports {GPIO_LED[5]}]
set_property PACKAGE_PIN BG27 [get_ports {GPIO_LED[6]}]
set_property PACKAGE_PIN BG28 [get_ports {GPIO_LED[7]}]
set_property IOSTANDARD LVCMOS18 [get_ports {GPIO_LED[*]}]
set_false_path -to [get_ports {GPIO_LED[*]}]

# QSFP1: GTY quad 135 (Quad_X0Y11, lanes X0Y44..47; placed by eth40_qsfp1's GT_LOC),
# reference MGTREFCLK0_135 from Si570 U95 (156.25 MHz default)
set_property PACKAGE_PIN P42 [get_ports QSFP1_SI570_CLOCK_P]
set_property PACKAGE_PIN P43 [get_ports QSFP1_SI570_CLOCK_N]
# the clock on QSFP1_SI570_CLOCK_P is created by eth40_qsfp1 (156.25 MHz)
set_property PACKAGE_PIN G53 [get_ports {QSFP1_RX_P[0]}]
set_property PACKAGE_PIN F51 [get_ports {QSFP1_RX_P[1]}]
set_property PACKAGE_PIN E53 [get_ports {QSFP1_RX_P[2]}]
set_property PACKAGE_PIN D51 [get_ports {QSFP1_RX_P[3]}]
set_property PACKAGE_PIN G48 [get_ports {QSFP1_TX_P[0]}]
set_property PACKAGE_PIN E48 [get_ports {QSFP1_TX_P[1]}]
set_property PACKAGE_PIN C48 [get_ports {QSFP1_TX_P[2]}]
set_property PACKAGE_PIN A49 [get_ports {QSFP1_TX_P[3]}]

# QSFP1 sideband, bank 67: RESETL high, LPMODE low, MODSKLL low (module selected)
set_property PACKAGE_PIN BN25 [get_ports QSFP1_RESETL_LS]
set_property PACKAGE_PIN BN24 [get_ports QSFP1_LPMODE_LS]
set_property PACKAGE_PIN BM24 [get_ports QSFP1_MODSKLL_LS]
set_property PACKAGE_PIN BM25 [get_ports QSFP1_MODPRSL_LS]
set_property PACKAGE_PIN BP24 [get_ports QSFP1_INTL_LS]
set_property IOSTANDARD LVCMOS18 [get_ports {QSFP1_RESETL_LS QSFP1_LPMODE_LS QSFP1_MODSKLL_LS QSFP1_MODPRSL_LS QSFP1_INTL_LS}]
set_false_path -to [get_ports {QSFP1_RESETL_LS QSFP1_LPMODE_LS QSFP1_MODSKLL_LS}]
set_false_path -from [get_ports {QSFP1_MODPRSL_LS QSFP1_INTL_LS}]

# Configuration: QSPI MT25QU02G (x4, 32-bit address), as vcu128_opentpu_hog
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 31.9 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.CONFIG.OVERTEMPSHUTDOWN Enable [current_design]
# Unused pins float: a pull-down held the 1G PHY in power-down in vcu128_opentpu_hog
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
