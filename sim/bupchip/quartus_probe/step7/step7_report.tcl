# quartus_sta -t step7_report.tcl: the step-7 timing report (run_step7.sh;
# docs/daria_step7/plan.md 5.4). Run in the compiled project's directory,
# after step7_prep.py has written step7_prep.txt there.
#
# Every check first lists the cells and registers it works on. An empty
# collection is a failure ("no such cell"), except for the chains that plan
# 2.7 marks absent from this kind of build, whose absence is the expected
# result. Writes:
#   timing.txt     worst setup and hold slack per clock at each corner, the
#                  clock table, clk_arm's internal Fmax, and the endpoint
#                  counts between clock pairs
#   checks.txt     one block per check: "CHECK <id> PASS|FAIL|INFO: ...",
#                  with the collections and figures
#   crossings.tsv  every clk_sys <-> clk_arm path pair: direction, setup and
#                  hold relationship and slack, logic levels, from, to
#   fanin.tsv      every timed path into each first flop of plan 2.7 that is
#                  present, from any clock: the register it starts at, its
#                  clock, the logic levels ((k'): one register in the whole
#                  fan-in, P21)
#   sdram_worst.tsv the 20 worst clk_sdram setup paths at the worse slow
#                  corner, for 5.3's classification
#   exceptions.rpt, sdc.rpt, metastability.rpt, datasheet.rpt,
#   cross.rpt, guard.rpt, fixb.rpt
# step7_checks.py reads these and the compile's reports and gives the
# verdicts per kind of build.
#
# (a), (l) and (h) are judged here by plan 5.4's rules as first written, the
# threshold printed on (h)'s line included. step7_checks.py reads the figures
# this script writes for them, the per-corner pd_tog -> pd_rx lines, the
# corner list, timing.txt and (h)'s lines, and judges them again by the
# build's divider: plan 5.4 as amended 2026-10-14 at VCO/19 (the guard pair's
# setup slack reported, not gated, in (a) and left out of (l); (h) at +3.0
# ns), as first written at any other. Keep those lines' format.
#
# The guard pair's bounds ((a), (b), (k); step7_checks.py's (e)) are not
# fixed here: they are read from the SDC the fit was made with, as the
# Timing Analyzer read it (report_sdc, sdc.rpt), and must be one of the
# known pairs of guard_pairs below (plan 5.4 as amended for G1, 2026-10-19;
# the amendment is docs/daria_step10/plan.md section 10).
# The bounds used are written to checks.txt ("# guard bounds: ..."), and
# step7_checks.py judges (a), (b) and (k) again by sdc.rpt's bounds from the
# per-corner pd_tog -> pd_rx lines and crossings.tsv. A report written before
# this change held the pair to 6 / 1 ns whatever the SDC said.

project_open ap_core
# "post_map" as an argument: the netlist after synthesis only (a smoke test
# of this script on a small project, without a fit).
if {[lsearch -exact $quartus(args) post_map] >= 0} {
	create_timing_netlist -post_map
} else {
	create_timing_netlist
}
read_sdc
update_timing_netlist

# ---- the build ---------------------------------------------------------------------------
array set prep {kind daria daria 1 bup_debug 0 fixb 1 div 18}
if {[file exists step7_prep.txt]} {
	set fh [open step7_prep.txt]
	foreach line [split [read $fh] "\n"] {
		if {[llength $line] == 2} { set prep([lindex $line 0]) [lindex $line 1] }
	}
	close $fh
}
set kind $prep(kind)

set pre {ic|pll|altera_pll_i|cyclonev_pll|counter[}
set post {].output_counter|divclk}
set clk_names {0 clk_sys 1 clk_sdram 2 clk_sys_90 3 clk_arm}

set out [open "checks.txt" w]
puts $out "# step7_report.tcl: kind $kind, DARIA $prep(daria), BUP_DEBUG $prep(bup_debug), Fix B $prep(fixb), clk_arm VCO/$prep(div)"

