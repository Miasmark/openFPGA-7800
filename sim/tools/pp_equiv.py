#!/usr/bin/env python3
"""Preprocessed-source fingerprint of the Quartus build (DARIA step 7, 7.5).

Walks ap_core.qsf -> QIP_FILE (recursively) in Quartus's order, collects the
Verilog/SystemVerilog files, and runs Verilator's preprocessor over them as
one stream (so a `define in one file reaches the later ones, as in Quartus),
with the qsf's VERILOG_MACROs plus ALTERA_RESERVED_QIS (Quartus defines it
during synthesis). Comments are dropped by -E; whitespace within a line is
collapsed and blank lines removed, so comment-only, spacing and blank-line
edits do not count. Line breaks are kept: a statement split or joined
across lines changes the hash (a false difference, never a false identity).

What the hash does not see, and the guards in pp_guards.py cover (plan 7.5):
comments (a `// synthesis translate_off` is a directive to Quartus), VHDL
(mister/rtl/dpram.vhd is listed, not preprocessed), memory files (.mif,
.hex), and the qsf's own assignments and constraints.

Usage:
  pp_equiv.py FPGA_DIR OUTDIR [-D NAME[=V] ...] [-U NAME ...]
              [--exclude REGEX ...] [--token WORD] [--expect SHA256]
      the Quartus file list. -D adds a macro (e.g. POCKET_DARIA), -U removes
      one the qsf sets. --exclude drops files whose path (relative to
      FPGA_DIR) matches REGEX from the stream (the new DARIA files, once they
      are shown to be unreferenced). An excluded file is not in the stream,
      so a directive in it that reaches the files after it in Quartus's
      order would go unseen: an excluded file is refused (exit 1) when it
      holds, outside comments, any of `define, `undef, `undefineall,
      `timescale, `resetall, `include, `celldefine, `unconnected_drive,
      `pragma, `begin_keywords, `line, `default_decay_time,
      `default_trireg_strength, `delay_mode_*, a `default_nettype other than
      none or wire or not ending at wire, or unbalanced `ifdef/`endif
      (plan 2.8; leak_directives below, which pp_guards.py also applies).
      --token counts the identifiers in the stream that contain WORD
      (default daria) and prints the count; with --max-token N the run fails
      when the count is above N.
  pp_equiv.py --files OUTDIR FILE... [-D NAME[=V] ...] [-I DIR ...]
              [--expect SHA256]
      the given files in the given order, with only the macros given (no qsf,
      no ALTERA_RESERVED_QIS unless given): e.g. top.sv and cart2600.sv with
      run_daria.sh's WRAPPER set.

Prints one hash for the whole stream ("<sha256>  N files, ...") and writes
OUTDIR/files.txt (order and macros), OUTDIR/stream.pp and OUTDIR/hashes.txt
(per file, each preprocessed alone, so a `define from an earlier file is not
seen: per-file hashes are a locator only; the stream hash is the proof).
Exit status: 0, or 1 on a preprocessor error, a hash other than --expect,
or a token count above --max-token.

VERILATOR selects the binary (default /opt/verilator-5.040/bin/verilator).
SPDX-License-Identifier: MIT
"""
import hashlib, os, re, subprocess, sys

VERILATOR = os.environ.get("VERILATOR", "/opt/verilator-5.040/bin/verilator")


def qip_files(path, out, vhdl):
    base = os.path.dirname(path)
    for line in open(path):
        line = line.split("#", 1)[0]
        m = re.search(r"-name\s+(\w+)\s+(.*)$", line)
        if not m:
            continue
        kind, rest = m.group(1), m.group(2).strip()
        j = re.search(r"qip_path\)\s+\"?([^\]\"]+?)\"?\s*\]", rest)
        f = os.path.normpath(os.path.join(base, j.group(1).strip())) if j else \
            os.path.normpath(os.path.join(base, rest.strip('"')))
        if kind == "QIP_FILE":
            qip_files(f, out, vhdl)
        elif kind in ("VERILOG_FILE", "SYSTEMVERILOG_FILE"):
            out.append(f)
        elif kind == "VHDL_FILE":
            vhdl.append(f)


