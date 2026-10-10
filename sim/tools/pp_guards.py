#!/usr/bin/env python3
"""The three guards that go with pp_equiv.py (DARIA step 7, plan 7.5 and 7.6).

pp_equiv.py hashes the preprocessed Verilog stream, which drops comments and
covers neither VHDL nor memory files nor the qsf. Over `git diff FROM TO`:

  directive  no added or removed line in a Verilog/SystemVerilog file
             carries a Quartus directive in a comment or an attribute:
             synthesis, altera_attribute, translate_off/translate_on, or
             "(*" inside a comment. Attributes in code reach pp_equiv's
             stream and are hashed; a directive in a comment does not, so it
             is listed here, and removing one (a translate_off/on pair, a
             keep) changes what Quartus builds as much as adding one.
  daria      every daria_* and bup_dbg_snap source in TO (src/fpga) is free
             of directives that reach the files compiled after it: `define,
             `undef, `timescale and the rest of pp_equiv.py's
             leak_directives (plan 2.8), so that excluding these files from
             pp_equiv's stream cannot hide a change to the others.
  files      no .vhd/.vhdl, .mif or .hex file changed (git diff --name-only).
  qsf        --qsf daria: the ap_core.qsf diff is exactly the three DARIA
             lines (VERILOG_MACRO "POCKET_DARIA=1", QIP_FILE core/daria.qip,
             SDC_FILE core/daria_constraints.sdc, each added once), plus the
             SEED line and comment lines; anything else fails.
             --qsf comments: every .qsf and .sdc file is the same at FROM and
             TO once comments and blank lines are stripped (7.6's
             comment-only exemption).
             --qsf none: no qsf rule.

Usage: pp_guards.py --from REV [--to REV] [--repo DIR] [--qsf daria|comments|none]
  --to defaults to HEAD; --to WORKTREE compares with the working tree
  (tracked files only). Exit status 0 when every guard passes, else 1.
SPDX-License-Identifier: MIT
"""
import argparse, os, re, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pp_equiv import leak_directives  # noqa: E402

