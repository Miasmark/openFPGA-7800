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
#   sdram_worst.tsv the 20 worst clk_sdram setup paths at the worse slow
#                  corner, for 5.3's classification
#   exceptions.rpt, sdc.rpt, metastability.rpt, datasheet.rpt,
#   cross.rpt, guard.rpt, fixb.rpt
# step7_checks.py reads these and the compile's reports and gives the
# verdicts per kind of build.

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
# A section runs at global level; a Tcl error in it is a failed check, and
# the report goes on.
proc section {id body} {
	if {[catch {uplevel #0 $body} err]} {
		check $id FAIL "Tcl error in the report script: [string map {"\n" " | "} $err]"
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

set slow_corners {}
set all_corners [get_available_operating_conditions]
foreach c $all_corners { if {[string match -nocase "*slow*" $c]} { lappend slow_corners $c } }
say "# corners: $all_corners"

# ---- timing.txt, and the clock table (part of (l)) ------------------------------------------------
section l {
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
# ---- (a), (b), (d): the guard pair ---------------------------------------------------------------------
section ab {
say "\n## (a) (b) (d) the guard pair pd_tog -> pd_rx (design.md 8.2)"
set g_tog [regs "pd_tog" {*|daria_fe_guard:u_guard|pd_tog}]
set g_rx [regs "pd_rx" {*|daria_fe_guard:u_guard|pd_rx}]
if {[csize $g_tog] == 0 || [csize $g_rx] == 0} {
	check "a" FAIL "no such cell: pd_tog or pd_rx"
	check "b" FAIL "no such cell: pd_tog or pd_rx"
	check "d" FAIL "no such cell: pd_tog or pd_rx"
} else {
	set a_ok 1
	set b_ok 1
	foreach cond $all_corners {
		set_operating_conditions $cond
		update_timing_netlist
		foreach {which want} {setup 6.000 hold 1.000} {
			set n 0
			set txt ""
			foreach_in_collection p [get_timing_paths -$which -from $g_tog -to $g_rx -npaths 10 -nworst 10] {
				incr n
				set rel [get_path_info $p -clock_relationship]
				set sl [get_path_info $p -slack]
				set sk [get_path_info $p -clock_skew]
				set dd [get_path_info $p -data_delay]
				append txt [format " rel %.3f slack %.3f skew %.3f data %.3f;" $rel $sl $sk $dd]
				if {abs($rel - $want) > 0.0005 || $sl < 0} { if {$which eq "setup"} { set a_ok 0 } else { set b_ok 0 } }
			}
			if {$n != 1} { if {$which eq "setup"} { set a_ok 0 } else { set b_ok 0 } }
			say "  $cond $which: $n path(s);$txt"
		}
	}
	set_operating_conditions $wcond
	update_timing_netlist
	report_timing -setup -from $g_tog -to $g_rx -npaths 10 -detail full_path -file guard.rpt
	report_timing -hold -from $g_tog -to $g_rx -npaths 10 -detail full_path -append -file guard.rpt
	check "a" [expr {$a_ok ? "PASS" : "FAIL"}] "exactly one setup path pd_tog -> pd_rx at every corner, relationship 6.000 ns, met"
	check "b" [expr {$b_ok ? "PASS" : "FAIL"}] "exactly one hold path pd_tog -> pd_rx at every corner, relationship 1.000 ns, met"
	check "d" INFO "the clock skew on pd_tog -> pd_rx is listed per corner above (skew)"
}

}
# ---- (c) and (f) in part: the first flops present or absent ------------------------------------------------
section c.cells {
# The synchroniser table of plan 2.7. Columns: pattern, present in Build B
# (daria), present in Q5 (DARIA + BUP_DEBUG).
say "\n## (c) (f) the first flops of plan 2.7 (registers without duplicates)"
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
	{*|bupchip_pocket:bupchip|cap_err_a[0]} 0 1
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
section e {
say "\n## (e) report_sdc, report_exceptions (status parsed by step7_checks.py)"
report_sdc -file sdc.rpt
report_sdc -ignored -file sdc_ignored.rpt
report_exceptions -file exceptions.rpt
check "e.files" INFO "sdc.rpt, sdc_ignored.rpt and exceptions.rpt written; step7_checks.py checks the statuses"

}
# ---- (f): metastability -----------------------------------------------------------------------------------------
section f {
report_metastability -nchains 100000 -file metastability.rpt
check "f.files" INFO "metastability.rpt written (every chain); step7_checks.py checks the Forced first flops"

}
# ---- (g), (h), (i): Fix B --------------------------------------------------------------------------------------
section g {
say "\n## (g) no cart2600 path into sram_ctrl or the SRAM pads except through sram|t_*_q"
# Nets are named by instance path alone (ic|atari|main|cart2600|...).
set c26 [get_nets -nowarn {*|cart2600|*}]
set n26 [csize $c26]
say "  nets in cart2600 (*|cart2600|*): $n26"
foreach x [names $c26 8] { say "    $x" }
set c26r [regs "cart2600's registers" {*|cart2600:cart2600|*}]
set sram_all [regs "sram_ctrl's registers" {*|sram_ctrl:sram|*}]
set tq [regs "sram|t_*_q" {*|sram_ctrl:sram|t_*_q*}]
# remove_from_collection fails (a warning, and no removal) when the second
# collection is empty, as it is on a tree without Fix B.
set sram_end [expr {[csize $tq] > 0 ? [remove_from_collection $sram_all $tq] : $sram_all}]
set pads [get_ports -nowarn {sram_a[*] sram_dq[*] sram_oe_n sram_we_n sram_ub_n sram_lb_n}]
say "  sram_ctrl registers: [csize $sram_all], of them t_*_q: [csize $tq]; SRAM pads: [csize $pads] (outputs with no output delay: their pad registers are sram_ctrl's)"
foreach x [names $pads 6] { say "    $x" }
if {$n26 == 0 || [csize $sram_all] == 0} {
	check "g" FAIL "no such cell: cart2600's nets or sram_ctrl's registers"
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
		if {$n > 0} { report_timing -setup -through $c26 -to $coll -npaths 20 -detail full_path -append -file fixb.rpt }
	}
	set nch 0
	set sdr [get_registers -nowarn {*|sdram:sdram|*}]
	if {[csize $sdr] > 0} {
		foreach_in_collection p [get_timing_paths -setup -through $c26 -to $sdr -npaths 100000 -pairs_only] { incr nch }
	}
	say "  (reported apart) paths through cart2600 into sdram's registers ([csize $sdr]), the ch0_* legs: $nch"
	set nt 0
	if {[csize $tq] > 0} {
		foreach_in_collection p [get_timing_paths -setup -through $c26 -to $tq -npaths 100000 -pairs_only] { incr nt }
	}
	say "  paths through cart2600 into sram|t_*_q (allowed): $nt"
	check "g" [expr {$ng == 0 ? "PASS" : "FAIL"}] "$ng path(s) from cart2600 into sram_ctrl or the SRAM pads other than through t_*_q (on aeee6d2, Q0, this must find the merged request's paths: the negative control)"
}

}
section h {
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
	if {$ws eq "" || $ws < 8.0} { set h_ok 0 }
	if {$whh eq "" || $whh < 0} { set h_ok 0 }
	if {$wi eq "" || $wi < 40.0} { set h_ok 0 }
	say "  t_*_q -> clk_sdram: worst setup $ws ns ([expr {$ws eq "" ? "-" : $wl}] levels, >= +8), worst hold over corners $whh ns (>= 0)"
	say "  into t_*_q: worst setup $wi ns (>= +40)"
	check "h" [expr {$h_ok ? "PASS" : "FAIL"}] "t_*_q -> clk_sdram setup $ws / hold $whh, into t_*_q $wi (retiming into cart2600: step7_checks.py)"
}

}
section i {
say "\n## (i) open item 12"
set cr [regs "c_rdata" {*|sram_ctrl:sram|c_rdata[*]}]
set fb [regs "fbn_*" {*|sram_ctrl:sram|fbn_*}]
if {[csize $cr] == 0 || [csize $fb] == 0} {
	check "i" FAIL "no such cell: sram|c_rdata or sram|fbn_*"
} else {
	foreach cond $all_corners {
		set_operating_conditions $cond
		update_timing_netlist
		set l "  $cond:"
		foreach {lab coll} [list c_rdata $cr fbn_* $fb] {
			foreach w {setup hold} {
				set v "-"
				foreach_in_collection p [get_timing_paths -$w -from $coll -npaths 1] { set v [format "%.3f" [get_path_info $p -slack]] }
				append l " $lab $w $v;"
			}
		}
		say $l
	}
	set_operating_conditions $wcond
	update_timing_netlist
	check "i" INFO "c_rdata's multicycle slack and Flicker Blend's fbn_* slack per corner, above"
}

}
# ---- (j), (k), (k'): the crossings ----------------------------------------------------------------------------
section j {
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
section k {
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
		set guard [expr {[string match {*|daria_fe_guard:u_guard|pd_tog} $f] && [string match {*|daria_fe_guard:u_guard|pd_rx} $t]}]
		set wr [expr {$guard ? 6.0 : 20.0}]
		set wrh [expr {$guard ? 1.0 : -20.0}]
		if {abs($rel - $wr) > 0.0005 || $hrel eq "-" || abs($hrel - $wrh) > 0.0005} {
			set k_ok 0
			say "  $dir: $f -> $t setup rel $rel, hold rel $hrel (expected $wr / $wrh)"
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
} else {
	check "k" [expr {$k_ok ? "PASS" : "FAIL"}] "every clk_sys <-> clk_arm path pair has the 20 / -20 ns relationship, pd_tog -> pd_rx 6 / 1 ns ($nk pairs; crossings.tsv)"
}
check "k'.files" INFO "crossings.tsv written; step7_checks.py compares its endpoints with plan F3's list (f3_crossings.txt) and checks each first flop's source"

}
# ---- the 20 worst clk_sdram paths, for 5.3 ----------------------------------------------------------------------
section sdram {
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
section p {
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
section o {
report_datasheet -file datasheet.rpt
check "o.files" INFO "datasheet.rpt written; step7_checks.py lists cram0_a, cram0_adv_n, cram0_oe_n clock-to-output and cram0_dq setup/hold"

}
close $tf
close $out
delete_timing_netlist
project_close
