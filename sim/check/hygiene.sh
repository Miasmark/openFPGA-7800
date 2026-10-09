#!/bin/bash
# Repository hygiene before a merge (DARIA step 7, docs/daria_step7/plan.md
# 7.7), over the changes from BASE (default aeee6d2) to HEAD:
#   - no file with a cartridge-image extension (.a26, .a78, .bin, .rom), no
#     image or frame dump (.png, .ppm, .bmp, .gif, .jpg), nothing under
#     sim/work, and no binary file or file over LIMIT bytes (default 262144)
#     unless --allow names it;
#   - no user firmware (a file named bupchip.<anything>);
#   - no absolute path into /tmp or a scratch directory in an added line;
#   - none of the assistant and model names in a list kept OUTSIDE the
#     repository (writing them in would break the rule this checks): give it
#     as --names FILE or HYGIENE_NAMES=FILE, one name per line, matched as
#     words, case-insensitively. Without the list the run fails: the check
#     did not happen.
# Commit messages are not files and are not checked here.
#   sim/check/hygiene.sh [--base REV] [--names FILE] [--allow PATH]... [--limit BYTES]
# Exit status 0 when nothing is found, 1 otherwise, 2 on a usage error.
# SPDX-License-Identifier: MIT
set -e -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
BASE=aeee6d2
NAMES="${HYGIENE_NAMES:-}"
LIMIT=262144
ALLOW=()
while [ $# -gt 0 ]; do
	case "$1" in
		--base) BASE="$2"; shift 2 ;;
		--names) NAMES="$2"; shift 2 ;;
		--allow) ALLOW+=("$2"); shift 2 ;;
		--limit) LIMIT="$2"; shift 2 ;;
		*) echo "hygiene.sh: unknown argument $1" >&2; exit 2 ;;
	esac
done
git -C "$REPO" rev-parse --verify -q "$BASE^{commit}" > /dev/null || { echo "hygiene.sh: no commit $BASE" >&2; exit 2; }
python3 - "$REPO" "$BASE" "$NAMES" "$LIMIT" "${ALLOW[@]}" <<'PY'
import os, re, subprocess, sys
repo, base, names, limit = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
allow = set(sys.argv[5:])

def git(*a):
    return subprocess.run(["git", "-C", repo] + list(a), capture_output=True, text=True, errors="replace", check=True).stdout

# absolute paths into /tmp or a scratch directory (spelled in pieces, so that
# this file does not match itself)
T = "tmp/"
TMP_RE = re.compile(r"(^|[\s\"'=(:])/" + T + "|/var/" + T + "|/private/" + T + "|scratch" + "pad")
bad = []
head = git("rev-parse", "--short", "HEAD").strip()
changed = [l.split("\t") for l in git("diff", "--name-status", "--no-renames", base, "HEAD").splitlines() if l]
files = [p[-1] for p in changed if not p[0].startswith("D")]
numstat = {l.split("\t")[2]: l.split("\t")[:2] for l in git("diff", "--numstat", "--no-renames", base, "HEAD").splitlines() if l}
for f in files:
    low = f.lower()
    name = os.path.basename(f)
    if f in allow:
        continue
    if re.search(r"\.(a26|a78|bin|rom)$", low):
        bad.append(f"cartridge-image extension: {f}")
    if re.search(r"\.(png|ppm|bmp|gif|jpe?g)$", low):
        bad.append(f"image file: {f}")
    if f.startswith("sim/work"):
        bad.append(f"under sim/work: {f}")
    if re.fullmatch(r"bupchip\.[^/]*", name, re.I):
        bad.append(f"user firmware: {f}")
    try:
        size = int(git("cat-file", "-s", f"HEAD:{f}").strip())
    except subprocess.CalledProcessError:
        size = 0
    if numstat.get(f, ["", ""])[0] == "-":
        bad.append(f"binary file: {f} ({size} bytes)")
    elif size > limit:
        bad.append(f"over {limit} bytes: {f} ({size} bytes)")

# added lines
diff = git("diff", "-U0", "--no-color", "--no-renames", base, "HEAD")
cur, added = None, []
for l in diff.splitlines():
    if l.startswith("+++ "):
        cur = l[6:] if l.startswith("+++ b/") else None
    elif l.startswith("+") and cur and cur not in allow:
        added.append((cur, l[1:]))
for f, t in added:
    if re.search(TMP_RE, t):
        bad.append(f"absolute path into /tmp or a scratch directory: {f}: {t.strip()[:120]}")

if not names:
    bad.append("assistant and model names: no list given (--names FILE or HYGIENE_NAMES): not checked")
else:
    rp = os.path.realpath(names)
    if rp.startswith(os.path.realpath(repo) + os.sep):
        bad.append(f"the name list {names} is inside the repository")
    elif not os.path.exists(rp):
        bad.append(f"the name list {names} does not exist")
    else:
        words = [w.strip() for w in open(rp, errors="replace") if w.strip() and not w.startswith("#")]
        pats = [re.compile(r"(?<![A-Za-z0-9])" + re.escape(w) + r"(?![A-Za-z0-9])", re.I) for w in words]
        hits = 0
        for f, t in added:
            for w, p in zip(words, pats):
                if p.search(t):
                    hits += 1
                    bad.append(f"listed name in an added line: {f}: '{w}'")
        # file names too
        for f in files:
            for w, p in zip(words, pats):
                if p.search(f):
                    bad.append(f"listed name in a file name: {f}: '{w}'")
        print(f"  names: {len(words)} checked over {len(added)} added lines")

print(f"hygiene {base}..{head}: {len(files)} files changed, {len(added)} lines added")
for b in bad:
    print("  FAIL: " + b)
print("HYGIENE " + ("pass" if not bad else f"FAIL ({len(bad)} finding(s))"))
sys.exit(0 if not bad else 1)
PY
