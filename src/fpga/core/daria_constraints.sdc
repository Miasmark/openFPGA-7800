#
# DARIA constraints (POCKET_DARIA: the 2600 ARM front end on the BupChip's
# CPU; docs/DARIA_CORE.md 7.3, docs/daria_fe/design.md 8.2)
#
# Read only through its SDC_FILE line in ap_core.qsf, which comes after the
# QIP_FILE lines: by then apf_constraints.sdc has derived the PLL clocks and
# read core_constraints.sdc. A build without DARIA drops that line with the
# other two DARIA lines (the macro and core/daria.qip), and nothing else in
# its constraint set changes. Padding for the DARIA build alone goes here,
# never in core_constraints.sdc.
#
# Under POCKET_DARIA clk_arm (counter[3]) is VCO/18 (pll_core.v): its rising
# edges meet clk_sys's only every 3 clk_sys (8 clk_arm), so the requirement
# derived from the edges can be as little as one VCO period. Every crossing
# between the two goes through a synchroniser (two or three flops on a level
# or a toggle), and the buses that go with a toggle are held until the far
# side has taken them (DARIA_CORE.md 7.1-7.2; core/daria.qip, through
# core/daria_sync.tcl, and the RTL attributes of the files written for DARIA
# mark the first flops). clk_arm
# stays in core_constraints.sdc's synchronous group, so these paths are
# timed, but against a bound instead of the edges: at most 20 ns of data
# delay both ways, under one clk_arm period, and set_min_delay -20 so that a
# held bus has no hold check (with 0 it would fail one that means nothing
# for it). Not a clock-group cut: in TimeQuest a cut outranks set_max_delay
# and would leave the held buses unconstrained. clk_arm <-> clk_sdram and
# clk_arm <-> clk_sys_90 keep their real relationship as a tripwire: any
# path there is a design error, and fails timing visibly.

set daria_sys {ic|pll|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
set daria_arm {ic|pll|altera_pll_i|cyclonev_pll|counter[3].output_counter|divclk}

set_max_delay -from [get_clocks $daria_sys] -to [get_clocks $daria_arm] 20.000
set_max_delay -from [get_clocks $daria_arm] -to [get_clocks $daria_sys] 20.000
set_min_delay -from [get_clocks $daria_sys] -to [get_clocks $daria_arm] -20.000
set_min_delay -from [get_clocks $daria_arm] -to [get_clocks $daria_sys] -20.000

# The front end's shared-edge phase detector (daria_fe_guard.sv; design.md
# 8.1-8.2): one clk_arm toggle (pd_tog) into one clk_sys flop (pd_rx), which
# is not a synchroniser (SYNCHRONIZER_IDENTIFICATION OFF in the RTL). At
# VCO/18 a toggle launched 8.73 ns before a clk_sys edge must be caught
# there, and the toggle launched on the shared edge must not be caught on
# it. G1 (docs/daria_step10/plan.md section 10): 8 ns keeps 0.73 ns and
# 0.5 ns keeps 0.5 ns of margin beyond the corner models, since the Timing
# Analyzer's check already holds the skew and setup (the first pair, [1, 6]
# ns, counted them twice). step7_report.tcl's guard_pairs table knows both
# pairs. Register to register, so these two lines take precedence over the
# clock-to-clock pair above on this one path.
set_max_delay -from [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_tog}] \
              -to   [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_rx}] 8.000
set_min_delay -from [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_tog}] \
              -to   [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_rx}] 0.500

# Fitter only (as in core_constraints.sdc): extra margin asked of the fitter
# for the DARIA build alone, which the Timing Analyzer does not check. Empty
# at first; the rungs of the step-7 timing ladder (docs/daria_step7/plan.md
# 5.2 and 5.3: clk_arm setup, then clk_sdram setup) go here when a seed
# misses. This block is read after core_constraints.sdc's, and a later
# set_clock_uncertainty on a clock transfer REPLACES the earlier value for
# that transfer instead of adding to it: the last line wins, setup and hold
# each on their own, and -add adds only to the uncertainty Quartus derives
# (measured on Q0, plan 3.5 test 6: clk_sys -> clk_sdram setup, derived
# 0.12 ns; 1.0 ns padding, 1.12; that padding then a later -add 0.3, 0.42).
# So every rung here:
#   - states the TOTAL padding for the transfers it names, core_constraints'
#     part included: for 0.5 ns more setup into clk_sdram than its 1.5 ns,
#     write 2.0, never 0.5 (0.5 would cut the padding to a third);
#   - keeps -add, or the derived part is lost as well;
#   - names only the transfers it means to change: a setup line from all
#     four core clocks into clk_sdram replaces the setup padding of each of
#     them (a -setup line leaves the hold padding alone, and the reverse);
#   - is reviewed against core_constraints.sdc's fitter block, line by line,
#     for every transfer both name.
# clk_arm -> clk_arm (plan 5.2) has no padding in core_constraints.sdc, so
# its rung is the whole amount there.
#
# The guard pair asked of the fitter at 7.5 ns instead of 8.0 (a register to
# register line: it replaces the 8.000 above for the fitter alone; the
# Timing Analyzer and plan 5.4 (a) keep 8.000), as the first pair asked
# 5.5 ns for 6.0: with the router's register duplication off
# (daria_sync.tcl) the fitter once left that pair at -0.109 ns (seed 3 at
# VCO/19), its skew, about -0.6 to -1.1 ns at the slow corners, eating most
# of the bound.
if {$::TimeQuestInfo(nameofexecutable) eq "quartus_fit"} {
	set_max_delay -from [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_tog}] \
	              -to   [get_registers -nowarn {*|daria_fe_guard:u_guard|pd_rx}] 7.500
}
