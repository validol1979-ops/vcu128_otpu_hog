# SLR floorplan of the VCU128 build at S = 2 and S = 4 (layout L2; after upstream boards/bcu1525/constraints/
# bcu1525_floorplan.tcl, which its author marks unverified). Unmanaged Tcl, implementation only,
# read late (Top/otpu/list/sources.con). At S = 1 there is no g_slice[1] / g_xs: nothing to place.
#
# The xcvu37p's three SLRs: HBM (both stacks, all AXI ports) at the bottom edge of SLR0, QSFP1
# (GTY quad 135, X0Y44..47) in SLR2. Slice 0, the shell (control block, collective unit, trace)
# and every channel's otpu_mem_ch (its uclk side at 225 MHz meets the HBM ports) in SLR0; slice 1
# in SLR1. The 40G MAC and the bridge (eth_clk) are left to the placer (near the GTs in SLR2);
# their DMA reaches the otpu_mem_ch xclk sides and the AXI-Lite crosses into core_clk through
# axil_cdc, as at S = 1.
#
# What crosses SLR0 <-> SLR1 (core_clk):
#   - slice 1's channels 2 and 3: the native port through two otpu_native_reg (otpu_bcu_sys SLL =
#     4'b1100): u_tx with the slice in SLR1, u_rx with otpu_mem_ch in SLR0;
#   - slice 1's control / status / collective (otpu_board g_xs.g_x[1]): u_dn_tx, u_up_rx with the
#     shell in SLR0, u_dn_rx, u_up_tx, u_cport with the slice in SLR1 (otpu_xr, flop to flop).
# Laguna registers (USER_SLL_REG): the plain D flip-flops on both sides of the crossings (the
# native ports' read data, write count, error; the otpu_xr stages). The skid buffers' output
# registers (u_tx/u_cmd, u_wd m_data: a clock enable from across the SLR) are left to the placer.
proc vcu128_pb {name slr cells} {
  set found {}
  foreach c $cells {
    set x [get_cells -quiet $c]
    if {[llength $x]} { lappend found $x } else {
      puts "CRITICAL WARNING: \[vcu128_floorplan.tcl\] $name: no cell $c"
    }
  }
  set pb [create_pblock $name]
  resize_pblock $pb -add $slr
  if {[llength $found]} { add_cells_to_pblock $pb [join $found] }
  puts "vcu128_floorplan.tcl: $name in $slr, [llength $found] of [llength $cells] cells"
}

