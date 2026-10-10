# DARIA's synchroniser marks (POCKET_DARIA; docs/DARIA_CORE.md 7.1-7.3),
# sourced by core/daria.qip.
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
# (sim/bupchip/quartus_probe/step7/smoke/run_smoke.sh): all 16 marks read
# "User Specified", none is reported ignored, and without daria.qip the same
# registers read "Automatic" or head no chain.
#
# Not here: the chains that carry the attribute in their RTL on a scalar
# first stage (daria_fe's u_call.ret_s1 and u_audio.ack_s1, daria_smp's
# req_s0, bup_dbg_snap's two first stages), and the guard's pd_rx, which
# is no synchroniser (SYNCHRONIZER_IDENTIFICATION OFF in daria_fe_guard.sv;
# its SDC pair is in daria_constraints.sdc).
#
# Three of these chains are absent from the release build and are marked
# for the builds that have them: pause_a (its input, pause_core, is tied 0,
# so synthesis removes it), halted_s (daria_halted has no load before
# step 8) and cap_err_a (BUP_DEBUG only).
#
# Form: -to "*|<entity>:*|<register>[0]" (brackets escaped for Tcl).

# clk_sys -> clk_arm
# bupchip/bupchip_pocket.sv: the hold and pause levels
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|hold_a\[0\]"
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|pause_a\[0\]"
# bupchip/bupchip_pocket.sv: the profile, the 32 KB cart RAM flag, the mapper reset
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|prof_a\[0\]"
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|ram32_a\[0\]"
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|mres_a\[0\]"
# bupchip/bupchip_pocket.sv: the $8007 command toggle (cmd_byte held)
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|cmd_s\[0\]"
# bupchip/bupchip_pocket.sv, BUP_DEBUG: the capture's sticky error flags
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|cap_err_a\[0\]"
# bupchip/daria_call.sv: call_tog
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|daria_call:*|tog_s\[0\]"
# bupchip/daria_mmio.sv: the TC snapshot toggle (hold, hold_tok held)
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|daria_mmio:*|sn_a\[0\]"
# bupchip/bup_asset_wr.sv: the capture's message toggle (msg_type, msg_pl held); a scalar
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bup_asset_wr:*|t1"

# clk_arm -> clk_sys
# bupchip/bupchip_pocket.sv: CPU ready and halted
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|ready_s\[0\]"
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|halted_s\[0\]"
# bupchip/bupchip_pocket.sv: cpu_run, for daria_mmio's clk_sys reset
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|run_s\[0\]"
# bupchip/bupchip_pocket.sv: the audio frame toggle (frame_arm held)
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|bupchip_pocket:*|ftog_s\[0\]"
# bupchip/daria_mmio.sv: TCR bit 0, and the TC write toggle (w_data, w_strb held)
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|daria_mmio:*|en_s\[0\]"
set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION FORCED -to "*|daria_mmio:*|w_s\[0\]"
