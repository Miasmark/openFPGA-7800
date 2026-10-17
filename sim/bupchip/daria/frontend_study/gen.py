#!/usr/bin/env python3
# Generate a standalone Quartus project for one module, in ./NAME (run_study.sh):
# every port but the clocks is a virtual pin, so nothing is pruned and no pins
# are needed, with the core's synthesis and fitter settings (ap_core.qsf).
#   gen.py NAME SOURCE [EXTRA ...]    ROOT: the repository, mounted at /build
# SPDX-License-Identifier: MIT
import os, re, sys
name, src = sys.argv[1], sys.argv[2]
extra = sys.argv[3:]          # extra source files
clocks = {"clk", "clk_sys", "clk_arm", "clk_i"}
text = open(src).read()
m = re.search(r"module\s+%s\b.*?\((.*?)\);" % re.escape(name), text, re.S)
hdr = m.group(1)
# drop a parameter block if present
if "#(" in text[m.start():m.start()+200]:
    m2 = re.search(r"module\s+%s\s*#\s*\(.*?\)\s*\((.*?)\);" % re.escape(name), text, re.S)
    hdr = m2.group(1)
ports = []
for line in hdr.split("\n"):
    line = re.sub(r"//.*", "", line).strip()
    if not re.match(r"(input|output|inout)\b", line):
        continue
    bus = "[" in line
    nm = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*,?\s*$", line)[0]
    ports.append((nm, bus))
d = name + os.environ.get("SUFFIX", "")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "p.qsf"), "w") as f:
    f.write('set_global_assignment -name FAMILY "Cyclone V"\n')
    f.write("set_global_assignment -name DEVICE 5CEBA4F23C8\n")
    f.write("set_global_assignment -name TOP_LEVEL_ENTITY %s\n" % name)
    f.write("set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files\n")
    f.write("set_global_assignment -name SDC_FILE p.sdc\n")
    f.write("set_global_assignment -name NUM_PARALLEL_PROCESSORS 1\n")
    for k, v in [("MIN_CORE_JUNCTION_TEMP", "0"), ("MAX_CORE_JUNCTION_TEMP", "85"),
                 ("OPTIMIZATION_MODE", '"HIGH PERFORMANCE EFFORT"'), ("SEED", "1"),
                 ("ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP", "ON"), ("PRE_MAPPING_RESYNTHESIS", "ON"),
                 ("OPTIMIZATION_TECHNIQUE", "SPEED"), ("MUX_RESTRUCTURE", "OFF"),
                 ("PHYSICAL_SYNTHESIS_COMBO_LOGIC", "ON"), ("PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION", "ON"),
                 ("PHYSICAL_SYNTHESIS_REGISTER_RETIMING", "ON"), ("FITTER_EFFORT", '"AUTO FIT"')]:
        f.write("set_global_assignment -name %s %s\n" % (k, v))
    for s in [src] + extra:
        kind = "VERILOG_FILE" if s.endswith(".v") else "SYSTEMVERILOG_FILE"
        f.write("set_global_assignment -name %s %s\n" % (kind, "/build/" + os.path.relpath(os.path.abspath(s), os.environ["ROOT"])))
    for nm, bus in ports:
        if nm in clocks:
            continue
        f.write("set_instance_assignment -name VIRTUAL_PIN ON -to %s%s\n" % (nm, "[*]" if bus else ""))
with open(os.path.join(d, "p.sdc"), "w") as f:
    for nm, _ in ports:
        if nm in clocks:
            per = "34.921" if nm == "clk_arm" else "69.841"
            f.write("create_clock -name %s -period %s [get_ports %s]\n" % (nm, per, nm))
    f.write("derive_clock_uncertainty\n")
print(d, len(ports), "ports")
