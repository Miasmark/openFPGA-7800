#!/usr/bin/env python3
# Write the DPC+ deletion variants of upstream's mapper_dpcplus.sv into the
# current directory, each with one feature removed, for run_study.sh to size:
#   variants.py PATH/mapper_dpcplus.sv
# SPDX-License-Identifier: MIT
import re, sys
src = open(sys.argv[1]).read()

def sub(t, old, new, count=1):
    assert old in t, old[:60]
    return t.replace(old, new, count)

def nofrac(t):
    t = sub(t, "\t\t\t\tfractional[i] <= 20'b0;\n", "")
    t = sub(t, "\t\t\t\tincrement[i] <= 8'b0;\n", "")
    t = re.sub(r"3'd3: fractional\[read_index\] <=\s*fractional\[read_index\] \+ \{12'b0, increment\[read_index\]\};", "3'd3: ;", t)
    t = re.sub(r"4'd0: fractional\[a_in\[2:0\]\] <=.*?\{4'b0, d_in, 8'b0\};", "4'd0: ;", t, flags=re.S)
    t = re.sub(r"4'd1: fractional\[a_in\[2:0\]\] <=.*?fractional\[a_in\[2:0\]\]\[15:0\]\};", "4'd1: ;", t, flags=re.S)
    t = re.sub(r"4'd2: begin\s*increment\[a_in\[2:0\]\] <= d_in;.*?end\n", "4'd2: ;\n", t, flags=re.S)
    assert "fractional[a_in" not in t and "increment[a_in" not in t
    return t

def nowindow(t):
    return sub(t, "window_set[i] = (top[i] - counter[i][7:0]) >\n\t\t\t\t(top[i] - bottom[i]);", "window_set[i] = 1'b0;")

def norandom(t):
    for old in ["\t\t\trandom_number <= 32'h2B435044;\n"]:
        t = sub(t, old, "")
    t = sub(t, "random_number <= random_next;", ";")
    t = sub(t, "random_number <= random_prior;", ";")
    t = sub(t, "3'd0: random_number <= 32'h2B435044;", "3'd0: ;")
    for b in ["7:0", "15:8", "23:16", "31:24"]:
        t = sub(t, "random_number[%s] <= d_in;" % b, ";")
    assert "random_number <=" not in t and "random_number[7:0] <=" not in t
    return t

def noservice(t):
    t = re.sub(r"if \(parameter_pointer < 8\) begin.*?end\n", "", t, count=1, flags=re.S)
    t = re.sub(r"else if \(\(d_in == 8'd1 \|\| d_in == 8'd2\) &&.*?end else if", "else if", t, count=1, flags=re.S)
    return t

for name, fns in [("nofrac", [nofrac]), ("nowindow", [nowindow]), ("norandom", [norandom]),
                  ("noservice", [noservice]), ("core", [nofrac, nowindow, norandom, noservice])]:
    t = src
    for f in fns:
        t = f(t)
    open("mapper_dpcplus_%s.sv" % name, "w").write(t)
    print(name, "ok")