# Compiler directives whose effect reaches the files compiled after the one
# that holds them (IEEE 1800 22.x); `ifdef and friends only within the file,
# when balanced. `default_nettype is allowed as the daria files use it: none,
# back to wire at the end (a file that compiles under none compiles to the
# same netlist under wire, and the reverse is a compile error).
LEAK = re.compile(r"`\s*(define|undef|undefineall|timescale|resetall|include|celldefine|endcelldefine|"
                  r"unconnected_drive|nounconnected_drive|pragma|begin_keywords|end_keywords|line|"
                  r"default_decay_time|default_trireg_strength|delay_mode_\w+)\b")


def strip_comments(text):
    """The text without // and /* */ comments and string literals, line breaks kept."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            seg = text[i:n if j < 0 else j + 2]
            out.append("\n" * seg.count("\n"))
            i = n if j < 0 else j + 2
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append('""')
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def leak_directives(text):
    """[(line, what)] for each directive in text (one file) that could reach
    the files compiled after it."""
    code = strip_comments(text)
    bad = []
    for ln, l in enumerate(code.splitlines(), 1):
        for m in LEAK.finditer(l):
            bad.append((ln, "`" + m.group(1)))
    nettypes = [(ln, m.group(1)) for ln, l in enumerate(code.splitlines(), 1)
                for m in re.finditer(r"`\s*default_nettype\s+(\w+)", l)]
    for ln, v in nettypes:
        if v not in ("none", "wire"):
            bad.append((ln, f"`default_nettype {v}"))
    if nettypes and nettypes[-1][1] != "wire":
        bad.append((nettypes[-1][0], "`default_nettype not set back to wire at the end"))
    depth = 0
    for ln, l in enumerate(code.splitlines(), 1):
        for m in re.finditer(r"`\s*(ifdef|ifndef|endif)\b", l):
            depth += 1 if m.group(1) != "endif" else -1
            if depth < 0:
                bad.append((ln, "`endif without `ifdef"))
                depth = 0
    if depth:
        bad.append((0, f"{depth} `ifdef/`ifndef without `endif"))
    return bad


def normalise(text):
    return "\n".join(l for l in (re.sub(r"\s+", " ", x).strip() for x in text.splitlines()) if l)


def preprocess(macros, incs, files):
    cmd = [VERILATOR, "-E", "-P"] + ["-D" + m for m in macros] + ["-I" + d for d in incs] + files
    return subprocess.run(cmd, capture_output=True, text=True)


def parse_args(argv):
    o = {"adds": [], "rems": [], "excl": [], "incs": [], "token": "daria", "max_token": None,
         "expect": None, "files_mode": False, "pos": []}
    a = list(argv)
    while a:
        x = a.pop(0)
        if x == "-D": o["adds"].append(a.pop(0))
        elif x.startswith("-D") and len(x) > 2: o["adds"].append(x[2:])
        elif x == "-U": o["rems"].append(a.pop(0))
        elif x == "-I": o["incs"].append(a.pop(0))
        elif x == "--exclude": o["excl"].append(a.pop(0))
        elif x == "--token": o["token"] = a.pop(0)
        elif x == "--max-token": o["max_token"] = int(a.pop(0))
        elif x == "--expect": o["expect"] = a.pop(0)
        elif x == "--files": o["files_mode"] = True
        elif x in ("-h", "--help"): print(__doc__); sys.exit(0)
        elif x.startswith("-"): sys.exit("pp_equiv.py: bad argument " + x)
        else: o["pos"].append(x)
    return o


def main():
    o = parse_args(sys.argv[1:])
    if o["files_mode"]:
        if len(o["pos"]) < 2:
            sys.exit("usage: pp_equiv.py --files OUTDIR FILE... [-D M] [-I DIR]")
        outdir, files = o["pos"][0], [os.path.abspath(f) for f in o["pos"][1:]]
        root = os.path.commonpath([os.path.dirname(f) for f in files])
        macros, vhdl = list(o["adds"]), []
        incs = sorted({os.path.dirname(f) for f in files} | set(map(os.path.abspath, o["incs"])))
    else:
        if len(o["pos"]) != 2:
            sys.exit("usage: pp_equiv.py FPGA_DIR OUTDIR [-D NAME] [-U NAME] [--exclude REGEX]")
        fpga, outdir = o["pos"]
        root = fpga
        qsf = os.path.join(fpga, "ap_core.qsf")
        macros, files, vhdl = [], [], []
        for line in open(qsf):
            m = re.match(r'\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"([^"]+)"', line)
            if m: macros.append(m.group(1))
            m = re.match(r'\s*set_global_assignment\s+-name\s+QIP_FILE\s+(\S+)', line)
            if m: qip_files(os.path.join(fpga, m.group(1)), files, vhdl)
        macros = [x for x in macros if x.split("=")[0] not in o["rems"]] + o["adds"] + ["ALTERA_RESERVED_QIS=1"]
        excluded = [f for f in files if any(re.search(r, os.path.relpath(f, fpga)) for r in o["excl"])]
        files = [f for f in files if f not in excluded]
        refused = [(os.path.relpath(f, fpga), ln, what) for f in excluded
                   for ln, what in leak_directives(open(f, errors="replace").read())]
        if refused:
            for rel, ln, what in refused:
                print(f"EXCLUDE REFUSED {rel}:{ln}: {what} would reach the files after it, which the stream would not show")
            sys.exit(1)
        incs = sorted({os.path.dirname(f) for f in files} | {os.path.join(fpga, "mister"), os.path.join(fpga, "mister/rtl")})
    os.makedirs(outdir, exist_ok=True)
    rel = [os.path.relpath(f, root) for f in files]
    txt = "\n".join(rel) + "\n# VHDL (not preprocessed):\n" + "\n".join(os.path.relpath(f, root) for f in vhdl) + \
        "\n# macros: " + " ".join(macros) + "\n"
    if not o["files_mode"] and o["excl"]:
        txt += "# excluded: " + " ".join(os.path.relpath(f, root) for f in excluded) + "\n"
    open(os.path.join(outdir, "files.txt"), "w").write(txt)
    r = preprocess(macros, incs, files)
    if r.returncode != 0:
        sys.stderr.write(r.stderr[:4000]); sys.exit(1)
    norm = normalise(r.stdout) + "\n"
    open(os.path.join(outdir, "stream.pp"), "w").write(norm)
    h = hashlib.sha256(norm.encode()).hexdigest()
    with open(os.path.join(outdir, "hashes.txt"), "w") as fh:
        for f in files:
            rr = preprocess(macros, incs, [f])
            n = normalise(rr.stdout)
            fh.write(f"{hashlib.sha256(n.encode()).hexdigest()[:16]} {os.path.relpath(f, root)}\n")
    tok = o["token"]
    ntok = len([t for t in re.findall(r"[A-Za-z_][A-Za-z0-9_$]*", norm) if tok.lower() in t.lower()])
    extra = f", excluded {len(excluded)}" if not o["files_mode"] and o["excl"] else ""
    print(f"{h}  {len(files)} files, {len(vhdl)} VHDL not covered, macros: {' '.join(macros)}")
    print(f"tokens containing '{tok}': {ntok}{extra}")
    rc = 0
    if o["expect"] is not None:
        ok = h == o["expect"]
        print(f"EXPECT {o['expect']}: {'match' if ok else 'MISMATCH'}")
        rc |= 0 if ok else 1
    if o["max_token"] is not None and ntok > o["max_token"]:
        print(f"TOKENS {ntok} above the limit {o['max_token']}")
        rc = 1
    sys.exit(rc)


if __name__ == "__main__":
    main()
