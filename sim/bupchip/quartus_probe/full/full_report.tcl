# quartus_sta -t full_report.tcl: the step 3 full-build probe's timing
# figures (run_full.sh). Writes timing.txt (worst setup and hold slack per
# clock at each corner, and clk_arm's Fmax), arm_paths.rpt (the ten worst
# clk_arm setup paths), arm_hold.rpt (the ten worst clk_arm hold paths at
# each fast corner), and cross.rpt (the worst paths each way between
# clk_arm and clk_sys, with the requirement that applied to them).
project_open ap_core
create_timing_netlist
read_sdc
update_timing_netlist

set pre {ic|pll|altera_pll_i|cyclonev_pll|counter[}
set post {].output_counter|divclk}
set names {0 clk_sys 1 clk_sdram 2 clk_sys_90 3 clk_arm}

set f [open "timing.txt" w]
foreach cond [get_available_operating_conditions] {
	set_operating_conditions $cond
	update_timing_netlist
	puts $f "== $cond"
	foreach {n label} $names {
		set clk [get_clocks "$pre$n$post"]
		set ss "-"
		set hs "-"
		foreach_in_collection p [get_timing_paths -setup -to_clock $clk -npaths 1] { set ss [format "%.3f" [get_path_info $p -slack]] }
		foreach_in_collection p [get_timing_paths -hold -to_clock $clk -npaths 1] { set hs [format "%.3f" [get_path_info $p -slack]] }
		puts $f [format "  %-10s setup %8s  hold %8s" $label $ss $hs]
	}
	set arm [get_clocks "${pre}3$post"]
	foreach_in_collection p [get_timing_paths -setup -from_clock $arm -to_clock $arm -npaths 1] {
		set per [get_clock_info -period $arm]
		set sl [get_path_info $p -slack]
		puts $f [format "  clk_arm internal: period %.3f, slack %.3f, Fmax %.2f MHz, %d levels, %s -> %s" \
			$per $sl [expr {1000.0 / ($per - $sl)}] [get_path_info $p -num_logic_levels] \
			[get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]]]
	}
}

set cond ""
foreach c [get_available_operating_conditions] { if {[string match "*slow*85c*" $c]} { set cond $c } }
set_operating_conditions $cond
update_timing_netlist
set arm [get_clocks "${pre}3$post"]
set sys [get_clocks "${pre}0$post"]
report_timing -setup -from_clock $arm -to_clock $arm -npaths 10 -nworst 1 -detail full_path -file arm_paths.rpt
report_timing -setup -from_clock $sys -to_clock $arm -npaths 5 -detail full_path -file cross.rpt
report_timing -setup -from_clock $arm -to_clock $sys -npaths 5 -detail full_path -append -file cross.rpt
report_timing -hold -from_clock $sys -to_clock $arm -npaths 5 -detail summary -append -file cross.rpt
report_timing -hold -from_clock $arm -to_clock $sys -npaths 5 -detail summary -append -file cross.rpt
set sdram [get_clocks "${pre}1$post"]
set sys90 [get_clocks "${pre}2$post"]
foreach {label from to} [list "sys->arm" $sys $arm "arm->sys" $arm $sys "sdram->arm" $sdram $arm \
		"arm->sdram" $arm $sdram "sys90->arm" $sys90 $arm "arm->sys90" $arm $sys90] {
	set n 0
	set ws "-"
	foreach_in_collection p [get_timing_paths -setup -from_clock $from -to_clock $to -npaths 100000] {
		if {$n == 0} { set ws [format "%.3f" [get_path_info $p -slack]] }
		incr n
	}
	set wh "-"
	foreach_in_collection p [get_timing_paths -hold -from_clock $from -to_clock $to -npaths 1] {
		set wh [format "%.3f" [get_path_info $p -slack]]
	}
	puts $f "$label: $n endpoints, worst setup slack $ws, worst hold slack $wh (slow 85C)"
}
close $f
# The worst hold paths into clk_arm at the fast corners, where hold is tightest.
foreach c [get_available_operating_conditions] {
	if {![string match "*fast*" $c]} { continue }
	set_operating_conditions $c
	update_timing_netlist
	report_timing -hold -to_clock $arm -npaths 10 -nworst 1 -detail full_path -append -file arm_hold.rpt
}
catch { report_exceptions -file exceptions.rpt }
delete_timing_netlist
project_close
