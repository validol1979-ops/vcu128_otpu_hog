# Thermal monitor (src/thermal): SYSMON placement and its clock-domain crossings.
# Unmanaged Tcl, implementation only (Top/otpu/list/sources.con, nosynth), after vcu128_cdc.tcl.
# doc/design.md "Температура и контроль".

# One SYSMONE4 per SLR, instance s in SLR s: the System Management Wizard's placement for
# virtexuplusHBM (master SYSMONE4_X0Y0 in SLR0, slaves X0Y1, X0Y2).
for {set s 0} {$s < 3} {incr s} {
    set c [get_cells -quiet -hier -filter "NAME =~ *u_sysmon/g_sm\[$s\].u_sysmon && REF_NAME == SYSMONE4"]
    if {[llength $c] != 1} {
        puts "CRITICAL WARNING: \[vcu128_thermal.tcl\] SYSMONE4 of SLR $s not found: [llength $c] cells"
        continue
    }
    set_property LOC SYSMONE4_X0Y$s $c
}

proc vcu128_th_cells {pattern} {
    set c [get_cells -quiet -hier -filter "NAME =~ $pattern"]
    if {[llength $c] == 0} {
        puts "CRITICAL WARNING: \[vcu128_thermal.tcl\] no cells '$pattern': crossing unconstrained"
    }
    return $c
}

# Two-flop synchronizers (clk100 -> core_clk): the snapshot toggle and the SYSMON OT outputs
foreach p {u_plat/u_thermal/tog_s1_reg* u_plat/u_thermal/ot_s1_reg*} {
    set c [vcu128_th_cells $p]
    if {[llength $c]} { set_property ASYNC_REG TRUE $c; set_false_path -to $c }
}

# The snapshot (clk100) is captured in core_clk >= 2 cycles after its toggle, and holds for
# a whole PERIOD (1 ms): bound the bus skew to one clk100 period instead of timing it as a
# synchronous path between the related clocks.
set from [vcu128_th_cells {u_sysmon/u_drp/snap*_reg*}]
set to   [vcu128_th_cells {u_plat/u_thermal/cap_*_reg*}]
if {[llength $from] && [llength $to]} {
    set_max_delay -datapath_only -from $from -to $to 10.000
}