# The 40G front end (eth_clk) in SLR1, its DMA's last register stage in pb_slr0 (S > 1)
proc vcu128_eth_front {} {
  # The 40G front end (eth_clk, 312.5 MHz) in SLR1, next to QSFP1's GT (quad 135, SLR2): build A
  # (f666116) left it unconstrained and Vivado split l_ethernet and otpu_eth_bridge between SLR1 and
  # SLR0 (towards HBM): txoutclk WNS -0.280 ns, every failing path an SLR crossing without registers
  # (u_filt/len_ok -> u_rxq URAM, l_ethernet inside). In SLR1: l_ethernet's logic (not the GT
  # channels, their BUFG_GT and the reference buffer, fixed in SLR2), the bridge, eth40_regs, the
  # reset synchronizer and vcu128_xreg's first stage; its last stage goes to SLR0 with the channels,
  # so the crossing is register to register (two axi_register stages, both skid buffers).
  set eth [get_cells -quiet -hierarchical -filter {NAME =~ u_eth40/* && IS_PRIMITIVE && \
    PRIMITIVE_GROUP != ADVANCED && REF_NAME !~ BUFG_GT* && REF_NAME !~ IBUFDS_GTE*}]
  set pb [create_pblock pb_eth]
  resize_pblock $pb -add SLR1
  if {[llength $eth]} { add_cells_to_pblock $pb $eth } else {
    puts "CRITICAL WARNING: \[vcu128_floorplan.tcl\] pb_eth: no l_ethernet cells"
  }
  set front {}
  foreach c [list u_bridge u_eth_regs u_eth_core_rst {u_xreg/g_ch[*].g_st[0].u_reg}] {
    set x [get_cells -quiet $c]
    if {[llength $x]} { set front [concat $front $x] } else {
      puts "CRITICAL WARNING: \[vcu128_floorplan.tcl\] pb_eth: no cell $c"
    }
  }
  if {[llength $front]} { add_cells_to_pblock $pb $front }
  puts "vcu128_floorplan.tcl: pb_eth in SLR1, [llength $eth] l_ethernet cells, [llength $front] blocks"
  set last [get_cells -quiet {u_xreg/g_ch[*].g_st[1].u_reg}]
  if {[llength $last]} { add_cells_to_pblock [get_pblocks pb_slr0] $last } else {
    puts "CRITICAL WARNING: \[vcu128_floorplan.tcl\] vcu128_xreg: no last stage"
  }
}

if {[llength [get_cells -quiet {u_sys/u_board/g_slice[1].u_slice}]] == 0} {
  puts "vcu128_floorplan.tcl: one slice, no floorplan"
} elseif {[llength [get_cells -quiet {u_sys/u_board/g_slice[3].u_slice}]]} {
  # ---- S = 4, layout L2 (build B, 22.10: L1 = slices 0, 1 in SLR1 left 8 channels across SLR0/1
  # and 4 through SLR1: long-line congestion level 6 in SLR1, WNS -0.83). The SLR of each slice
  # and of the shell (control block, collective, trace, slice crossings' shell side, 40G front);
  # HBM and every channel's otpu_mem_ch / otpu_hbm_port / u_rx in SLR0. otpu_vcu128_top's SLL /
  # SLL2 must match: a channel crosses when its slice is not in SLR0, twice (u_mid in SLR1) from
  # SLR2. Checked below against the netlist (g_sll / g_mid present).
  set slr_of {0 0 1 1 2 1 3 2}         ;# slice -> SLR
  set shell 1
  set b  u_sys/u_board
  set xs u_sys/u_board/g_xs
  set cells {0 {} 1 {} 2 {}}
  proc vcu128_add {var slr c} { upvar $var cl; dict lappend cl $slr $c }
  for {set j 0} {$j < 8} {incr j} {
    vcu128_add cells 0 "u_sys/g_ch\[$j\].u_ch"
    vcu128_add cells 0 "g_hbm\[$j\].u_port"
  }
  vcu128_add cells $shell $b/u_ctrl
  vcu128_add cells $shell $b/u_iso
  vcu128_add cells $shell $b/g_coll.u_coll
  vcu128_add cells $shell $b/g_trace.u_trace
  vcu128_add cells $shell "$xs.u_chub"
  set laguna {}
  for {set s 0} {$s < 4} {incr s} {
    set r [dict get $slr_of $s]
    if {$s == 0} { set sl $b/u_slice; set sm $b/u_mem } else {
      set sl "$b/g_slice\[$s\].u_slice"; set sm "$b/g_slice\[$s\].u_mem" }
    vcu128_add cells $r $sl
    vcu128_add cells $r $sm
    foreach c {u_dn_rx u_up_tx u_cport} { vcu128_add cells $r "$xs.g_x\[$s\].$c" }
    foreach c {u_dn_tx u_up_rx} { vcu128_add cells $shell "$xs.g_x\[$s\].$c" }
    if {$r != $shell} {
      foreach c {u_dn_tx u_dn_rx u_up_tx u_up_rx} { lappend laguna "$xs.g_x\[$s\].$c/r_reg*" }
    }
    foreach j [list [expr {2 * $s}] [expr {2 * $s + 1}]] {
      set sll  [llength [get_cells -quiet "u_sys/g_ch\[$j\].g_sll.u_tx"]]
      set sll2 [llength [get_cells -quiet "u_sys/g_ch\[$j\].g_sll.g_mid.u_mid"]]
      if {$sll != ($r > 0) || $sll2 != ($r > 1)} {
        puts "CRITICAL WARNING: \[vcu128_floorplan.tcl\] channel $j: SLL $sll / SLL2 $sll2 do not match slice $s in SLR$r (otpu_vcu128_top)"
      }
      if {$r > 0} {
        vcu128_add cells $r "u_sys/g_ch\[$j\].g_sll.u_tx"
        vcu128_add cells 0 "u_sys/g_ch\[$j\].g_sll.u_rx"
        foreach u {u_rx u_tx} { foreach g {s_rdata_reg* s_wdone_reg* s_err_reg} {
          lappend laguna "u_sys/g_ch\[$j\].g_sll.$u/$g" } }
      }
      if {$r > 1} { vcu128_add cells 1 "u_sys/g_ch\[$j\].g_sll.g_mid.u_mid" }
    }
  }
  foreach r {0 1 2} { vcu128_pb pb_slr$r SLR$r [dict get $cells $r] }
  vcu128_eth_front
  set lc [get_cells -quiet $laguna]
  if {[llength $lc]} { set_property USER_SLL_REG TRUE $lc }
  puts "vcu128_floorplan.tcl: S = 4 layout L2 (slices $slr_of, shell SLR$shell), [llength $lc] Laguna registers"
} else {
  set b  u_sys/u_board
  set xs u_sys/u_board/g_xs
  vcu128_pb pb_slr0 SLR0 [list $b/u_slice $b/u_mem $b/u_ctrl $b/u_iso $b/g_coll.u_coll \
    $b/g_trace.u_trace "$xs.u_chub" \
    "$xs.g_x\[0\].u_dn_tx" "$xs.g_x\[0\].u_dn_rx" "$xs.g_x\[0\].u_up_tx" "$xs.g_x\[0\].u_up_rx" \
    "$xs.g_x\[0\].u_cport" "$xs.g_x\[0\].g_pf.u_pf_tx" "$xs.g_x\[0\].g_pf.u_pf_rx" \
    "$xs.g_x\[1\].u_dn_tx" "$xs.g_x\[1\].u_up_rx" \
    {u_sys/g_ch[0].u_ch} {u_sys/g_ch[1].u_ch} {u_sys/g_ch[2].u_ch} {u_sys/g_ch[3].u_ch} \
    {u_sys/g_ch[2].g_sll.u_rx} {u_sys/g_ch[3].g_sll.u_rx} \
    {g_hbm[0].u_port} {g_hbm[1].u_port} {g_hbm[2].u_port} {g_hbm[3].u_port}]
  vcu128_pb pb_slice1 SLR1 [list "$b/g_slice\[1\].u_slice" "$b/g_slice\[1\].u_mem" \
    "$xs.g_x\[1\].u_dn_rx" "$xs.g_x\[1\].u_up_tx" "$xs.g_x\[1\].u_cport" \
    {u_sys/g_ch[2].g_sll.u_tx} {u_sys/g_ch[3].g_sll.u_tx}]

  vcu128_eth_front

  foreach j {2 3} {
    set sll {}
    foreach pat [list "u_sys/g_ch\[$j\].g_sll.u_rx/s_rdata_reg*" "u_sys/g_ch\[$j\].g_sll.u_rx/s_wdone_reg*" \
                 "u_sys/g_ch\[$j\].g_sll.u_rx/s_err_reg" "u_sys/g_ch\[$j\].g_sll.u_tx/s_rdata_reg*" \
                 "u_sys/g_ch\[$j\].g_sll.u_tx/s_wdone_reg*" "u_sys/g_ch\[$j\].g_sll.u_tx/s_err_reg"] {
      set sll [concat $sll [get_cells -quiet $pat]]
    }
    if {[llength $sll]} {
      set_property USER_SLL_REG TRUE $sll
      puts "vcu128_floorplan.tcl: channel $j, [llength $sll] Laguna registers"
    } else {
      puts "CRITICAL WARNING: \[vcu128_floorplan.tcl\] channel $j: no crossing registers found"
    }
  }
  set sll [get_cells -quiet [list "$xs.g_x\[1\].u_dn_tx/r_reg*" "$xs.g_x\[1\].u_dn_rx/r_reg*" \
                                  "$xs.g_x\[1\].u_up_tx/r_reg*" "$xs.g_x\[1\].u_up_rx/r_reg*"]]
  if {[llength $sll]} {
    set_property USER_SLL_REG TRUE $sll
    puts "vcu128_floorplan.tcl: slice 1's control / status / collective, [llength $sll] Laguna registers"
  } else {
    puts "CRITICAL WARNING: \[vcu128_floorplan.tcl\] slice 1: no crossing registers found"
  }
}
