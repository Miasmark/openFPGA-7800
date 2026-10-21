# DARIA's synchroniser marks (POCKET_DARIA; docs/DARIA_CORE.md 7.1-7.3),
# sourced by core/daria.qip, and the one fitter setting the DARIA build
# changes (at the end: the router's register duplication, off so that the
# guard's pd_tog and pd_rx stay single registers).
#
# Each line marks the first flop of a clk_sys <-> clk_arm synchroniser whose
# first flop is not a scalar declaration of its own, so that the fitter keeps
# each chain together, reports it, and names it "Forced" ("User Specified" in
# report_metastability). An RTL attribute applies to a whole declaration, and
# these first flops are the bit 0 of a vector whose bit 1 is the second stage,
# or share a declaration with registers that are no synchronisers (t1 with t2
# and seen), so each is marked here on its exact bit. The source files keep
# their declarations, which the benches tap by name.
#
# Why a Tcl file and not the qip itself: Quartus tags every assignment it
# reads from a QIP_FILE with -qip, and refuses that option on
# SYNCHRONIZER_IDENTIFICATION ("Error (125091): ... Option "-qip" for
# "SYNCHRONIZER_IDENTIFICATION" assignment is illegal"), which stops Analysis
# & Synthesis. Assignments from a SOURCE_TCL_SCRIPT_FILE are not tagged.
# Checked on a fitted design with the core's names four levels deep
# (sim/bupchip/quartus_probe/step7/smoke/run_smoke.sh): all 13 marks read
# "User Specified", none is reported ignored, and without daria.qip the same
# registers read "Automatic" or head no chain.
#
# Not here: the chains that carry the attribute in their RTL on a scalar
# first stage (daria_fe's u_call.ret_s1 and u_audio.ack_s1, daria_smp's
# req_s0, bup_dbg_snap's two first stages), and the guard's pd_rx, which
# is no synchroniser (SYNCHRONIZER_IDENTIFICATION OFF in daria_fe_guard.sv;
# its SDC pair is in daria_constraints.sdc).
#
# Three first flops have no mark, because no build has their chain (plan
# 2.7), the BUP_DEBUG build among them: bupchip_pocket.sv's cap_err_a feeds
# only the status word's bit 11, which bup_status_osd.sv does not show;
# pause_a's input, pause_core, is tied 0 in every build; and halted_s feeds
# only daria_halted, which the wrapper leaves open (the status overlay shows
# the halt from dbg_status instead). The fitter listed the marks they had as
# ignored in the release and the BUP_DEBUG fits. A build that drives
# pause_core or loads daria_halted needs their marks back.
#
# Form: -to "*|<entity>:*|<register>[0]" (brackets escaped for Tcl).

# clk_sys -> clk_arm
# bupchip/bupchip_pocket.sv: the hold level
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|hold_a\[0\]"
# bupchip/bupchip_pocket.sv: the profile, the 32 KB cart RAM flag, the mapper reset
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|prof_a\[0\]"
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|ram32_a\[0\]"
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|mres_a\[0\]"
# bupchip/bupchip_pocket.sv: the $8007 command toggle (cmd_byte held)
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|cmd_s\[0\]"
# bupchip/daria_call.sv: call_tog
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|daria_call:*|tog_s\[0\]"
# bupchip/daria_mmio.sv: the TC snapshot toggle (hold, hold_tok held)
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|daria_mmio:*|sn_a\[0\]"
# bupchip/bup_asset_wr.sv: the capture's message toggle (msg_type, msg_pl held); a scalar
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bup_asset_wr:*|t1"

# clk_arm -> clk_sys
# bupchip/bupchip_pocket.sv: CPU ready
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|ready_s\[0\]"
# bupchip/bupchip_pocket.sv: cpu_run, for daria_mmio's clk_sys reset
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|run_s\[0\]"
# bupchip/bupchip_pocket.sv: the audio frame toggle (frame_arm held)
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|ftog_s\[0\]"
# bupchip/daria_mmio.sv: TCR bit 0, and the TC write toggle (w_data, w_strb held)
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|daria_mmio:*|en_s\[0\]"
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|daria_mmio:*|w_s\[0\]"

# The router's register duplication, off for the DARIA build (step 7, plan
# 5.4 (a)-(c)). daria_fe_guard's pd_tog -> pd_rx pair must be one register
# each, so that one path carries the 6 / 1 ns window (daria_constraints.sdc)
# and the detector reads one sample. With ap_core.qsf's
# ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION ON, "Auto Register
# Duplication" (this assignment, default Auto) let the router duplicate
# about 1,000 registers per fit for routability, pd_tog and pd_rx among them
# in 8 of 12 step-7 fits ("Router Logic Cell Insertion and Logic
# Duplication"), although PRESERVE_REGISTER marks both "Not to be Touched by
# Netlist Optimizations". Nothing narrower holds them in Quartus 21.1 Lite:
# - ROUTER_REGISTER_DUPLICATION and ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION
#   are global only; with -to Quartus stops ("Error (125024): Assignment
#   value ... specified in -to option ... not required");
# - ADV_NETLIST_OPT_ALLOWED "NEVER ALLOW" on both registers is accepted and
#   changes nothing: the router duplicated both again, in a fit otherwise
#   identical to the one without it (same slacks, same 1,054 duplicates).
# The logic cell insertion (routing buffers) and the duplication of
# combinational cells stay on (ap_core.qsf). A global assignment in a qip
# is refused like SYNCHRONIZER_IDENTIFICATION (Error 125091, -qip), so it
# is here; a build without DARIA keeps Auto.
set_global_assignment -name ROUTER_REGISTER_DUPLICATION OFF