HDL = ("*.v", "*.sv", "*.svh", "*.vh")
DIRECTIVE = re.compile(r"synthesis|altera_attribute|translate_(off|on)", re.I)
DARIA_QSF = [
    'set_global_assignment -name VERILOG_MACRO "POCKET_DARIA=1"',
    'set_global_assignment -name QIP_FILE core/daria.qip',
    'set_global_assignment -name SDC_FILE core/daria_constraints.sdc',
]
SEED = re.compile(r"^set_global_assignment\s+-name\s+SEED\s+\d+$")


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True,
                       errors="replace")
    if r.returncode != 0:
        sys.exit(f"pp_guards.py: git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def diff_args(a):
    return [a.frm] if a.to == "WORKTREE" else [a.frm, a.to]


def added_lines(repo, a, paths, sign="+"):
    """(file, line number, text) for every added line (sign "+", numbered in
    TO) or removed line (sign "-", numbered in FROM)."""
    out, f, ln, fold, fnew = [], None, 0, None, None
    for l in git(repo, "diff", "-U0", "--no-color", *diff_args(a), "--", *paths).splitlines():
        if l.startswith("--- "):
            fold = l[6:] if l.startswith("--- a/") else None
        elif l.startswith("+++ "):
            fnew = l[6:] if l.startswith("+++ b/") else None
            f = fnew if sign == "+" else fold
        elif l.startswith("@@"):
            m = re.search(r"\+(\d+)" if sign == "+" else r"-(\d+)", l)
            ln = int(m.group(1)) if m else 0
        elif l.startswith(sign) and f:
            out.append((f, ln, l[1:]))
            ln += 1
    return out


def comment_part(text, in_block):
    """The comment text of one line, and whether a block comment is still open."""
    parts, i, s = [], 0, text
    while i < len(s):
        if in_block:
            j = s.find("*/", i)
            parts.append(s[i:] if j < 0 else s[i:j])
            if j < 0:
                return " ".join(parts), True
            i, in_block = j + 2, False
        else:
            q = s.find('"', i)
            c1, c2 = s.find("//", i), s.find("/*", i)
            cands = [x for x in (c1, c2) if x >= 0]
            if not cands:
                break
            c = min(cands)
            if 0 <= q < c:                       # skip a string literal
                e = s.find('"', q + 1)
                i = len(s) if e < 0 else e + 1
                continue
            if c == c1:
                parts.append(s[c + 2:])
                break
            i, in_block = c + 2, True
    return " ".join(parts), in_block


def guard_directive(repo, a):
    bad = []
    for sign, what in (("+", "added"), ("-", "removed")):
        blk = {}
        for f, ln, text in added_lines(repo, a, HDL, sign):
            com, blk[f] = comment_part(text, blk.get(f, False))
            if DIRECTIVE.search(com) or "(*" in com:
                bad.append(f"{what} {f}:{ln}: {text.strip()}")
    return bad


def guard_daria(repo, a):
    bad = []
    if a.to == "WORKTREE":
        names = git(repo, "ls-files", "src/fpga").split()
    else:
        names = git(repo, "ls-tree", "-r", "--name-only", a.to, "src/fpga").split()
    for n in sorted(names):
        if re.search(r"(^|/)(daria_[^/]*|bup_dbg_snap)\.(sv|v|svh|vh)$", n):
            for ln, what in leak_directives(blob(repo, a.to, n)):
                bad.append(f"{n}:{ln}: {what}")
    return bad


def guard_files(repo, a):
    names = git(repo, "diff", "--name-only", *diff_args(a)).split()
    return [n for n in names if re.search(r"\.(vhdl?|mif|hex)$", n, re.I)]


def strip_tcl(text):
    out = []
    for l in text.splitlines():
        l = re.sub(r";\s*#.*$", "", l).strip()
        if l and not l.startswith("#"):
            out.append(re.sub(r"\s+", " ", l))
    return out


def blob(repo, rev, path):
    if rev == "WORKTREE":
        p = os.path.join(repo, path)
        return open(p, errors="replace").read() if os.path.exists(p) else ""
    r = subprocess.run(["git", "-C", repo, "show", f"{rev}:{path}"], capture_output=True, text=True,
                       errors="replace")
    return r.stdout if r.returncode == 0 else ""


def guard_qsf_daria(repo, a):
    bad, added, removed = [], [], []
    for l in git(repo, "diff", "-U0", "--no-color", *diff_args(a), "--", "src/fpga/ap_core.qsf").splitlines():
        if l.startswith(("+++", "---", "@@")):
            continue
        if l[:1] in "+-":
            t = re.sub(r"\s+", " ", l[1:]).strip()
            if not t or t.startswith("#"):
                continue                          # comment lines may change (the seed comment)
            (added if l[0] == "+" else removed).append(t)
    for t in added:
        if t in DARIA_QSF or SEED.match(t):
            continue
        bad.append("added: " + t)
    for t in removed:
        if not SEED.match(t):
            bad.append("removed: " + t)
    for t in DARIA_QSF:
        if added.count(t) != 1:
            bad.append(f"expected once, added {added.count(t)} times: {t}")
    if sum(1 for t in added if SEED.match(t)) > 1:
        bad.append("more than one SEED line added")
    return bad


def guard_qsf_comments(repo, a):
    names = set(git(repo, "diff", "--name-only", *diff_args(a)).split())
    bad = []
    for n in sorted(x for x in names if re.search(r"\.(qsf|sdc)$", x)):
        if strip_tcl(blob(repo, a.frm, n)) != strip_tcl(blob(repo, a.to, n)):
            bad.append(f"{n}: differs with comments stripped")
    return bad


def main():
    p = argparse.ArgumentParser(description="pp_equiv.py's guards (plan 7.5)")
    p.add_argument("--repo", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    p.add_argument("--from", dest="frm", required=True)
    p.add_argument("--to", default="HEAD")
    p.add_argument("--qsf", choices=("daria", "comments", "none"), default="none")
    a = p.parse_args()
    repo = os.path.abspath(a.repo)
    rc = 0
    checks = [("directive", guard_directive), ("daria", guard_daria), ("files", guard_files)]
    if a.qsf == "daria":
        checks.append(("qsf daria", guard_qsf_daria))
    elif a.qsf == "comments":
        checks.append(("qsf/sdc comments", guard_qsf_comments))
    print(f"pp_guards {a.frm}..{a.to} in {repo}")
    for name, fn in checks:
        bad = fn(repo, a)
        print(f"GUARD {name}: {'pass' if not bad else 'FAIL'} ({len(bad)} finding(s))")
        for b in bad:
            print("  " + b)
        rc |= 1 if bad else 0
    sys.exit(rc)


if __name__ == "__main__":
    main()
