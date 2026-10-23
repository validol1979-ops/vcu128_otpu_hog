# Термоконтроль VCU128 по JTAG-to-AXI (без 40G): температура SLR и HBM, пороги, флаги;
# для сравнения — SYSMON глазами hw_manager (get_hw_sysmons). Регистры — окно 0x40000,
# 0x20..0x5C (doc/design.md «Температура и контроль»), как tools/otpu_temp.py.
#
#   vivado -mode batch -nolog -nojournal -source vcu128_otpu/tools/jtag/thermal.tcl \
#       [-tclargs <команда> ...]
# Команды (по умолчанию report):
#   report                  одно чтение
#   watch <с> [<раз>]       опрос с интервалом
#   limits fpga|hbm <warn> <alarm> <hyst>
#   ctrl <TH_CTRL>          запись TH_CTRL как есть (биты: 0 ACT_EN, 1 AUTO_RESUME, 2 CATTRIP_ACT,
#                           3 FORCE_HOLD; W1: 8 RESUME, 9 сброс защёлок, 10 сброс максимумов)
#   resume | clear | clearmax   то же с текущими битами 0..3
# Окружение: HW_SERVER (localhost:3121), JTAG_TARGET (подстрока имени цели), OTPU_LTX (файл
# .ltx сборки, необязателен: JTAG-to-AXI находится и без него).

set P 0x40000

proc find_vcu128 {} {
    set url localhost:3121
    if {[info exists ::env(HW_SERVER)]} { set url $::env(HW_SERVER) }
    open_hw_manager
    connect_hw_server -url $url
    set want ""
    if {[info exists ::env(JTAG_TARGET)]} { set want $::env(JTAG_TARGET) }
    foreach t [get_hw_targets] {
        if {$want ne "" && [string first $want $t] < 0} { continue }
        current_hw_target $t
        if {![get_property IS_OPENED $t]} {
            if {[catch {open_hw_target $t} err]} { puts "skip $t: $err"; catch {close_hw_target $t}; continue }
        }
        set dev [lindex [get_hw_devices -quiet -of_objects $t xcvu37p*] 0]
        if {$dev ne ""} { puts "VCU128: $t / $dev"; current_hw_device $dev; return $dev }
        catch {close_hw_target $t}
    }
    error "xcvu37p не найден: питание платы, кабель USB JTAG, hw_server ($url)"
}

proc axi_rd {ax addr} {
    delete_hw_axi_txn -quiet [get_hw_axi_txns -quiet -of_objects $ax]
    create_hw_axi_txn -quiet rd_t $ax -type READ -address [format %08x $addr] -len 1
    run_hw_axi -quiet rd_t
    return [expr {"0x[get_property DATA [get_hw_axi_txns rd_t]]" + 0}]
}

proc axi_wr {ax addr val} {
    delete_hw_axi_txn -quiet [get_hw_axi_txns -quiet -of_objects $ax]
    create_hw_axi_txn -quiet wr_t $ax -type WRITE -address [format %08x $addr] -len 1 \
        -data [format %08x $val]
    run_hw_axi -quiet wr_t
}

proc q4 {v} {
    set v [expr {$v & 0xFFFF}]
    if {$v == 0x8000} { return "   —  " }
    if {$v & 0x8000} { set v [expr {$v - 0x10000}] }
    return [format %6.2f [expr {$v / 16.0}]]
}

