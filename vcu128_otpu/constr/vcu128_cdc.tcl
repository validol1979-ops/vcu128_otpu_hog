# Clock-domain crossings of otpu_vcu128_top outside otpu_mem_ch and axil_cdc.
# Unmanaged Tcl, implementation only, read late (Top/otpu/list/sources.con), after:
#   src/otpu-fesens/boards/ypcb-00338/constraints/otpu_mem_ch.tcl (scoped to otpu_mem_ch:
#     native <-> uclk <-> xclk, as upstream does on the BCU1525),
#   src/lib/verilog-axi/syn/vivado/axil_cdc.tcl (the 40G bridge's AXI-Lite into core_clk).
# As upstream (boards/bcu1525/constraints/bcu1525_top.tcl): no clock pair is declared
# asynchronous, which would take priority over otpu_mem_ch's set_max_delay -datapath_only.
# Clocks: core_clk (200 MHz), uclk and clk100 (HBM APB, l_ethernet dclk) from one MMCM
# (related), eth_clk (l_ethernet tx_clk_out),
# the HBM and GT internals (IP constraints).

proc vcu128_sync_to {pattern} {
    set c [get_cells -quiet -hier -filter "NAME =~ $pattern"]
    if {[llength $c] == 0} {
        puts "CRITICAL WARNING: \[vcu128_cdc.tcl\] no cells '$pattern': crossing unconstrained"
        return
    }
    set_property ASYNC_REG TRUE $c
    set_false_path -to $c
}

# Two-flop synchronizers of quasi-static or single-bit signals: the first stage.
vcu128_sync_to {u_plat/s1_reg*}          ;# platform status (HBM, 40G, QSFP, locks)
vcu128_sync_to {link_s1_reg*}            ;# 40G status into eth_clk (eth40_regs LINK)
vcu128_sync_to {led_s1_reg*}             ;# HBM status into core_clk (LEDs)
vcu128_sync_to {calib_u1_reg*}           ;# HBM calibration (APB clock) into uclk
vcu128_sync_to {u_eth_mgmt/rx_sync_reg[0]} ;# stat_rx_status into core_clk
vcu128_sync_to {u_sys/u_board/cal_s1_reg*} ;# HBM calibration (APB clk100) into core_clk (otpu_board)

# Reset synchronizers released after the MMCM lock (asynchronous assertion)
foreach r {core_rst_sync_reg* u_rst_sync_reg* r100_rst_sync_reg*} {
    set c [get_cells -quiet -hier -filter "NAME =~ $r"]
    if {[llength $c]} { set_false_path -to [get_pins -of_objects $c -filter {REF_PIN_NAME == PRE || REF_PIN_NAME == CLR}] }
}

# The 40G management in core_clk drives l_ethernet's resets (asynchronous inputs of the
# IP's own synchronizers; eth40_core_reset's xpm_cdc_async_rst for the MAC/PCS).
set c [get_cells -quiet -hier -filter {NAME =~ u_eth_mgmt/sys_reset_reg || NAME =~ u_eth_mgmt/rx_dp_reset_reg}]
if {[llength $c]} { set_false_path -from $c }