proc say {line} {
	global out
	puts $out $line
}
proc check {id verdict text} {
	say "CHECK $id $verdict: $text"
}
# A section runs at global level; a Tcl error in it fails every check the
# section reports (ids), so that a check that never ran cannot pass, and the
# report goes on. step7_checks.py also fails a gating check that is missing.
proc section {id ids body} {
	if {[catch {uplevel #0 $body} err]} {
		foreach i $ids {
			check $i FAIL "Tcl error in the report script, section $id: [string map {"\n" " | "} $err]"
		}
	}
}
proc names {coll {max 40}} {
	set l {}
	set n 0
	foreach_in_collection c $coll {
		if {$n < $max} { lappend l [get_node_info -name $c] }
		incr n
	}
	if {$n > $max} { lappend l "... ($n in all)" }
	return $l
}
proc csize {coll} {
	set n 0
	foreach_in_collection c $coll { incr n }
	return $n
}
# Registers by pattern, listed; returns the collection (empty: the caller decides).
proc regs {label pattern {nodup 0}} {
	if {$nodup} {
		set c [get_registers -nowarn -no_duplicates $pattern]
	} else {
		set c [get_registers -nowarn $pattern]
	}
	set n [csize $c]
	say "  $label: $n register(s) for {$pattern}"
	foreach x [names $c 12] { say "    $x" }
	return $c
}

# The synchroniser table of plan 2.7, and the guard's receiver. Columns:
# pattern, present in Build B (daria), present in Q5 (DARIA + BUP_DEBUG).
# f3_crossings.txt holds the same presence per kind (selftest.sh compares
# the two). cap_err_a is absent from Q5 too: it feeds only the status
# word's bit 11, which bup_status_osd.sv does not show (plan 2.7).
set ff_table {
	{*|bupchip_pocket:bupchip|hold_a[0]} 1 1
	{*|bupchip_pocket:bupchip|pause_a[0]} 0 0
	{*|bupchip_pocket:bupchip|prof_a[0]} 1 1
	{*|bupchip_pocket:bupchip|ram32_a[0]} 1 1
	{*|bupchip_pocket:bupchip|mres_a[0]} 1 1
	{*|bupchip_pocket:bupchip|cmd_s[0]} 1 1
	{*|daria_call:call|tog_s[0]} 1 1
	{*|daria_mmio:mmio|sn_a[0]} 1 1
	{*|bup_asset_wr:writer|t1} 1 1
	{*|daria_smp:*|req_s0} 1 1
	{*|bup_dbg_snap:*|rq_s0} 0 1
	{*|bupchip_pocket:bupchip|cap_err_a[0]} 0 0
	{*|bupchip_pocket:bupchip|ready_s[0]} 1 1
	{*|bupchip_pocket:bupchip|halted_s[0]} 0 0
	{*|bupchip_pocket:bupchip|run_s[0]} 1 1
	{*|bupchip_pocket:bupchip|ftog_s[0]} 1 1
	{*|daria_mmio:mmio|en_s[0]} 1 1
	{*|daria_mmio:mmio|w_s[0]} 1 1
	{*|daria_fe_call:u_call|ret_s1} 1 1
	{*|daria_fe_audio:u_audio|ack_s1} 1 1
	{*|bup_dbg_snap:*|ak_s0} 0 1
	{*|daria_fe_guard:u_guard|pd_rx} 1 1
}

# The known bounds of the guard pair pd_tog -> pd_rx (docs/daria_fe/design.md
# 8.1-8.2; plan 5.4 (a), (b), (e), (k)). Columns: the Timing Analyzer's
# set_max_delay and set_min_delay (ns), the fitter-only set_max_delay of
# daria_constraints.sdc's quartus_fit block (ns), and the pair's name.
#   first  design.md 8.2 as first written: 6 ns (a toggle launched 8.73 ns
#          before a clk_sys edge is caught there), 1 ns (the toggle launched
#          on the shared edge is never caught on it); fitter 5.5 (618b5c3).
#   G1     [0.5, 8.0] ns, fitter 7.5 (docs/daria_step10/plan.md: G1 in its
#          summary, and section 10; Rev 0, 2026-10-19): 6 ns counted the skew and setup twice, since the
#          Timing Analyzer's check already holds them, so 8.0 keeps 0.73 ns
#          and 0.5 keeps 0.5 ns of margin beyond the corner models at VCO/18.
# The bounds are absolute: neither pair belongs to a divider. A pair not in
# this table fails (a), (b), (k) and (e), so that reading the SDC cannot let
# a stray value judge itself. step7_checks.py reads this table (the tree's).
set guard_pairs {
	{6.000 1.000 5.500 first}
	{8.000 0.500 7.500 G1}
}

set slow_corners {}
set all_corners [get_available_operating_conditions]
foreach c $all_corners { if {[string match -nocase "*slow*" $c]} { lappend slow_corners $c } }
say "# corners: $all_corners"

# ---- timing.txt, and the clock table (part of (l)) ------------------------------------------------
section l {l.clocks l gate.clk_sdram gate.clk_arm gate.hold} {
set tf [open "timing.txt" w]
set exp_period [dict create 0 69.841 1 17.460 2 69.841 3 [expr {$prep(div) == 19 ? 27.645 : ($prep(div) == 24 ? 34.920 : 26.190)}]]
set clocks_ok 1
foreach {n label} $clk_names {
	set c [get_clocks -nowarn "$pre$n$post"]
	if {[csize $c] != 1} {
		set clocks_ok 0
		say "  no clock $pre$n$post ($label)"
		continue
	}
	set per [get_clock_info -period $c]
	set want [dict get $exp_period $n]
	if {abs($per - $want) > 0.01} { set clocks_ok 0 }
	puts $tf [format "clock %-10s %-66s period %.3f (expected %.3f)" $label "$pre$n$post" $per $want]
}
check "l.clocks" [expr {$clocks_ok ? "PASS" : "FAIL"}] "the four PLL clocks exist under the SDC's names with the expected periods (clk_arm VCO/$prep(div))"

array set worst_setup {}
array set worst_hold {}
set other_clocks {}
foreach cond $all_corners {
	set_operating_conditions $cond
	update_timing_netlist
	puts $tf "== $cond"
	foreach {n label} $clk_names {
		set clk [get_clocks -nowarn "$pre$n$post"]
		set ss "-"
		set hs "-"
		foreach_in_collection p [get_timing_paths -setup -to_clock $clk -npaths 1] { set ss [format "%.3f" [get_path_info $p -slack]] }
		foreach_in_collection p [get_timing_paths -hold -to_clock $clk -npaths 1] { set hs [format "%.3f" [get_path_info $p -slack]] }
		set worst_setup($cond,$label) $ss
		set worst_hold($cond,$label) $hs
		puts $tf [format "  %-10s setup %8s  hold %8s" $label $ss $hs]
	}
	# every other clock (clk_74a, clk_74b, bridge_spiclk, ...)
	foreach_in_collection clk [get_clocks *] {
		set cn [get_clock_info -name $clk]
		if {[string first $pre $cn] == 0} { continue }
		set ss "-"
		set hs "-"
		foreach_in_collection p [get_timing_paths -setup -to_clock $clk -npaths 1] { set ss [format "%.3f" [get_path_info $p -slack]] }
		foreach_in_collection p [get_timing_paths -hold -to_clock $clk -npaths 1] { set hs [format "%.3f" [get_path_info $p -slack]] }
		set worst_setup($cond,$cn) $ss
		set worst_hold($cond,$cn) $hs
		lappend other_clocks $cn
		puts $tf [format "  %-10s setup %8s  hold %8s" $cn $ss $hs]
	}
	set arm [get_clocks -nowarn "${pre}3$post"]
	foreach_in_collection p [get_timing_paths -setup -from_clock $arm -to_clock $arm -npaths 1] {
		set per [get_clock_info -period $arm]
		set sl [get_path_info $p -slack]
		puts $tf [format "  clk_arm internal: period %.3f, slack %.3f, Fmax %.2f MHz, %d levels, %s -> %s" \
			$per $sl [expr {1000.0 / ($per - $sl)}] [get_path_info $p -num_logic_levels] \
			[get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]]]
	}
}

# (l): setup and hold at every corner, for every clock; the gates at the
# worse slow corner.
set other_clocks [lsort -unique $other_clocks]
set every_clock {}
foreach {n label} $clk_names { lappend every_clock $n $label }
foreach cn $other_clocks { lappend every_clock - $cn }
set l_ok 1
foreach cond $all_corners {
	foreach {n label} $every_clock {
		foreach kindk {setup hold} {
			if {$kindk eq "setup"} { set v $worst_setup($cond,$label) } else { set v $worst_hold($cond,$label) }
			if {$v ne "-" && $v < 0} {
				set l_ok 0
				say "  $label $kindk slack $v at $cond"
			}
		}
	}
}
check "l" [expr {$l_ok ? "PASS" : "FAIL"}] "setup and hold slack >= 0 for every clock at every corner"
proc worse_slow {label} {
	global slow_corners worst_setup
	set w ""
	foreach c $slow_corners {
		set v $worst_setup($c,$label)
		if {$v eq "-"} { continue }
		if {$w eq "" || $v < $w} { set w $v }
	}
	return $w
}
set sd [worse_slow clk_sdram]
check "gate.clk_sdram" [expr {$sd ne "" && $sd >= 1.5 ? "PASS" : "FAIL"}] "clk_sdram worst setup at the worse slow corner: $sd ns (gate +1.5 ns, plan 5.3)"
set ar [worse_slow clk_arm]
check "gate.clk_arm" [expr {$ar ne "" && $ar >= 0 ? "PASS" : "FAIL"}] "clk_arm worst setup at the worse slow corner: $ar ns (gate >= 0, plan 5.2)"
set wh ""
foreach cond $all_corners {
	foreach {n label} $every_clock {
		set v $worst_hold($cond,$label)
		if {$v ne "-" && ($wh eq "" || $v < $wh)} { set wh $v }
	}
}
check "gate.hold" [expr {$wh ne "" && $wh > 0 ? "PASS" : "FAIL"}] "worst hold over every clock and corner: $wh ns (> 0)"

# Everything below at the worse slow corner for setup (the corner with the
# smaller clk_sdram setup slack), and every corner for hold where it says so.
set wcond [lindex $slow_corners 0]
foreach c $slow_corners {
	if {$worst_setup($c,clk_sdram) ne "-" && $worst_setup($c,clk_sdram) < $worst_setup($wcond,clk_sdram)} { set wcond $c }
}
set_operating_conditions $wcond
update_timing_netlist
say "# setup checks below at $wcond"
set sys [get_clocks -nowarn "${pre}0$post"]
set sdram [get_clocks -nowarn "${pre}1$post"]
set sys90 [get_clocks -nowarn "${pre}2$post"]
set arm [get_clocks -nowarn "${pre}3$post"]

}
# ---- the guard pair's bounds, from the SDC as the Timing Analyzer read it -------------------------------
# report_sdc lists every constraint applied (the fitter-only block of
# daria_constraints.sdc is not: it runs under quartus_fit alone). The pair's
# bounds are its one set_max_delay and one set_min_delay from pd_tog to
# pd_rx; they must be a row of guard_pairs. Otherwise guard_set stays empty,
# guard_why says why, and (a), (b) and (k) fail on it. A Tcl error here
# leaves the same. step7_checks.py reads sdc.rpt the same way.
proc guard_bounds {pairs} {
	report_sdc -file sdc.rpt
	set fh [open sdc.rpt]
	set lines [split [read $fh] "\n"]
	close $fh
	set maxv {}
	set minv {}
	set maxi {}
	set mini {}
	foreach line $lines {
		set cols {}
		foreach c [split [string trim [string trim $line] ";"] ";"] { lappend cols [string trim $c] }
		set cmd [lindex $cols 0]
		if {$cmd ne "set_max_delay" && $cmd ne "set_min_delay"} { continue }
		set ti [lsearch -exact $cols "-to"]
		if {$ti < 1} { continue }
		set fr [join [lrange $cols 1 [expr {$ti - 1}]] " "]
		if {![string match "*u_guard|pd_tog*" $fr] || ![string match "*u_guard|pd_rx*" [lindex $cols [expr {$ti + 1}]]]} { continue }
		set v [lindex $cols [expr {$ti + 2}]]
		set item "$v at [lindex $cols [expr {$ti + 3}]]"
		if {$cmd eq "set_max_delay"} { lappend maxv $v; lappend maxi $item } else { lappend minv $v; lappend mini $item }
	}
	if {$maxi eq ""} { set maxi none }
	if {$mini eq ""} { set mini none }
	set seen "set_max_delay [join $maxi {, }]; set_min_delay [join $mini {, }]"
	if {[llength $maxv] != 1 || [llength $minv] != 1} {
		return [list "" "" "" "sdc.rpt has [llength $maxv] set_max_delay and [llength $minv] set_min_delay from pd_tog to pd_rx, not one of each ($seen)"]
	}
	set s [lindex $maxv 0]
	set h [lindex $minv 0]
	if {[string is double -strict $s] && [string is double -strict $h]} {
		foreach p $pairs {
			lassign $p ps ph pf pn
			if {abs($s - $ps) < 0.0005 && abs($h - $ph) < 0.0005} { return [list $ps $ph $pn "sdc.rpt: $seen"] }
		}
	}
	return [list "" "" "" "the SDC's pair (setup $s, hold $h ns) is not one of the known pairs ($pairs); sdc.rpt: $seen"]
}
if {[catch {lassign [guard_bounds $guard_pairs] guard_set guard_hold guard_name guard_why} err]} {
	set guard_set ""
	set guard_hold ""
	set guard_name ""
	set guard_why "Tcl error while reading the bounds from sdc.rpt: [string map {"\n" " | "} $err]"
}
if {$guard_set ne ""} {
	say "# guard bounds: setup $guard_set hold $guard_hold ($guard_name; $guard_why)"
} else {
	say "# guard bounds: none ($guard_why)"
}

# ---- (a), (b), (d): the guard pair ---------------------------------------------------------------------
section ab {a b d} {
say "\n## (a) (b) (d) the guard pair pd_tog -> pd_rx (design.md 8.2)"
set g_tog [regs "pd_tog" {*|daria_fe_guard:u_guard|pd_tog}]
set g_rx [regs "pd_rx" {*|daria_fe_guard:u_guard|pd_rx}]
if {[csize $g_tog] == 0 || [csize $g_rx] == 0} {
	check "a" FAIL "no such cell: pd_tog or pd_rx"
	check "b" FAIL "no such cell: pd_tog or pd_rx"
	check "d" FAIL "no such cell: pd_tog or pd_rx"
} else {
	# Without known bounds the figures are still listed (step7_checks.py
	# reads them), and (a) and (b) fail.
	set a_ok [expr {$guard_set ne ""}]
	set b_ok $a_ok
	foreach cond $all_corners {
		set_operating_conditions $cond
		update_timing_netlist
		foreach {which want} [list setup $guard_set hold $guard_hold] {
			set n 0
			set txt ""
			foreach_in_collection p [get_timing_paths -$which -from $g_tog -to $g_rx -npaths 10 -nworst 10] {
				incr n
				set rel [get_path_info $p -clock_relationship]
				set sl [get_path_info $p -slack]
				set sk [get_path_info $p -clock_skew]
				set dd [get_path_info $p -data_delay]
				append txt [format " rel %.3f slack %.3f skew %.3f data %.3f;" $rel $sl $sk $dd]
				if {$want eq "" || abs($rel - $want) > 0.0005 || $sl < 0} { if {$which eq "setup"} { set a_ok 0 } else { set b_ok 0 } }
			}
			if {$n != 1} { if {$which eq "setup"} { set a_ok 0 } else { set b_ok 0 } }
			say "  $cond $which: $n path(s);$txt"
		}
	}
	set_operating_conditions $wcond
	update_timing_netlist
	report_timing -setup -from $g_tog -to $g_rx -npaths 10 -detail full_path -file guard.rpt
	report_timing -hold -from $g_tog -to $g_rx -npaths 10 -detail full_path -append -file guard.rpt
	if {$guard_set ne ""} {
		check "a" [expr {$a_ok ? "PASS" : "FAIL"}] "exactly one setup path pd_tog -> pd_rx at every corner, relationship $guard_set ns (the SDC's, $guard_name), met"
		check "b" [expr {$b_ok ? "PASS" : "FAIL"}] "exactly one hold path pd_tog -> pd_rx at every corner, relationship $guard_hold ns (the SDC's, $guard_name), met"
	} else {
		check "a" FAIL "the guard pair's bounds are not known: $guard_why"
		check "b" FAIL "the guard pair's bounds are not known: $guard_why"
	}
	check "d" INFO "the clock skew on pd_tog -> pd_rx is listed per corner above (skew)"
}

}
# ---- (c) and (f) in part: the first flops present or absent ------------------------------------------------
section c.cells {c.cells} {
say "\n## (c) (f) the first flops of plan 2.7 (registers without duplicates)"
set ff_ok 1
set ffl [open "firstflops.tsv" w]
foreach {pat inb inq5} $ff_table {
	# A build without DARIA is held to Build B's column: its DARIA-only first
	# flops then report "no such cell", a failure (the vacuity guard).
	set want [expr {$kind eq "q5" ? $inq5 : $inb}]
	set c [get_registers -nowarn -no_duplicates $pat]
	set n [csize $c]
	set all [csize [get_registers -nowarn "${pat}*"]]
	set st "ok"
	if {$want && $n != 1} { set st "MISSING (no such cell)"; set ff_ok 0 }
	if {!$want && $n != 0} { set st "PRESENT but plan 2.7 marks it absent here"; set ff_ok 0 }
	say [format "  %-48s expected %s, found %d (with duplicates and suffixes %d): %s" $pat [expr {$want ? "present" : "absent"}] $n $all $st]
	puts $ffl "$pat\t$want\t$n\t$all"
}
close $ffl
check "c.cells" [expr {$ff_ok ? "PASS" : "FAIL"}] "each first flop of plan 2.7 is present or absent as the table says for kind $kind (the netlist-optimization part of (c) is in step7_checks.py)"

}
# ---- (e): the SDC and the exceptions -------------------------------------------------------------------------
section e {e.files e} {
say "\n## (e) report_sdc, report_exceptions (status parsed by step7_checks.py)"
# sdc.rpt is written above, where the guard pair's bounds are read from it.
if {![file exists sdc.rpt]} { report_sdc -file sdc.rpt }
report_sdc -ignored -file sdc_ignored.rpt
report_exceptions -file exceptions.rpt
check "e.files" INFO "sdc.rpt, sdc_ignored.rpt and exceptions.rpt written; step7_checks.py checks the statuses and the guard pair's bounds"

}
# ---- (f): metastability -----------------------------------------------------------------------------------------
section f {f.files f} {
report_metastability -nchains 100000 -file metastability.rpt
check "f.files" INFO "metastability.rpt written (every chain); step7_checks.py checks the Forced first flops"

}
# ---- (g), (h), (i): Fix B --------------------------------------------------------------------------------------
section g {g g.legs} {
say "\n## (g) no cart2600 path into sram_ctrl or the SRAM pads except through sram|t_*_q"
# Nets are named by instance path alone (ic|atari|main|cart2600|...).
set c26 [get_nets -nowarn {*|cart2600|*}]
set n26 [csize $c26]
say "  nets in cart2600 (*|cart2600|*): $n26"
foreach x [names $c26 8] { say "    $x" }
# The 2600 data leg by top.sv's own net names. Synthesis can fold cart2600's
# output mux into LUTs named in top.sv, so a path through cart2600's logic
# need not cross a net named *|cart2600|*: on aeee6d2 (Q0 seed 2)
# maria_en_out -> the 7800 cart's POKEY read select -> main|read_DB~98,
# ~135, ~136 -> main|cart_din[5]~30 -> sram|dq_out[5] had none, and on
# Build A (Q1 seed 2) c_rdata -> main|cart|dout[0]~42 -> main|read_DB~113,
# ~114 -> main|cart_din[0]~39 -> t_wdata_q has none either. read_DB (the
# 6507's read bus) reaches sram_ctrl only through cart_din, the 2600 slot's
# data input, so a path through it may end in sram_ctrl only at t_wdata_q.
# The cart_din nets themselves are no filter: synthesis named a shared bus
# decode LUT main|cart_din[0]~0 (Q1 seed 2), which lies on the 7800 strobe
# path maria_en_out -> cs_ram0 -> ... -> cartram_rd -> sram_a.
set rdb [get_nets -nowarn {*|main|read_DB*}]
say "  nets of top.sv's read_DB (*|main|read_DB*): [csize $rdb]"
foreach x [names $rdb 4] { say "    $x" }
set c26r [regs "cart2600's registers" {*|cart2600:cart2600|*}]
set sram_all [regs "sram_ctrl's registers" {*|sram_ctrl:sram|*}]
set tq [regs "sram|t_*_q" {*|sram_ctrl:sram|t_*_q*}]
# remove_from_collection fails (a warning, and no removal) when the second
# collection is empty, as it is on a tree without Fix B.
set sram_end [expr {[csize $tq] > 0 ? [remove_from_collection $sram_all $tq] : $sram_all}]
set pads [get_ports -nowarn {sram_a[*] sram_dq[*] sram_oe_n sram_we_n sram_ub_n sram_lb_n}]
say "  sram_ctrl registers: [csize $sram_all], of them t_*_q: [csize $tq]; SRAM pads: [csize $pads] (outputs with no output delay: their pad registers are sram_ctrl's)"
foreach x [names $pads 6] { say "    $x" }
if {$n26 == 0 || [csize $rdb] == 0 || [csize $sram_all] == 0} {
	check "g" FAIL "no such cell: cart2600's nets, top.sv's read_DB nets or sram_ctrl's registers"
} else {
	set ng 0
	set gf [open fixb.rpt w]
	close $gf
	foreach {lab coll} [list "sram_ctrl registers (not t_*_q)" $sram_end "SRAM pads" $pads] {
		if {[csize $coll] == 0} { continue }
		set n 0
		foreach_in_collection p [get_timing_paths -setup -through $c26 -to $coll -npaths 100000 -pairs_only] {
			if {$n < 10} {
				say [format "    %s: slack %.3f %d levels %s -> %s" $lab [get_path_info $p -slack] [get_path_info $p -num_logic_levels] \
					[get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]]]
			}
			incr n
		}
		say "  paths through cart2600 into $lab: $n"
		incr ng $n
		# Of these, the ones that start at a cart2600 register (plan 5.4 (g):
		# "from cart2600 cells"); the count above also takes in paths that
		# pass through cart2600's logic from outside it.
		set nr 0
		if {[csize $c26r] > 0} {
			foreach_in_collection p [get_timing_paths -setup -from $c26r -to $coll -npaths 100000 -pairs_only] {
				if {$nr < 10} {
					say [format "    from a cart2600 register into %s: slack %.3f %d levels %s -> %s" $lab [get_path_info $p -slack] \
						[get_path_info $p -num_logic_levels] [get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]]]
				}
				incr nr
			}
		}
		say "  of them from cart2600's registers into $lab: $nr"
		# the data leg by top.sv's names (above): counted as well
		set nd 0
		foreach_in_collection p [get_timing_paths -setup -through $rdb -to $coll -npaths 100000 -pairs_only] {
			if {$nd < 10} {
				say [format "    through read_DB into %s: slack %.3f %d levels %s -> %s" $lab [get_path_info $p -slack] \
					[get_path_info $p -num_logic_levels] [get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]]]
			}
			incr nd
		}
		say "  paths through top.sv's read_DB into $lab: $nd"
		incr ng $nd
		if {$n > 0} { report_timing -setup -through $c26 -to $coll -npaths 20 -detail full_path -append -file fixb.rpt }
		if {$nd > 0} { report_timing -setup -through $rdb -to $coll -npaths 10 -detail full_path -append -file fixb.rpt }
	}
	set nch 0
	set wch ""
	set sdr [get_registers -nowarn {*|sdram:sdram|*}]
	if {[csize $sdr] > 0} {
		foreach_in_collection p [get_timing_paths -setup -through $c26 -to $sdr -npaths 100000 -pairs_only] {
			incr nch
			set v [get_path_info $p -slack]
			if {$wch eq "" || $v < $wch} { set wch $v }
		}
	}
	say "  (reported apart) paths through cart2600 into sdram's registers ([csize $sdr]), the ch0_* legs: $nch, worst setup $wch"
	set nt 0
	if {[csize $tq] > 0} {
		foreach_in_collection p [get_timing_paths -setup -through $c26 -to $tq -npaths 100000 -pairs_only] { incr nt }
	}
	say "  paths through cart2600 into sram|t_*_q (allowed): $nt"
	check "g" [expr {$ng == 0 ? "PASS" : "FAIL"}] "$ng path(s) from cart2600 (through its nets, from its registers, or through top.sv's read_DB) into sram_ctrl or the SRAM pads other than through t_*_q (on aeee6d2, Q0, this must find the merged request's paths: the negative control)"
}
# g.legs: each leg of the 2600 request (address, strobe, data) reaches its
# t_*_q group from the 2600 side, so that (g)'s zero is not vacuous; and
# c_rdata -> read_DB -> cart_din -> t_wdata_q is timed under the c_rdata
# multicycle (core_constraints.sdc: -setup 2 into clk_sys).
say "\n## (g.legs) the address, strobe and data legs into sram|t_*_q, and c_rdata -> t_wdata_q"
if {[csize $tq] == 0} {
	check "g.legs" FAIL "no such cell: sram|t_*_q"
} else {
	set legs_ok 1
	set lsum {}
	foreach {leg pat} {address {*|sram_ctrl:sram|t_addr_q*} strobe {*|sram_ctrl:sram|t_rd_q* *|sram_ctrl:sram|t_wr_q*} data {*|sram_ctrl:sram|t_wdata_q*}} {
		set lc [get_registers -nowarn $pat]
		if {[csize $lc] == 0} {
			set legs_ok 0
			say "  $leg: no such cell {$pat}"
			lappend lsum "$leg: no such cell"
			continue
		}
		set n 0
		set w ""
		array unset ends
		foreach th [list $c26 $rdb] {
			foreach_in_collection p [get_timing_paths -setup -through $th -to $lc -npaths 100000 -pairs_only] {
				incr n
				set ends([get_node_info -name [get_path_info $p -to]]) 1
				set v [get_path_info $p -slack]
				if {$w eq "" || $v < $w} { set w $v }
			}
		}
		set nr 0
		if {[csize $c26r] > 0} {
			foreach_in_collection p [get_timing_paths -setup -from $c26r -to $lc -npaths 100000 -pairs_only] { incr nr }
		}
		say "  $leg: [csize $lc] register(s), [array size ends] reached through cart2600 or read_DB; $n path pair(s), $nr from cart2600's registers; worst setup $w"
		lappend lsum "$leg [array size ends]/[csize $lc] reached, worst $w"
		if {$n == 0 || [array size ends] == 0} { set legs_ok 0 }
	}
	set cr [get_registers -nowarn {*|sram_ctrl:sram|c_rdata[*]}]
	set twd [get_registers -nowarn {*|sram_ctrl:sram|t_wdata_q*}]
	set ncr 0
	set crs ""
	set crel ""
	set clv ""
	if {[csize $cr] > 0 && [csize $twd] > 0} {
		foreach_in_collection p [get_timing_paths -setup -from $cr -to $twd -npaths 100000 -pairs_only] { incr ncr }
		foreach_in_collection p [get_timing_paths -setup -from $cr -to $twd -npaths 1] {
			set crs [get_path_info $p -slack]
			set crel [get_path_info $p -clock_relationship]
			set clv [get_path_info $p -num_logic_levels]
		}
		set ncd 0
		foreach_in_collection p [get_timing_paths -setup -from $cr -through $rdb -to $twd -npaths 100000 -pairs_only] { incr ncd }
		say "  c_rdata -> t_wdata_q: $ncr pair(s), $ncd of them through read_DB; worst setup $crs ns, relationship $crel ns, $clv levels"
		report_timing -setup -from $cr -to $twd -npaths 2 -detail full_path -append -file fixb.rpt
	}
	# The multicycle moves the latch one clk_sys later: the relationship
	# exceeds a clk_sys period (one clk_sdram plus one clk_sys).
	set psys [get_clock_info -period $sys]
	set mc_ok [expr {$ncr > 0 && $crel ne "" && $crel > $psys}]
	if {!$mc_ok} { set legs_ok 0 }
	check "g.legs" [expr {$legs_ok ? "PASS" : "FAIL"}] "[join $lsum {; }]; c_rdata -> t_wdata_q $ncr pair(s), relationship $crel ns (> one clk_sys, $psys: the multicycle), worst setup $crs ns"
}

}
section h {h} {
say "\n## (h) Fix B checks 2-4: t_*_q"
if {[csize $tq] == 0} {
	check "h" FAIL "no such cell: sram|t_*_q"
} else {
	set h_ok 1
	set ws ""
	foreach_in_collection p [get_timing_paths -setup -from $tq -to_clock $sdram -npaths 1] { set ws [get_path_info $p -slack]; set wl [get_path_info $p -num_logic_levels] }
	set wi ""
	foreach_in_collection p [get_timing_paths -setup -to $tq -npaths 1] { set wi [get_path_info $p -slack] }
	set whh ""
	foreach cond $all_corners {
		set_operating_conditions $cond
		update_timing_netlist
		foreach_in_collection p [get_timing_paths -hold -from $tq -to_clock $sdram -npaths 1] {
			set v [get_path_info $p -slack]
			if {$whh eq "" || $v < $whh} { set whh $v }
		}
	}
	set_operating_conditions $wcond
	update_timing_netlist
	if {$ws eq "" || $ws < 4.5} { set h_ok 0 }
	if {$whh eq "" || $whh < 0} { set h_ok 0 }
	if {$wi eq "" || $wi < 40.0} { set h_ok 0 }
	say "  t_*_q -> clk_sdram: worst setup $ws ns ([expr {$ws eq "" ? "-" : $wl}] levels, >= +4.5), worst hold over corners $whh ns (>= 0)"
	say "  into t_*_q: worst setup $wi ns (>= +40)"
	check "h" [expr {$h_ok ? "PASS" : "FAIL"}] "t_*_q -> clk_sdram setup $ws / hold $whh, into t_*_q $wi (retiming into cart2600: step7_checks.py)"
}

}
section i {i} {
say "\n## (i) open item 12"
set cr [regs "c_rdata" {*|sram_ctrl:sram|c_rdata[*]}]
set fb [regs "fbn_*" {*|sram_ctrl:sram|fbn_*}]
set padr [get_registers -nowarn {*|sram_ctrl:sram|sram_a* *|sram_ctrl:sram|dq_out* *|sram_ctrl:sram|sram_ub_n* *|sram_ctrl:sram|sram_lb_n* *|sram_ctrl:sram|sram_oe_n* *|sram_ctrl:sram|sram_we_n* *|sram_ctrl:sram|dq_oe*}]
if {[csize $cr] == 0 || [csize $fb] == 0 || [csize $padr] == 0} {
	check "i" FAIL "no such cell: sram|c_rdata, sram|fbn_* or the SRAM pad registers"
} else {
	# c_rdata -> clk_sys is the multicycle (its slack is open item 12's
	# figure); c_rdata -> clk_sdram (sdram's write data, through read_DB and
	# cart_din) is a plain one-period path and is listed apart. Flicker
	# Blend: into fbn_* (the falling-edge capture, half a period), and
	# fbn_* -> the pad registers.
	foreach cond $all_corners {
		set_operating_conditions $cond
		update_timing_netlist
		set l "  $cond:"
		foreach {lab a} [list "c_rdata->clk_sys (multicycle)" [list -from $cr -to_clock $sys] "c_rdata->clk_sdram" [list -from $cr -to_clock $sdram] \
				"into fbn_*" [list -to $fb] "fbn_*->pad registers" [list -from $fb -to $padr]] {
			foreach w {setup hold} {
				set v "-"
				foreach_in_collection p [eval get_timing_paths -$w $a -npaths 1] {
					set v [format "%.3f (rel %.3f)" [get_path_info $p -slack] [get_path_info $p -clock_relationship]]
				}
				append l " $lab $w $v;"
			}
		}
		say $l
	}
	set_operating_conditions $wcond
	update_timing_netlist
	check "i" INFO "c_rdata's multicycle slack (c_rdata -> clk_sys), c_rdata -> clk_sdram apart, and Flicker Blend's fbn_* slack (into fbn_*, fbn_* -> the pad registers) per corner, above"
}

}
# ---- (j), (k), (k'): the crossings ----------------------------------------------------------------------------
section j {j} {
say "\n## (j) tripwire: clk_arm <-> clk_sdram, clk_arm <-> clk_sys_90"
set nj 0
foreach {label from to} [list "arm->sdram" $arm $sdram "sdram->arm" $sdram $arm "arm->sys90" $arm $sys90 "sys90->arm" $sys90 $arm] {
	set n 0
	foreach_in_collection p [get_timing_paths -setup -from_clock $from -to_clock $to -npaths 100000 -pairs_only] { incr n }
	say "  $label: $n path(s)"
	incr nj $n
}
check "j" [expr {$nj == 0 ? "PASS" : "FAIL"}] "$nj path(s) between clk_arm and clk_sdram or clk_sys_90"

}
section k {k k'.files k'} {
say "\n## (k) (k') clk_sys <-> clk_arm"
set ct [open "crossings.tsv" w]
puts $ct "dir\tsetup_rel\tsetup_slack\thold_rel\thold_slack\tlevels\tfrom\tto"
set k_ok 1
set nk 0
foreach {dir from to} [list s2a $sys $arm a2s $arm $sys] {
	array unset hold_of
	foreach_in_collection p [get_timing_paths -hold -from_clock $from -to_clock $to -npaths 1000000 -pairs_only] {
		set key "[get_node_info -name [get_path_info $p -from]]\t[get_node_info -name [get_path_info $p -to]]"
		set hold_of($key) [list [get_path_info $p -clock_relationship] [get_path_info $p -slack]]
	}
	set n 0
	set ws ""
	foreach_in_collection p [get_timing_paths -setup -from_clock $from -to_clock $to -npaths 1000000 -pairs_only] {
		set f [get_node_info -name [get_path_info $p -from]]
		set t [get_node_info -name [get_path_info $p -to]]
		set rel [get_path_info $p -clock_relationship]
		set sl [get_path_info $p -slack]
		set lv [get_path_info $p -num_logic_levels]
		set key "$f\t$t"
		if {[info exists hold_of($key)]} { lassign $hold_of($key) hrel hsl } else { set hrel "-"; set hsl "-" }
		puts $ct [format "%s\t%.3f\t%.3f\t%s\t%s\t%d\t%s\t%s" $dir $rel $sl $hrel $hsl $lv $f $t]
		# The guard pair by the registers' own names: a duplicate the router
		# made ("pd_tog~DUPLICATE", "pd_rx~DUPLICATE") is matched by the SDC's
		# get_registers patterns as well, so its paths carry the guard's bounds
		# and are judged against them here; (a), (b) and (c) fail the duplicate.
		# The bounds are the SDC's (guard_set / guard_hold, above).
		regsub {~DUPLICATE\S*$} $f "" f0
		regsub {~DUPLICATE\S*$} $t "" t0
		set guard [expr {[string match {*|daria_fe_guard:u_guard|pd_tog} $f0] && [string match {*|daria_fe_guard:u_guard|pd_rx} $t0]}]
		if {$guard && $guard_set eq ""} {
			set k_ok 0
			say "  $dir: $f -> $t setup rel $rel, hold rel $hrel (the guard pair's bounds are not known)"
		} else {
			set wr [expr {$guard ? $guard_set : 20.0}]
			set wrh [expr {$guard ? $guard_hold : -20.0}]
			if {abs($rel - $wr) > 0.0005 || $hrel eq "-" || abs($hrel - $wrh) > 0.0005} {
				set k_ok 0
				say "  $dir: $f -> $t setup rel $rel, hold rel $hrel (expected $wr / $wrh)"
			}
		}
		if {$ws eq "" || $sl < $ws} { set ws $sl }
		incr n
	}
	say "  $dir: $n path pairs, worst setup slack $ws"
	incr nk $n
	report_timing -setup -from_clock $from -to_clock $to -npaths 10 -detail full_path -append -file cross.rpt
	report_timing -hold -from_clock $from -to_clock $to -npaths 10 -detail summary -append -file cross.rpt
}
close $ct
if {$nk == 0} {
	check "k" FAIL "no clk_sys <-> clk_arm path at all"
} elseif {$guard_set eq ""} {
	check "k" FAIL "the guard pair's bounds are not known: $guard_why ($nk pairs; crossings.tsv)"
} else {
	check "k" [expr {$k_ok ? "PASS" : "FAIL"}] "every clk_sys <-> clk_arm path pair has the 20 / -20 ns relationship, pd_tog -> pd_rx $guard_set / $guard_hold ns (the SDC's, $guard_name) ($nk pairs; crossings.tsv)"
}
check "k'.files" INFO "crossings.tsv written; step7_checks.py compares its endpoints with plan F3's list (f3_crossings.txt) and checks each first flop's source"

}
section kfan {k'} {
# P21 as 5.4 (k') checks it: a first flop's whole fan-in is one register,
# from the other clock (one more, of its own clock, for a synchronous reset).
# The logic levels are listed but not judged: Quartus puts a NOT gate before
# an inverted register (a power-up value of 1) and the router can insert a
# routing cell, each with one input, which cannot glitch.
say "\n## (k') the fan-in of each first flop, from any clock (fanin.tsv)"
set ff [open "fanin.tsv" w]
puts $ff "pattern\tto\tto_clock\tfrom\tfrom_clock\tlevels\tslack"
proc clkname {c} {
	if {[catch {get_clock_info -name $c} n] || $n eq ""} { return "-" }
	return $n
}
foreach {pat inb inq5} $ff_table {
	set rc [get_registers -nowarn $pat]
	if {[csize $rc] == 0} { continue }
	array unset seen_to
	foreach_in_collection p [get_timing_paths -setup -to $rc -npaths 1000000 -pairs_only] {
		set tn [get_node_info -name [get_path_info $p -to]]
		set seen_to($tn) 1
		puts $ff [format "%s\t%s\t%s\t%s\t%s\t%d\t%.3f" $pat $tn [clkname [get_path_info $p -to_clock]] \
			[get_node_info -name [get_path_info $p -from]] [clkname [get_path_info $p -from_clock]] \
			[get_path_info $p -num_logic_levels] [get_path_info $p -slack]]
	}
	foreach_in_collection r $rc {
		set tn [get_node_info -name $r]
		if {![info exists seen_to($tn)]} { puts $ff "$pat\t$tn\t-\t-\t-\t-\t-" }
	}
}
close $ff
check "k'.fanin" INFO "fanin.tsv written; step7_checks.py checks that each first flop's fan-in is one register of the other clock"

}
# ---- the 20 worst clk_sdram paths, for 5.3 ----------------------------------------------------------------------
section sdram {sdram.files} {
set sw [open "sdram_worst.tsv" w]
puts $sw "slack\tlevels\tfrom_clock\tfrom\tto"
foreach_in_collection p [get_timing_paths -setup -to_clock $sdram -npaths 20 -nworst 1] {
	puts $sw [format "%.3f\t%d\t%s\t%s\t%s" [get_path_info $p -slack] [get_path_info $p -num_logic_levels] \
		[get_clock_info -name [get_path_info $p -from_clock]] [get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]]]
}
close $sw
report_timing -setup -to_clock $sdram -npaths 20 -nworst 1 -detail full_path -file sdram_worst.rpt

}
# ---- (p) the sample requester's chain (plan 2.2): psram -> cache / daria_smp -> psram, clk_arm ------------------------
section p {p} {
# Synthesis folds rx and rd_req into the writer's psram_read_en LUT (Q0: the
# chain's worst path is read_avail -> writer|psram_read_en -> psram's
# registers, 3 levels, with no cache net on it), so the chain is found from
# psram's read_avail through the writer's psram_read_en net, not through the
# cache's nets.
say "\n## (p) psram_read_avail -> rx -> rd_req -> psram_read_en (plan 2.2)"
set ps [regs "psram's registers" {*|psram:bup_psram|*}]
set ra [regs "psram's read_avail" {*|psram:bup_psram|read_avail}]
set en [get_nets -nowarn {*|bupchip|writer|psram_read_en}]
say "  the writer's psram_read_en net (*|bupchip|writer|psram_read_en): [csize $en]"
set smpn [get_nets -nowarn {*|bupchip|smp|*}]
say "  daria_smp's nets (*|bupchip|smp|*): [csize $smpn]"
if {[csize $ps] == 0 || [csize $ra] == 0 || [csize $en] == 0} {
	check "p" FAIL "no such cell: psram:bup_psram's registers, its read_avail, or the writer's psram_read_en net"
} else {
	set v ""
	set lv "-"
	foreach_in_collection p [get_timing_paths -setup -from $ra -through $en -to $ps -npaths 1] {
		set v [format "%.3f" [get_path_info $p -slack]]
		set lv [get_path_info $p -num_logic_levels]
		say [format "  worst: slack %s, %s levels, %s -> %s" $v $lv [get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]]]
	}
	set vs "-"
	if {[csize $smpn] > 0} {
		foreach_in_collection p [get_timing_paths -setup -from $ra -through $smpn -npaths 1] { set vs [format "%.3f" [get_path_info $p -slack]] }
		say "  worst from read_avail through daria_smp's nets: $vs"
	}
	if {$v eq ""} {
		check "p" FAIL "no path from psram's read_avail through the writer's psram_read_en into psram's registers"
	} else {
		check "p" INFO "psram_read_avail -> rx -> rd_req -> psram_read_en -> psram: worst setup $v ns, $lv levels at $wcond (through daria_smp: $vs)"
	}
}

}
# ---- (o) PSRAM pins: the datasheet ------------------------------------------------------------------------------
section o {o.files} {
report_datasheet -file datasheet.rpt
check "o.files" INFO "datasheet.rpt written; step7_checks.py lists cram0_a, cram0_adv_n, cram0_oe_n clock-to-output and cram0_dq setup/hold"

}
catch {close $tf}
say "# step7_report.tcl: end"
close $out
delete_timing_netlist
project_close