proc th_report {ax} {
    global P
    set info [axi_rd $ax [expr {$P + 0x20}]]
    if {!(($info >> 16) & 1)} { puts [format "TH_INFO 0x%08x: термоконтроля в битстриме нет" $info]; return }
    set st   [axi_rd $ax [expr {$P + 0x28}]]
    set ctl  [axi_rd $ax [expr {$P + 0x24}]]
    set fl   [axi_rd $ax [expr {$P + 0x2C}]]
    set hl   [axi_rd $ax [expr {$P + 0x30}]]
    set ev   [axi_rd $ax [expr {$P + 0x34}]]
    set raw  [axi_rd $ax [expr {$P + 0x38}]]
    set ab   [axi_rd $ax [expr {$P + 0x3C}]]
    set hbm  [axi_rd $ax [expr {$P + 0x4C}]]
    set names {WARN ALARM CATTRIP HOLD WARN_L ALARM_L CATTRIP_L HOLD_L COOL VALID DRP_ERR}
    set fl_s {}
    for {set i 0} {$i < 11} {incr i} { if {($st >> $i) & 1} { lappend fl_s [lindex $names $i] } }
    puts [format "TH_STATUS 0x%08x  %s  (WARN по датчикам 0x%02x, ALARM 0x%02x: SLR0 SLR1 SLR2 HBM0 HBM1)" \
        $st [join $fl_s " "] [expr {($st >> 16) & 0x1F}] [expr {($st >> 24) & 0x1F}]]
    puts [format "TH_CTRL   0x%08x  ACT_EN %d AUTO_RESUME %d CATTRIP_ACT %d FORCE_HOLD %d" $ctl \
        [expr {$ctl & 1}] [expr {($ctl >> 1) & 1}] [expr {($ctl >> 2) & 1}] [expr {($ctl >> 3) & 1}]]
    for {set s 0} {$s < 3} {incr s} {
        set t [axi_rd $ax [expr {$P + 0x40 + 4 * $s}]]
        set v [axi_rd $ax [expr {$P + 0x50 + 4 * $s}]]
        puts [format "SLR%d  %s °C  max %s   VCCINT %.3f  VCCAUX %.3f  VCCBRAM %.3f В%s" $s \
            [q4 $t] [q4 [expr {$t >> 16}]] [expr {($v & 0x3FF) * 3.0 / 1024}] \
            [expr {(($v >> 10) & 0x3FF) * 3.0 / 1024}] [expr {(($v >> 20) & 0x3FF) * 3.0 / 1024}] \
            [expr {(($raw >> (16 + $s)) & 1) ? "  OT!" : ""}]]
    }
    puts [format "HBM0  %d °C max %d   HBM1  %d °C max %d" [expr {$hbm & 0xFF}] \
        [expr {($hbm >> 16) & 0xFF}] [expr {($hbm >> 8) & 0xFF}] [expr {($hbm >> 24) & 0xFF}]]
    puts [format "пороги ПЛИС %d/%d гист. %d, HBM %d/%d гист. %d; удержаний %d, CTRL=0 %d, предупреждений %d" \
        [expr {$fl & 0xFF}] [expr {($fl >> 8) & 0xFF}] [expr {($fl >> 16) & 0xFF}] \
        [expr {$hl & 0xFF}] [expr {($hl >> 8) & 0xFF}] [expr {($hl >> 16) & 0xFF}] \
        [expr {$ev & 0xFFFF}] [expr {$ab & 0xFFFF}] [expr {$ev >> 16}]]
    set code [expr {$raw & 0xFFF}]
    puts [format "R_TEMP code 0x%03x = %.2f °C (UltraScale+: code x 509.314 / 4096 - 280.231)" $code \
        [expr {$code * 509.3140064 / 4096 - 280.2308787}]]
}

proc sysmon_report {} {
    # hw_manager's view of the SYSMON (JTAG; the master SLR's, plus the slaves' if Vivado lists them)
    foreach sm [get_hw_sysmons -quiet] {
        if {[catch {refresh_hw_sysmon $sm}]} { continue }
        puts [format "hw_sysmon %s: TEMPERATURE %s °C, VCCINT %s, VCCAUX %s, VCCBRAM %s" $sm \
            [get_property TEMPERATURE $sm] [get_property VCCINT $sm] [get_property VCCAUX $sm] \
            [get_property VCCBRAM $sm]]
    }
}

set dev [find_vcu128]
if {[info exists ::env(OTPU_LTX)]} { set_property PROBES.FILE $::env(OTPU_LTX) $dev }
refresh_hw_device -quiet $dev
set ax [lindex [get_hw_axis -quiet] 0]
if {$ax eq ""} { error "JTAG-to-AXI не найден: плата не прошита битстримом otpu?" }

set cmd [lindex $argv 0]
if {$cmd eq ""} { set cmd report }
switch -- $cmd {
    report { th_report $ax; sysmon_report }
    watch {
        set dt [lindex $argv 1]; if {$dt eq ""} { set dt 2 }
        set n [lindex $argv 2];  if {$n eq ""} { set n 0 }
        for {set k 0} {$n == 0 || $k < $n} {incr k} {
            puts "---- [clock format [clock seconds] -format %H:%M:%S]"
            th_report $ax
            after [expr {int($dt * 1000)}]
        }
    }
    limits {
        lassign [lrange $argv 1 4] which w a h
        set off [expr {$which eq "hbm" ? 0x30 : 0x2C}]
        if {!($w <= $a && $a < 125 && $h < $a)} { error "нужно warn <= alarm < 125, hyst < alarm" }
        axi_wr $ax [expr {$P + $off}] [expr {($h << 16) | ($a << 8) | $w}]
        th_report $ax
    }
    ctrl { axi_wr $ax [expr {$P + 0x24}] [expr {[lindex $argv 1]}]; th_report $ax }
    resume - clear - clearmax {
        set cur [expr {[axi_rd $ax [expr {$P + 0x24}]] & 0xF}]
        set bit [dict get {resume 0x100 clear 0x200 clearmax 0x400} $cmd]
        axi_wr $ax [expr {$P + 0x24}] [expr {$cur | $bit}]
        th_report $ax
    }
    default { error "команда: report | watch | limits | ctrl | resume | clear | clearmax" }
}
close_hw_manager
