#!/usr/bin/env python3
"""Lane I1's whole-core checks of the DARIA wiring (docs/daria_step7/plan.md
3.3 items 4 and 5, 7.2 row I1, 7.3), on tb_wire (tb_load with its checks).

  wire.py build [daria|plain]    build tb_wire in the DARIA and the plain build
  wire.py run [SCENARIO ...]     run scenarios (default: every one whose inputs
                                 exist) and judge them; exit 0 when all pass
  wire.py list                   the scenarios and what each needs
  wire.py mutant NAME [SCENARIO ...]
                                 build the DARIA tb_wire on a copy of the tree's
                                 src/fpga with one of MUTANTS (the fixes of the
                                 D review's findings 3 and 5 undone in part) and
                                 run the scenarios that catch it, CATCH[NAME]
                                 (plan 7.2's; with SCENARIO ..., those of them
                                 named); judged as "wire.py verdict" below
  wire.py verdict NAME FILE [SCENARIO ...]
                                 a mutant's verdict from its run's records (FILE,
                                 WIRE_JSON's lines; default CATCH[NAME]): CAUGHT
                                 (exit 0) when each of CATCH[NAME]'s scenarios
                                 that ran fails on one of CATCH's keys for it;
                                 NOT CAUGHT (exit 1) when one of them passes or
                                 fails only on other checks; ERROR (exit 2) when
                                 a scenario's run crashed, timed out, hit a
                                 %Fatal or %Error, gave no WIRE summary or one
                                 without a judged key, or left no record, or when
                                 none of CATCH[NAME]'s scenarios ran. A mutant
                                 that is not CAUGHT fails the wire gate

Each build first runs sim/run_sim.sh with BUILD_TOP=tb_load (its sources,
defines and patched copies, DARIA=1 or 0), then builds tb_wire.sv with the
same Verilator command (read back from obj_load's verFiles), so tb_wire is
tb_load as run_sim.sh builds it, plus the checks. No game data: the images
are fe_dir/mkimg.py's synthetic ARM images, tone_test.py's and make_a78.py's
tone programs and souper_test.py's Souper cartridge with a synthetic ARSC
block, and pal_dpc, smoke_dpc with PAL frames; GAMES=DIR (game images by
path, never copied) adds the Turbo run, BIOS=FILE the decision-11 runs,
BUPFW=FILE (default the tree's src/fpga/mister/rtl/bupchip.hex) the Souper
second loads.

Environment: WORK (default sim/work/step7/wire), VERILATOR (default
/opt/verilator-5.040/bin/verilator), VL_JOBS (default 2), RTL_TREE (build
another checkout's RTL with these benches: a mutant's scratch worktree),
ARM_DIV (18, the default and pll_core.v's divider: clk_arm at VCO/18, the
guard expected locked; 19: VCO/19, where the guard never locks), DIRECTED=1
(also every fe_dir directed image, the whole-core directed set), PAL2600_PLAIN=0
(pal2600 without its plain-build run, which is only reported), WIRE_JSON=FILE
(run: append one JSON line per scenario judged: name, result, every failed
check, the summary keys among them and the run's own failures; mutant sets it),
WIRE_TIMEOUT (seconds per simulation, default 7200; a run that exceeds it is
killed and its scenario fails).
The log starts with the tree's HEAD and status, the tool and the binaries'
md5 (plan P23). Results: WORK/results.txt, one line per scenario.
SPDX-License-Identifier: MIT
"""
import hashlib, json, os, re, shlex, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.abspath(os.path.join(HERE, "../../.."))
REPO = os.path.dirname(SIM)
WORK = os.path.abspath(os.environ.get("WORK", os.path.join(SIM, "work/step7/wire")))
VL = os.environ.get("VERILATOR", "/opt/verilator-5.040/bin/verilator")
RTL_TREE = os.path.abspath(os.environ["RTL_TREE"]) if os.environ.get("RTL_TREE") else REPO
GAMES = os.environ.get("GAMES", "")
BIOS = os.environ.get("BIOS", "")
BUPFW = os.environ.get("BUPFW", os.path.join(REPO, "src/fpga/mister/rtl/bupchip.hex"))
ARM_DIV = os.environ.get("ARM_DIV", "18")
TIMEOUT = int(os.environ.get("WIRE_TIMEOUT", "7200"))
TURBO = "Turbo-Arcade_demo_final_CG_NTSC.bin"


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, **kw)


def md5(path):
    return hashlib.md5(open(path, "rb").read()).hexdigest()


def header():
    print("-- wire.py: tree %s HEAD %s" % (RTL_TREE, sh(["git", "-C", RTL_TREE, "rev-parse", "HEAD"]).stdout.strip()))
    st = sh(["git", "-C", RTL_TREE, "status", "--porcelain"]).stdout.strip()
    print("-- status: [%s]" % st.replace("\n", "; "))
    if RTL_TREE != REPO:
        print("-- benches from %s HEAD %s" % (REPO, sh(["git", "-C", REPO, "rev-parse", "HEAD"]).stdout.strip()))
    try:
        v = sh([VL, "--version"]).stdout.strip()
    except OSError as e:
        v = "not runnable: %s" % e
    print("-- tool: %s (%s)" % (VL, v))


# ---------------------------------------------------------------- build
def build(kind):
    w = os.path.join(WORK, kind)
    os.makedirs(w, exist_ok=True)
    env = dict(os.environ, WORK=w, VERILATOR=VL, VL_JOBS=os.environ.get("VL_JOBS", "2"),
               DARIA="1" if kind == "daria" else "0", BUILD_TOP="tb_load")
    if RTL_TREE != REPO:
        env["RTL_TREE"] = RTL_TREE
    r = subprocess.run(["bash", os.path.join(SIM, "run_sim.sh")], env=env, capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode:
        sys.stdout.write(r.stderr)
        sys.exit("build: run_sim.sh failed (%s)" % kind)
    ver = open(os.path.join(w, "obj_load", "Vtb_load__verFiles.dat")).read()
    m = re.search(r'^C "(.*)"$', ver, re.M)
    args = shlex.split(m.group(1))
    obj = os.path.join(w, "obj_wire")
    out = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--top-module":
            out += [a, "tb_wire"]; i += 2; continue
        if a == "-Mdir":
            out += [a, obj]; i += 2; continue
        out.append(a)
        if a.endswith("/tb_load.sv"):
            # tb_wire, and core_top.v's region switch for its +wire_pll
            out.append(os.path.join(HERE, "tb_wire.sv"))
            out.append(os.path.join(RTL_TREE, "src/fpga/core/pll_region.v"))
        i += 1
    if os.path.join(HERE, "tb_wire.sv") not in out:
        sys.exit("build: no tb_load.sv in run_sim.sh's command")
    with open(os.path.join(w, "obj_wire.log"), "w") as log:
        r = subprocess.run(["nice", "-n", "10", VL] + out, stdout=log, stderr=subprocess.STDOUT)
    if r.returncode:
        print(open(os.path.join(w, "obj_wire.log")).read()[-3000:])
        sys.exit("build: tb_wire failed (%s)" % kind)
    for d, _, fs in os.walk(obj):
        for f in fs:
            if f.endswith(".gch"):
                os.remove(os.path.join(d, f))
    print("-- built %s: %s md5 %s" % (kind, os.path.join(obj, "vtb"), md5(os.path.join(obj, "vtb"))))


def binary(kind):
    return os.path.join(WORK, kind, "obj_wire", "vtb")


# ---------------------------------------------------------------- images
def images():
    d = os.path.join(WORK, "img")
    os.makedirs(d, exist_ok=True)
    tests = ["smoke_dpc", "smoke_cdf", "digital_cdfj", "hard_reset_call_dpc", "hard_reset_call_cdf"]
    if os.environ.get("DIRECTED") == "1":
        tests = []          # all of them
    r = sh([sys.executable, os.path.join(SIM, "bupchip/daria/fe_dir/mkimg.py"), d] + tests)
    if r.returncode:
        sys.exit("mkimg.py failed: " + r.stderr)
    tone = lambda *a: sh([sys.executable, os.path.join(SIM, "tone_test.py")] + list(a)).stdout
    # the 2600 and 7800 tone programs, as run_sim.sh's load tests make them
    open(os.path.join(d, "load_test.a26"), "wb").write(bytes(int(l, 16) for l in tone("14", "2600").split()[:4096]))
    r = subprocess.run([sys.executable, os.path.join(SIM, "make_a78.py"), "7"], capture_output=True)
    open(os.path.join(d, "load_test.a78"), "wb").write(r.stdout)
    # an A78 whose cartridge is 29,696 bytes: detect2600's size rule calls it
    # DPC+ (force_bs 21) with no override (P5); the tone program at its top
    rom = bytes(int(l, 16) for l in tone("7").split())
    big = bytes([0xFF]) * (29696 - len(rom)) + rom
    open(os.path.join(d, "rom29696.bin"), "wb").write(big)
    r = subprocess.run([sys.executable, os.path.join(SIM, "make_a78.py"), "--bin", os.path.join(d, "rom29696.bin")],
                       capture_output=True)
    open(os.path.join(d, "a78_29696.a78"), "wb").write(r.stdout)
    # the 7800 tone program as a PAL A78 (header byte 57, the region, 1)
    a = bytearray(open(os.path.join(d, "load_test.a78"), "rb").read())
    a[57] = 1
    open(os.path.join(d, "load_test_pal.a78"), "wb").write(bytes(a))
    # the 2600 tone program in PAL frames (tone_test.py's "pal")
    open(os.path.join(d, "pal_test.a26"), "wb").write(
        bytes(int(l, 16) for l in tone("14", "2600", "pal").split()[:4096]))
    # two ARM images whose byte 57 (the A78 header's region byte, which the
    # core reads from every image) has bit 0 set; no .meta, so not in the
    # directed set
    for t in ("smoke_dpc", "smoke_cdf"):
        b = bytearray(open(os.path.join(d, t + ".bin"), "rb").read())
        b[57] |= 1
        open(os.path.join(d, t + ".b57.bin"), "wb").write(bytes(b))
    pal_dpc(os.path.join(d, "pal_dpc.bin"))
    # the Souper cartridge and the firmware (run_sim.sh's BupChip section)
    if os.path.isfile(BUPFW):
        r = subprocess.run([sys.executable, os.path.join(REPO, "tools/hex2bin.py"), BUPFW], capture_output=True)
        open(os.path.join(d, "bupchip.bin"), "wb").write(r.stdout)
        if not os.path.isfile(os.path.join(d, "souper.a78")):
            sh([sys.executable, os.path.join(SIM, "bupchip/verif/make_synth_arsc.py"), os.path.join(d, "synth.a78"),
                "--arsc", os.path.join(d, "synth.arsc")])
            sh([sys.executable, os.path.join(SIM, "souper_test.py"), os.path.join(d, "souper.a78"),
                "--arsc", os.path.join(d, "synth.arsc")])
    return d


def pal_dpc(path):
    """fe_dir's smoke_dpc (tests.py) with PAL frames: its body, then 60 lines
    (61 in every other frame) and 255 more, about 320 lines a frame, which the
    TIA scores as PAL after 48 frames (about 1 s). The TIA scores a frame of
    an odd line count at half (TIA.sv's frame_score), so frames of one parity
    only could score even and read NTSC; alternating frames cannot. No .meta:
    not in the directed set."""
    fd = os.path.join(SIM, "bupchip/daria/fe_dir")
    if fd not in sys.path:
        sys.path.insert(0, fd)
    from mkimg import Img, classify
    from armenc import OP_W8
    img = Img('dpc', scripts=[[], [(OP_W8, 0x40000C10, 0x5A)]])
    img.program(5, init="""
        LDA #$10
        STA DF0LOW
        LDA #0
        STA DF0HI
""", body="""
        LDA DF0DATA
        STA $80
        LDA #$FF
        STA CALLFUNCTION
        LDA #$10
        STA DF0LOW
        LDA DF0DATA
        STA $81
        INC M_DONE
        LDA $82
        EOR #1
        STA $82
        BEQ palodd
        STA WSYNC
palodd: LDX #256-60
paldly: STA WSYNC
        INX
        BNE paldly
""", lines=255)
    rom = img.build()
    if classify(rom) != (21, 0):
        sys.exit("pal_dpc: classified as %s" % (classify(rom),))
    open(path, "wb").write(rom)


def meta(img):
    m = {"need": {}}
    p = os.path.splitext(img)[0] + ".meta"
    if os.path.isfile(p):
        for l in open(p):
            f = l.split()
            if f and f[0] == "need" and len(f) == 4:
                m["need"][f[1]] = int(f[3])
            elif f and f[0] == "frames":
                m["frames"] = int(f[1])
    return m


# ---------------------------------------------------------------- runs
DONE = {}


def run(kind, name, args):
    key = (kind, name, tuple(args))
    if key in DONE:
        return DONE[key]
    DONE[key] = r = run1(kind, name, args)
    return r


def run1(kind, name, args):
    d = os.path.join(WORK, "runs", kind, name)
    os.makedirs(d, exist_ok=True)
    rtl = os.path.join(d, "rtl")
    if not os.path.islink(rtl):
        os.symlink(os.path.join(WORK, kind, "rtl"), rtl)
    a = list(args) + (["+arm_div=%s" % ARM_DIV] if kind == "daria" else [])
    with open(os.path.join(d, "run.log"), "w") as log:
        log.write("-- %s %s\n" % (binary(kind), " ".join(a)))
        log.flush()
        try:
            rc = subprocess.run(["nice", "-n", "10", binary(kind)] + a, cwd=d, stdout=log, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, timeout=TIMEOUT).returncode
        except subprocess.TimeoutExpired:
            rc = "timeout (killed after %d s)" % TIMEOUT
    text = open(os.path.join(d, "run.log"), errors="replace").read()
    return parse(text, rc, d)


def parse(text, rc, d):
    s = {"rc": rc, "dir": d, "text": text}
    m = re.search(r"^WIRE summary (.*)$", text, re.M)
    s["sum"] = {}
    if m:
        for kv in m.group(1).split():
            k, v = kv.split("=", 1)
            try:
                s["sum"][k] = float(v) if "." in v else int(v)
            except ValueError:
                s["sum"][k] = v
    s["rel"] = [int(x) for x in re.findall(r"^WIRE release \d+ at clk_sys (\d+)", text, re.M)]
    s["f6end"] = [int(x) for x in re.findall(r"^WIRE f6 end \d+ at clk_sys (\d+)", text, re.M)]
    s["busyfall"] = [int(x) for x in re.findall(r"^WIRE pll_busy falls at clk_sys (\d+)", text, re.M)]
    s["song"] = [int(x) for x in re.findall(r"^WIRE song start (\d+)", text, re.M)]
    s["fatal"] = [l for l in text.splitlines() if "%Fatal" in l or "%Error" in l]
    return s


class Judge:
    """bad: every failed check; keys: the WIRE summary keys of the failed
    checks on a value the run reported; infra: the failures that say nothing
    of the design (the run crashed, timed out, hit a %Fatal or %Error, gave no
    summary, or a judged key is missing from it), which make a mutant's
    verdict ERROR"""
    def __init__(self, name):
        self.name, self.bad, self.keys, self.infra = name, [], [], []

    def ok(self, cond, what, key=None, infra=False):
        if not cond:
            self.bad.append(what)
            if infra:
                self.infra.append(what)
            elif key is not None and key not in self.keys:
                self.keys.append(key)

    def eq(self, s, k, v):
        got = s["sum"].get(k)
        self.ok(got == v, "%s=%s (want %s)" % (k, got, v), key=k, infra=got is None)

    def ge(self, s, k, v):
        got = s["sum"].get(k)
        self.ok(got is not None and got >= v, "%s=%s (want >= %s)" % (k, got, v), key=k, infra=got is None)


def common(j, s):
    j.ok(s["rc"] == 0 and not s["fatal"], "exit %s %s" % (s["rc"], "; ".join(s["fatal"])[:300]), infra=True)
    j.ok(bool(s["sum"]), "no WIRE summary", infra=True)


def daria_health(j, s, guard=True, resets=0, selfcheck=True):
    """resets: how many cart_reset rises may abandon an open call (a console
    reset or the end of a retune; at most one call each). selfcheck: the last
    image is one of fe_dir's, whose RIOT $FE counts its failed self-checks
    (a game's or another image's RIOT RAM means nothing there)"""
    common(j, s)
    for k in ("f6_rst_low", "f6_noib", "f6_live", "f6_busy", "wr_busy", "wr_stop", "halts", "psram_viol", "open_old",
              "orphans") + (("errors",) if selfcheck else ()):
        j.eq(s, k, 0)
    j.ok(s["sum"].get("psram_cs") == 50.0, "psram_cs=%s (want 50.0)" % s["sum"].get("psram_cs"))
    c, ca, r, rf, ab = (s["sum"].get(k, -1) for k in ("calls", "calls_arm", "rets", "rets_fe", "abandoned"))
    j.ok(abs(c - ca) <= 1 and abs(r - rf) <= 1 and 0 <= ab <= resets and 0 <= c - r - ab <= 1,
         "calls %s / at the BupChip %s, returns %s / at daria_fe %s, abandoned %s (at most %d)" % (
             c, ca, r, rf, ab, resets))
    if guard:
        if ARM_DIV == "18":
            j.eq(s, "locked", 1)
            j.eq(s, "unlocks", 0)


def boot(j, s, m):
    """an ARM image loaded once from power-up"""
    daria_health(j, s)
    j.eq(s, "f6", 1); j.eq(s, "f6_win", 1); j.eq(s, "f6_win_dt", 1); j.eq(s, "releases", 1)
    j.ok(len(s["rel"]) == 1 and len(s["f6end"]) == 1 and s["rel"][0] > s["f6end"][0],
         "the console reset released before F6 ended (releases %s, F6 ends %s)" % (s["rel"], s["f6end"]))
    j.ge(s, "calls", m["need"].get("call_accept", 1))
    j.ge(s, "marker", m["need"].get("dir_marker", 1))
    j.eq(s, "hold_rise", 1)


def no_daria(j, s):
    """an image that is not an ARM scheme: daria_fe stays out of it"""
    common(j, s)
    for k in ("f6", "wr_crb", "wr_stb", "hold_rise", "prof_clk", "calls", "psram_viol", "halts"):
        j.eq(s, k, 0)


def same_edge(j, s, p, rel_to_busy=False):
    """the last console reset release on the same clk_sys edge as the plain build's (P6)"""
    if not s["rel"] or not p["rel"]:
        j.ok(False, "no release (DARIA %s, plain %s)" % (s["rel"], p["rel"]))
        return
    a, b = s["rel"][-1], p["rel"][-1]
    if rel_to_busy:
        if not s["busyfall"] or not p["busyfall"]:
            j.ok(False, "no pll_busy fall")
            return
        a, b = a - s["busyfall"][-1], b - p["busyfall"][-1]
    j.ok(a == b and len(s["rel"]) == len(p["rel"]),
         "release edge %s (%d releases) against the plain build's %s (%d)%s" % (
             a, len(s["rel"]), b, len(p["rel"]), " (from pll_busy's fall)" if rel_to_busy else ""))


def pcm_same(j, ours, ref):
    if not ours["song"] or not ref["song"]:
        j.ok(False, "no song start (ours %s, reference %s)" % (ours["song"], ref["song"]))
        return
    r = sh([sys.executable, os.path.join(SIM, "bupchip/s1/pcm_check.py"), os.path.join(ours["dir"], "s.pcm"),
            os.path.join(ref["dir"], "s.pcm"), "--song-start", str(ours["song"][0]), "--ref-start", str(ref["song"][0])])
    out = r.stdout.strip().splitlines()
    m = re.search(r"compared (\d+) song frames", r.stdout)
    j.ok(r.returncode == 0 and "PCM IDENTICAL" in r.stdout and m and int(m.group(1)) >= 2000,
         "PCM: " + (out[-1] if out else r.stderr))
    return out[-1] if out else ""


# ---------------------------------------------------------------- scenarios
def scenarios(img):
    I = lambda n: os.path.join(img, n)
    S = {}
    fw = os.path.isfile(I("bupchip.bin")) and os.path.isfile(I("souper.a78"))

    def arm_boot(name, t, ms=300, extra=()):
        def f():
            s = run("daria", name, ["+image=" + I(t + ".bin"), "+daria=%d" % ms] + list(extra))
            j = Judge(name); boot(j, s, meta(I(t + ".bin")))
            return j, s
        S[name] = (f, "DARIA build: %s boots (F6 at the window close, released once after it, calls return)" % t, True)

    arm_boot("smoke_dpc", "smoke_dpc")
    arm_boot("smoke_cdf", "smoke_cdf")
    arm_boot("digital_cdfj", "digital_cdfj")

    def digital_smp():
        s = run("daria", "digital_cdfj", ["+image=" + I("digital_cdfj.bin"), "+daria=300"])
        j = Judge("digital_cdfj"); boot(j, s, meta(I("digital_cdfj.bin")))
        q, a = s["sum"].get("smp_req", 0), s["sum"].get("smp_ack", 0)
        j.ok(q > 0 and 0 <= q - a <= 1, "sample requests %s, answers %s" % (q, a))
        return j, s
    S["digital_cdfj"] = (digital_smp, "DARIA build: the 64 KB digital image boots; every sample request answered", True)

    def a78(name, image, extra):
        def f():
            s = run("daria", name, ["+image=" + I(image), "+daria=100"] + extra)
            j = Judge(name); no_daria(j, s); j.eq(s, "releases", 1)
            m = re.search(r"2600 mapper (\d+)", s["text"])
            j.ok(m is not None and m.group(1) == "21", "the core's 2600 mapper %s, not 21: the test is void"
                 % (m.group(1) if m else None))
            return j, s
        return f
    S["a78_bs21"] = (a78("a78_bs21", "load_test.a78", ["+bs=21"]),
                     "P5: a 7800 image with the bankswitching override 21 (DPC+): no daria_fe RAM write, no daria_hold", True)
    S["a78_29696"] = (a78("a78_29696", "a78_29696.a78", []),
                      "P5: an A78 of 29,696 bytes (detect2600: DPC+): no daria_fe RAM write, no daria_hold", True)

    def pair(name, args, check, desc, rel_to_busy=False):
        def f():
            s = run("daria", name, args)
            p = run("plain", name, args)
            j = Judge(name)
            common(j, p)
            check(j, s)
            same_edge(j, s, p, rel_to_busy)
            return j, s
        S[name] = (f, desc, True)

    pair("a26", ["+image=" + I("load_test.a26"), "+wav=100"], no_daria,
         "P6: a non-ARM 2600 image from power-up: released on the plain build's edge")

    def second(j, s):
        daria_health(j, s, selfcheck=False)
        j.eq(s, "f6", 1); j.eq(s, "wr_after_load2", 0); j.eq(s, "hold_rise", 1); j.eq(s, "releases", 2)
    pair("dpc_then_a26", ["+image=" + I("smoke_dpc.bin"), "+wav=320", "+image2=" + I("load_test.a26"), "+image2at=150"],
         second, "P6, 7.3: an ARM image, then a non-ARM 2600 image: released on the plain build's edge, "
                 "no daria_fe RAM write after the second load")
    pair("cdf_then_a78", ["+image=" + I("smoke_cdf.bin"), "+wav=320", "+image2=" + I("load_test.a78"), "+image2at=150"],
         second, "P6, 7.3: an ARM image, then a 7800 image: as above")

    def a26_retune(j, s):
        no_daria(j, s); j.eq(s, "releases", 2)
    pair("retune_a26", ["+image=" + I("load_test.a26"), "+wav=200", "+retune=80"], a26_retune,
         "P20: a non-ARM 2600 image retuned: released on the plain build's edge after pll_busy falls",
         rel_to_busy=True)

    def resetat(name, t, short=False):
        def f():
            s = run("daria", name, ["+image=" + I(t + ".bin"), "+wav=300",
                                    "+wire_resetat=120" if short else "+resetat=120"])
            j = Judge(name); daria_health(j, s, resets=1)
            if short:
                j.ok(re.search(r"^WIRE reset_in held for 49 clk_sys", s["text"], re.M) is not None,
                     "no 49 clk_sys reset_in")
            j.eq(s, "f6", 2); j.eq(s, "f6_rst", 1); j.eq(s, "rs_f6", 1); j.eq(s, "rs_f6_rst_low", 0)
            j.eq(s, "releases", 2)
            j.ok(len(s["rel"]) == 2 and len(s["f6end"]) == 2 and s["rel"][1] > s["f6end"][1],
                 "released before the reset's F6 ended (releases %s, F6 ends %s)" % (s["rel"], s["f6end"]))
            j.eq(s, "f6_ram_diff", 0)
            j.ge(s, "calls_rs", 1)
            j.ok(re.search(r"^BOOT 2 vector: .* from the cartridge slot", s["text"], re.M) is not None,
                 "the 6507 did not restart (no BOOT 2 vector line)")
            return j, s
        S[name] = (f, "7.3: a console reset (%s) in an ARM image: one F6, the reset held through it, "
                      "the game restarts" % ("49 clk_sys, the menu's Reset: daria_hold holds it" if short
                                             else "+resetat, 10 ms"), True)
    resetat("resetat_dpc", "hard_reset_call_dpc")
    resetat("resetat_cdf", "hard_reset_call_cdf")
    resetat("resetat_short_dpc", "hard_reset_call_dpc", True)
    resetat("resetat_short_cdf", "hard_reset_call_cdf", True)

    def retune(name, t, at, extra=()):
        def f():
            args = ["+image=" + I(t + ".bin"), "+wav=300"]
            args += ["+retune=%d" % at] if isinstance(at, int) else ["+wire_retune=" + at]
            args += list(extra)
            s = run("daria", name, args)
            j = Judge(name); daria_health(j, s, resets=1)
            for k, v in (("rt_f6", 1), ("rt_f6_early", 0), ("rt_rst_low", 0), ("wr_busy", 0), ("f6_busy", 0),
                         ("f6_live", 0), ("f6_ram_diff", 0), ("f6", 2), ("releases", 2)):
                j.eq(s, k, v)
            j.ok(len(s["rel"]) == 2 and len(s["f6end"]) == 2 and s["rel"][1] > s["f6end"][1],
                 "released before the retune's F6 ended (releases %s, F6 ends %s)" % (s["rel"], s["f6end"]))
            j.ok(len(s["busyfall"]) == 1 and len(s["f6end"]) == 2 and s["f6end"][1] > s["busyfall"][0],
                 "F6 not after pll_busy's fall")
            j.ge(s, "calls_rt", 1)
            if at == "svc":
                # not vacuous: the service ran on into pll_busy_s[1], and
                # atari7800_pocket.sv's daria_we_ok dropped its writes
                j.ge(s, "wr_drop", 1)
            return j, s
        S[name] = (f, "7.3, P20: a PAL/NTSC retune (+retune) mid-game in a busy ARM image: no daria_fe RAM write "
                      "while pll_busy_s[1] or as the clocks stop, one F6 after it, the reset never dips, the RAM as "
                      "at power-up" + ("; it lands in a DPC+ copy-engine service" if at == "svc" else ""), True)
    retune("retune_dpc", "hard_reset_call_dpc", 120)
    retune("retune_cdf", "hard_reset_call_cdf", 120)
    retune("retune_dpc2", "hard_reset_call_dpc", 131)
    retune("retune_svc_dpc", "hard_reset_call_dpc", "svc")
    retune("retune_svc4_dpc", "hard_reset_call_dpc", "svc", ["+wire_retune_k=4"])
    retune("retune_call_dpc", "hard_reset_call_dpc", "call")
    retune("retune_call_cdf", "hard_reset_call_cdf", "call")

    def after_retunes(j, s, f6_n):
        """the F6 that the last retune starts, and none during one"""
        for k, v in (("f6_busy", 0), ("f6_live", 0), ("wr_busy", 0), ("wr_stop", 0), ("f6_ram_diff", 0),
                     ("rt_f6_early", 0), ("rt_rst_low", 0), ("f6", f6_n)):
            j.eq(s, k, v)
        j.ok(len(s["f6end"]) == f6_n and len(s["busyfall"]) >= 1 and s["f6end"][-1] > s["busyfall"][-1],
             "no F6 after pll_busy's last fall (F6 ends %s, falls %s)" % (s["f6end"], s["busyfall"]))
        j.ok(len(s["rel"]) >= 1 and len(s["f6end"]) >= 1 and s["rel"][-1] > s["f6end"][-1],
             "released before the last F6 ended (releases %s, F6 ends %s)" % (s["rel"], s["f6end"]))
        j.ge(s, "calls_rt", 1)

    def twice(name, t, catch):
        def f():
            s = run("daria", name, ["+image=" + I(t + ".bin"), "+wav=300", "+wire_retune=twice",
                                    "+wire_retune_after=120", "+wire_retune_catch=%d" % catch])
            j = Judge(name); daria_health(j, s, resets=1)
            after_retunes(j, s, 2)
            j.eq(s, "rt_f6", 1); j.eq(s, "releases", 2)
            # not vacuous: pll_busy_s saw the one clk_74a gap (catch), or not
            j.ok(len(s["busyfall"]) == (2 if catch else 1),
                 "pll_busy_s[1] falls %s: the gap %s" % (s["busyfall"], "not seen" if catch else "seen"))
            return j, s
        S[name] = (f, "P20: two retunes back to back mid-game, pll_busy low for one clk_74a between, %s: one F6 "
                      "after the second, none during either" % ("a clk_sys edge inside it (pll_busy_s sees it)"
                                                               if catch else "no clk_sys edge inside it"), True)
    twice("twice_dpc", "hard_reset_call_dpc", 1)
    twice("twice_cdf", "hard_reset_call_cdf", 1)
    twice("twice_nc_dpc", "hard_reset_call_dpc", 0)

    # +wire_pll: pll_region in the loop, driven by the core's is_pal_o
    def loadpal(name, t):
        def f():
            s = run("daria", name, ["+image=" + I("load_test_pal.a78"), "+wav=260", "+image2=" + I(t + ".bin"),
                                    "+image2at=40", "+wire_pll"])
            j = Judge(name); daria_health(j, s, resets=1)
            after_retunes(j, s, 2)
            j.eq(s, "retunes", 2); j.eq(s, "b2b", 0); j.eq(s, "is_pal", 0); j.eq(s, "rgn_bad", 0)
            j.eq(s, "f6_pend", 0); j.eq(s, "f6_win", 1); j.eq(s, "f6_rst", 1)
            j.ge(s, "marker", meta(I(t + ".bin"))["need"].get("dir_marker", 1))
            return j, s
        S[name] = (f, "P20, review: the PLL in PAL from a PAL A78, then %s on Auto (pll_region in the loop): the "
                      "retune to NTSC starts after the load's F6, not in it; one F6 after it" % t, True)
    loadpal("loadpal_dpc", "smoke_dpc")
    loadpal("loadpal_cdf", "smoke_cdf")

    def palreset(name, t):
        def f():
            s = run("daria", name, ["+image=" + I("load_test_pal.a78"), "+wav=260", "+image2=" + I(t + ".bin"),
                                    "+image2at=40", "+wire_pll", "+wire_reset_on_pal=2"])
            j = Judge(name); daria_health(j, s, resets=1)
            after_retunes(j, s, 2)
            j.eq(s, "retunes", 2); j.eq(s, "b2b", 0); j.eq(s, "is_pal", 0); j.eq(s, "rgn_bad", 0)
            j.eq(s, "f6_pend", 0); j.eq(s, "f6_win", 1); j.eq(s, "f6_rst", 1); j.eq(s, "rs_f6", 1)
            j.eq(s, "rs_f6_rst_low", 0)
            j.ok(re.search(r"^WIRE reset_in rises as region_pll changes to 0", s["text"], re.M) is not None,
                 "no reset_in as region_pll changed: the test is void")
            j.ge(s, "marker", meta(I(t + ".bin"))["need"].get("dir_marker", 1))
            return j, s
        S[name] = (f, "P20: as loadpal_*, with a console reset (49 clk_sys) rising on the clock where the region "
                      "changes, before pll_busy_s shows the retune: one F6, after the retune", True)
    palreset("palreset_dpc", "smoke_dpc")

    def b57(name, t):
        def f():
            s = run("daria", name, ["+image=" + I(t + ".b57.bin"), "+daria=300", "+wire_pll"])
            j = Judge(name); boot(j, s, meta(I(t + ".bin")))
            j.eq(s, "retunes", 0); j.eq(s, "is_pal", 0); j.eq(s, "rgn_bad", 0); j.eq(s, "f6_pend", 0)
            return j, s
        S[name] = (f, "P20, review: %s with byte 57's bit 0 set (the A78 region byte) from power-up, pll_region in "
                      "the loop: no retune (none to PAL and back across F6)" % t, True)
    b57("b57_dpc", "smoke_dpc")
    b57("b57_cdf", "smoke_cdf")

    # +wire_seq: is_downloading held across a whole load sequence, as core_top.v
    # makes it (the D review's finding 3): a region change that pll_region must
    # hold until allcomplete, and allcomplete where it would land inside an F6
    def seq(name, mode, args, f6_n, releases, is_pal, retunes, desc, rs=True, resets=1, land=None):
        def f():
            s = run("daria", name, list(args) + ["+wire_pll", "+wire_seq=" + mode])
            j = Judge(name); daria_health(j, s, resets=resets)
            after_retunes(j, s, f6_n)
            j.eq(s, "f6_pend", 0); j.eq(s, "retunes", retunes); j.eq(s, "b2b", 0); j.eq(s, "is_pal", is_pal)
            j.eq(s, "releases", releases); j.eq(s, "rgn_bad", 0)
            if rs:
                # the console reset held from reset_in's rise to the end of the F6 after it
                j.eq(s, "rs_f6", 1); j.eq(s, "rs_f6_rst_low", 0)
            if mode == "rfirst":
                # not vacuous: no retune pending at the reset (it comes first), the
                # Region setting lands where only the freeze in an ARM image's console
                # reset holds region_pll, and allcomplete inside the reset's F6
                m = re.search(r"^WIRE seq reset_in rises first[^:]* at [\d.]+ ms: "
                              r"is_pal_o (\d), the PLL (PAL|NTSC), pll_region busy 0, loading 1", s["text"], re.M)
                j.ok(m is not None and int(m.group(1)) == (m.group(2) == "PAL"),
                     "a retune pending at the reset, or no reset (the test is void)")
                j.ok(re.search(r"^WIRE seq the Region setting to PAL at [\d.]+ ms \(reset first[^)]*\): region_pll_hold 0, "
                               r"ARM console reset 1, retune pending 0, pll_busy_s 0", s["text"], re.M) is not None,
                     "the Region setting did not land where only the ARM-console freeze holds region_pll (void)")
                j.ok(re.search(r"^WIRE seq allcomplete at [\d.]+ ms: .*, F6 1$", s["text"], re.M) is not None,
                     "allcomplete not inside the reset's F6 (the test is void)")
            else:
                # not vacuous: at the reset (or the slot's start, or allcomplete with
                # the console running) a retune was pending in pll_region's own view
                # (is_pal_o is not the region the PLL is set to, loading high, not busy)
                m = re.search(r"^WIRE seq (reset_in rises|reset-causing slot starts|cartridge slot starts|"
                              r"allcomplete comes)[^:]* at [\d.]+ ms: "
                              r"is_pal_o (\d), the PLL (PAL|NTSC), pll_region busy 0, loading 1", s["text"], re.M)
                j.ok(m is not None and int(m.group(2)) != (m.group(3) == "PAL"),
                     "no retune pending at the reset or slot (the test is void)")
            if mode == "back":
                # not vacuous: the setting moved back as pll_region started the retune
                # to PAL, before pll_busy_s[1] rose, with the console running, so
                # that only the freeze while a retune is pending holds region_pll
                j.ok(re.search(r"^WIRE seq the Region setting back to Auto at [\d.]+ ms, pll_region retuning: "
                               r"pll_region busy 1 to PAL, pll_busy_s 0, region_pll_hold 0, ARM console reset 0",
                               s["text"], re.M) is not None,
                     "the Region setting did not move back inside the retune's start (the test is void)")
            j.ok(re.search(r"^WIRE seq allcomplete", s["text"], re.M) is not None, "no allcomplete (the test is void)")
            return j, s
        S[name] = (f, "finding 3: " + desc, True)
    seq("seq_menu_dpc", "menu", ["+image=" + I("hard_reset_call_dpc.bin"), "+daria=40"], 2, 2, 1, 1,
        "a load sequence runs (a save slot), the Region setting asks for PAL, the menu's Reset 1 ms later, "
        "allcomplete 30 us after it: the console held from the reset through the retune, one F6 after it, "
        "none while it is pending or under way")
    seq("seq_menu_cdf", "menu", ["+image=" + I("hard_reset_call_cdf.bin"), "+daria=40"], 2, 2, 1, 1,
        "as seq_menu_dpc, a CDF image")
    seq("seq_auto_dpc", "auto", ["+image=" + I("load_test_pal.a78"), "+wav=90", "+image2=" + I("smoke_dpc.bin"),
                                  "+image2at=40"], 2, 3, 0, 2,
        "a PAL A78, then an ARM image as the first slot of a load sequence, Region on Auto: Auto asks for NTSC when "
        "its console is released, the menu's Reset 1 ms later, allcomplete 30 us after it: as seq_menu_dpc")
    seq("seq_tia_dpc", "tia", ["+image=" + I("pal_dpc.bin"), "+daria=1150"], 2, 2, 1, 1,
        "a PAL ARM image on Auto, a load sequence from 500 ms: the TIA's PAL decision asks for PAL, the menu's "
        "Reset 1 ms later, allcomplete 30 us after it: as seq_menu_dpc")
    seq("seq_load_cdf", "load", ["+image=" + I("smoke_cdf.bin"), "+wav=90", "+image2=" + I("smoke_cdf.bin"),
                                  "+image2at=30"], 3, 3, 1, 1,
        "a load sequence runs, the Region setting asks for PAL, an ARM cartridge is the sequence's last slot: no "
        "retune pending at its window-close F6 (allcomplete just before it), one retune after its F6, one F6 "
        "after the retune", rs=False)
    seq("seq_slot_dpc", "slot", ["+image=" + I("hard_reset_call_dpc.bin"), "+daria=40"], 2, 2, 1, 1,
        "a load sequence runs, the Region setting asks for PAL, a short reset-causing slot (0x107) is its last: "
        "the console held from the slot through the retune, one F6 after it, none while the retune is pending or "
        "under way", rs=False)
    seq("seq_rfirst_dpc", "rfirst", ["+image=" + I("hard_reset_call_dpc.bin"), "+daria=40", "+wire_seq_hold_clk=1",
                                      "+wire_seq_ac=60"], 3, 3, 1, 1,
        "a load sequence runs, the menu's Reset with no retune pending, the Region setting to PAL one clk_sys later "
        "(where only the freeze in an ARM image's console reset holds region_pll), allcomplete 60 us after the "
        "reset, inside its F6: no retune then; the region asked for at the release, one retune, one F6 after it")
    seq("seq_back_dpc", "back", ["+image=" + I("hard_reset_call_dpc.bin"), "+daria=40"], 3, 3, 0, 2,
        "a load sequence runs, the Region setting asks for PAL with the console running, allcomplete 1 ms later; as "
        "pll_region starts that retune, the Region setting back to Auto before pll_busy_s shows it (where only the "
        "freeze while a retune is pending holds region_pll): the retune to PAL, its F6, then one to NTSC and its F6, "
        "not back to back", rs=False, resets=2)

    def pal2600():
        args = ["+image=" + I("pal_test.a26"), "+wav=1300", "+wire_pll"]
        s = run("daria", "pal2600", args)
        j = Judge("pal2600"); no_daria(j, s)
        j.eq(s, "retunes", 1); j.eq(s, "b2b", 0); j.eq(s, "is_pal", 1); j.eq(s, "releases", 2)
        j.eq(s, "rgn_bad", 0); j.eq(s, "f6_pend", 0)
        if os.environ.get("PAL2600_PLAIN", "1") == "1":
            p = run("plain", "pal2600", args)
            common(j, p)
            s["note"] = "plain build: retunes=%s b2b=%s releases=%s is_pal=%s" % tuple(
                p["sum"].get(k) for k in ("retunes", "b2b", "releases", "is_pal"))
        return j, s
    S["pal2600"] = (pal2600, "a PAL 2600 image on Auto, pll_region in the loop: one retune, to PAL, once the TIA "
                    "has scored 48 frames (about 1 s), and the game restarts in PAL (the plain build's count is "
                    "reported)", True)

    # The final review's RTL-1, accepted for 2.2.1 as a known minor issue and fixed in the release after it: after
    # a PAL 2600 image the cartridge region is cleared to 0 while the PLL is PAL. During a PAL A78's download, once
    # its header makes it a 7800 cartridge, Auto asks for NTSC (cart_region 0) before byte 57 sets the region to
    # PAL. In 2.2.1's DARIA build region_pll took NTSC, the retune became pending, and the freeze while one is
    # pending (atari7800_pocket.sv's daria_rt_pend) kept region_pll there; pll_region then retuned to NTSC at the
    # load's end and back to PAL after it, two retunes more than the plain build, which makes none. With the fix
    # region_pll follows region_select in an A78's header even with a retune pending (daria_a78_hdr), so it is
    # PAL again before the load ends. The final region is PAL in both. This scenario pins the counts after the
    # 2600's own retune: EXTRA_RETUNES (DARIA 0, plain 0; 2.2.1's DARIA build: NTSC, PAL).
    AT2 = 1000          # ms: the A78's load starts after the 2600's retune to PAL (955 ms on the D fix round's tree)
    EXTRA_RETUNES = {"daria": [], "plain": []}

    def pal2600_a78():
        args = ["+image=" + I("pal_test.a26"), "+wav=1100", "+image2=" + I("load_test_pal.a78"),
                "+image2at=%d" % AT2, "+wire_pll"]
        s = run("daria", "pal2600_a78", args)
        p = run("plain", "pal2600_a78", args)
        j = Judge("pal2600_a78"); no_daria(j, s); common(j, p)
        j.eq(s, "rgn_bad", 0); j.eq(s, "f6_pend", 0); j.eq(s, "wr_after_load2", 0)
        notes = []
        for kind, r in (("daria", s), ("plain", p)):
            rt = [(m.group(1), float(m.group(2))) for m in re.finditer(
                r"^WIRE pll_region retune \d+ to (PAL|NTSC) at clk_sys \d+ \(([\d.]+) ms\)", r["text"], re.M)]
            j.ok(r["sum"].get("retunes") == len(rt), "%s: retunes=%s, %d retune lines" % (kind, r["sum"].get("retunes"), len(rt)),
                 key="retunes", infra=r["sum"].get("retunes") is None)
            # the 2600's retune to PAL comes first, before the A78's load
            j.ok(bool(rt) and rt[0][0] == "PAL" and rt[0][1] < AT2,
                 "%s: the first retune %s, not the 2600's to PAL before %d ms (the test is void)" % (
                     kind, rt[0] if rt else None, AT2))
            extra = [t for t, _ in rt[1:]]
            j.ok(extra == EXTRA_RETUNES[kind], "%s: retunes after the PAL 2600's: %s (pinned: %s; RTL-1)" % (
                kind, extra or "none", EXTRA_RETUNES[kind] or "none"), key="retunes")
            j.ok(r["sum"].get("is_pal") == 1, "%s: is_pal=%s at the end (want 1: the A78 is PAL)" % (
                kind, r["sum"].get("is_pal")), key="is_pal")
            j.ok(r["sum"].get("b2b") == 0, "%s: b2b=%s (want 0)" % (kind, r["sum"].get("b2b")), key="b2b")
            j.ok(re.search(r"^IMAGE2 .* loaded at", r["text"], re.M) is not None, "%s: no IMAGE2 line: the A78 was not "
                 "loaded (the test is void)" % kind)
            notes.append("%s: retunes %s, releases %s" % (kind, " ".join("%s@%.3fms" % x for x in rt) or "none",
                                                          r["sum"].get("releases")))
        s["note"] = "; ".join(notes)
        return j, s
    S["pal2600_a78"] = (pal2600_a78, "RTL-1 (fixed after 2.2.1): a PAL 2600 image, then a PAL A78 on Auto, pll_region "
                        "in the loop: after the 2600's retune to PAL, neither build retunes again (2.2.1's DARIA build "
                        "retuned twice more, to NTSC, then PAL); both end in PAL", True)

    def pal_arm():
        s = run("daria", "pal_dpc", ["+image=" + I("pal_dpc.bin"), "+daria=1300", "+wire_pll"])
        j = Judge("pal_dpc"); daria_health(j, s, resets=1)
        after_retunes(j, s, 2)
        j.eq(s, "retunes", 1); j.eq(s, "b2b", 0); j.eq(s, "is_pal", 1); j.eq(s, "releases", 2)
        j.eq(s, "rgn_bad", 0); j.eq(s, "f6_pend", 0); j.eq(s, "f6_win", 1); j.eq(s, "f6_rst", 1)
        j.ge(s, "marker", 3)
        return j, s
    S["pal_dpc"] = (pal_arm, "P20: a PAL DPC+ image on Auto (smoke_dpc in PAL frames), pll_region in the loop: one "
                    "retune, to PAL, once the TIA has scored 48 frames, one F6 after it, the game restarts in PAL", True)

    if BIOS and os.path.isfile(BIOS):
        def bios(name, t):
            def f():
                s = run("daria", name, ["+image=" + I(t + ".bin"), "+daria=300", "+bios=" + BIOS, "+skipbios=0"])
                j = Judge(name); boot(j, s, meta(I(t + ".bin")))
                j.ok(re.search(r"^BOOT 1 at \d+ ms: use_bios 0, bypass_bios 1, tia_mode 1, cart_present 1$", s["text"], re.M)
                     is not None, "BOOT 1 line: the BIOS switch")
                j.ok(re.search(r"^BOOT 1 after \d+ ms: 0 CPU reads from the BIOS ROM, tia_en 1$", s["text"], re.M)
                     is not None, "BOOT 1: the BIOS ran")
                return j, s
            S[name] = (f, "7.3, decision 11: the BIOS loaded, Skip BIOS off: an ARM image boots without it", True)
        bios("bios_dpc", "smoke_dpc")
        bios("bios_cdf", "smoke_cdf")
    else:
        S["bios_dpc"] = S["bios_cdf"] = (None, "decision 11 (needs BIOS=FILE)", False)

    if fw:
        def souper_ref():
            s = run("daria", "souper_ref", ["+image=" + I("souper.a78"), "+bupfw=" + I("bupchip.bin"), "+wav=330",
                                            "+wire_pcm=s.pcm"])
            j = Judge("souper_ref"); common(j, s); j.eq(s, "wr_crb", 0); j.eq(s, "f6", 0)
            j.ok(len(s["song"]) == 1, "no song start")
            return j, s
        S["souper_ref"] = (souper_ref, "the Souper cartridge loaded first (the reference for the two below)", True)

        def souper_bs21():
            ref = run("daria", "souper_ref", ["+image=" + I("souper.a78"), "+bupfw=" + I("bupchip.bin"), "+wav=330",
                                              "+wire_pcm=s.pcm"])
            s = run("daria", "souper_bs21", ["+image=" + I("souper.a78"), "+bupfw=" + I("bupchip.bin"), "+wav=330",
                                             "+wire_pcm=s.pcm", "+bs=21"])
            j = Judge("souper_bs21"); common(j, s)
            for k in ("f6", "wr_crb", "wr_stb", "hold_rise", "prof_clk"):
                j.eq(s, k, 0)
            m = re.search(r"2600 mapper (\d+)", s["text"])
            j.ok(m is not None and m.group(1) == "21", "the core's 2600 mapper %s, not 21: the test is void"
                 % (m.group(1) if m else None))
            pcm_same(j, s, ref)
            return j, s
        S["souper_bs21"] = (souper_bs21, "P5: the Souper cartridge with the bankswitching override 21: the BupChip "
                            "stays in its Souper profile (daria_profile 0), the song PCM-identical", True)

        def arm_then_souper():
            ref = run("daria", "souper_ref", ["+image=" + I("souper.a78"), "+bupfw=" + I("bupchip.bin"), "+wav=330",
                                              "+wire_pcm=s.pcm"])
            args = ["+image=" + I("smoke_dpc.bin"), "+bupfw=" + I("bupchip.bin"), "+wav=520",
                    "+image2=" + I("souper.a78"), "+image2at=40", "+wire_pcm=s.pcm"]
            s = run("daria", "dpc_then_souper", args)
            p = run("plain", "dpc_then_souper", args)
            j = Judge("dpc_then_souper"); common(j, p); second(j, s); same_edge(j, s, p)
            pcm_same(j, s, ref)
            return j, s
        S["dpc_then_souper"] = (arm_then_souper, "7.3: an ARM image, then the Souper cartridge: released on the plain "
                                "build's edge, no daria_fe RAM write after, the song PCM-identical to its first-load run", True)

        def souper_then_arm():
            ref = run("daria", "souper_ref", ["+image=" + I("souper.a78"), "+bupfw=" + I("bupchip.bin"), "+wav=330",
                                              "+wire_pcm=s.pcm"])
            s = run("daria", "souper_then_cdf", ["+image=" + I("souper.a78"), "+bupfw=" + I("bupchip.bin"), "+wav=420",
                                                 "+image2=" + I("smoke_cdf.bin"), "+image2at=150", "+wire_pcm=s.pcm"])
            j = Judge("souper_then_cdf"); daria_health(j, s)
            j.eq(s, "f6", 1); j.eq(s, "f6_win", 1); j.eq(s, "f6_win_dt", 1); j.eq(s, "releases", 2)
            j.ok(len(s["rel"]) == 2 and len(s["f6end"]) == 1 and s["rel"][1] > s["f6end"][0], "released before F6 ended")
            j.ge(s, "calls", 1); j.ge(s, "marker", 3)
            pcm_same(j, s, ref)
            return j, s
        S["souper_then_cdf"] = (souper_then_arm, "7.3: the Souper cartridge, then an ARM image: it boots; the song "
                                "PCM-identical to its first-load run up to the second load", True)
    else:
        for n in ("souper_ref", "souper_bs21", "dpc_then_souper", "souper_then_cdf"):
            S[n] = (None, "Souper second loads (needs the BupChip firmware, BUPFW=FILE)", False)

    tp = os.path.join(GAMES, TURBO) if GAMES else ""
    if tp and os.path.isfile(tp):
        def turbo():
            s = run("daria", "turbo", ["+image=" + tp, "+daria=1200"])
            j = Judge("turbo"); daria_health(j, s, selfcheck=False)
            j.eq(s, "f6", 1); j.eq(s, "f6_win_dt", 1); j.ge(s, "calls", 1); j.ge(s, "misses", 1)
            return j, s
        S["turbo"] = (turbo, "7.3: Turbo (CDFJ+, 128 KB) beyond the 64 KB window: calls return, cache misses, "
                      "0 PSRAM violations", True)
    else:
        S["turbo"] = (None, "Turbo beyond the window (needs GAMES=DIR with %s)" % TURBO, False)

    if os.environ.get("DIRECTED") == "1":
        for mp in sorted(f for f in os.listdir(img) if f.endswith(".meta")):
            t = mp[:-5]
            m = meta(I(t + ".bin"))
            ms = 17 * (m.get("frames", 4) + 6)

            def f(t=t, m=m, ms=ms):
                s = run("daria", "dir_" + t, ["+image=" + I(t + ".bin"), "+daria=%d" % ms])
                j = Judge("dir_" + t); daria_health(j, s)
                j.eq(s, "f6", 1); j.eq(s, "f6_win_dt", 1)
                j.ge(s, "marker", m["need"].get("dir_marker", 1))
                return j, s
            S["dir_" + t] = (f, "7.3 whole-core directed set: %s (its self-checks, markers, calls)" % t, True)
    return S


# ---------------------------------------------------------------- mutants
# atari7800_pocket.sv's fixes of the D review's findings 3 and 5, each mutant
# undoing one of their parts: (the text, its replacement)
MUTANTS = {
    # cart_reset not masked while a retune is pending: a console reset then
    # starts F6, and allcomplete can start the retune inside it
    "nomask": ("wire daria_rt_mask = pll_busy_s[1] | (daria_rt_cnt[3:2] == 2'b11) | daria_rt_pend;\n",
               "wire daria_rt_mask = pll_busy_s[1] | (daria_rt_cnt[3:2] == 2'b11);\n"),
    # no withdrawal during a 2600 download: a retune pending from earlier in
    # the sequence starts at allcomplete, inside the window-close F6
    "nowd": ("\t\tif ((cart_download | old_cart_download) & ~cart_is_7800)\n\t\t\tregion_pll <= daria_rgn_nx;\n",
             "\t\tif (1'b0)\n\t\t\tregion_pll <= daria_rgn_nx;\n"),
    # a console reset during a pending retune not held to the retune: the
    # 6507 restarts without F6, then again after the retune's F6
    "nohold": ("\t\t(daria_rt_pend & reset & daria_arm);\n", "\t\t1'b0;\n"),
    # region_pll not frozen while a retune is pending: a Region setting moved
    # as pll_region starts a retune (before pll_busy_s shows it) reaches
    # region_pll, daria_rgn takes it from a retune to the other region, and
    # pll_region starts a second retune as the first ends (seq_back_dpc)
    "nofrzpend": ("else if (!region_pll_hold && (!daria_rt_pend || daria_a78_hdr) && !(daria_reset & daria_arm))",
                  "else if (!region_pll_hold && !(daria_reset & daria_arm))"),
    # region_pll not frozen while an ARM image's console is in reset: a region
    # change on the clock after the reset rises (before tia_en falls) becomes
    # pending after daria_fe saw the reset rise, so the reset's F6 runs, and
    # allcomplete starts the retune inside it, with no F6 after it (seq_rfirst_dpc)
    "nofrzarm": ("else if (!region_pll_hold && (!daria_rt_pend || daria_a78_hdr) && !(daria_reset & daria_arm))",
                 "else if (!region_pll_hold && (!daria_rt_pend || daria_a78_hdr))"),
    # finding 5 undone: daria_mmio's timer rate (bupchip's daria_pal) from the
    # Region setting, not from the region the PLL runs at; it differs while a
    # retune waits for a load sequence's end (seq_*: rgn_bad)
    "palsel": (".daria_pal      (daria_rgn),", ".daria_pal      (region_select),"),
    # the region asked for (region_pll, is_pal_o) instead of the one the PLL
    # last took: it differs from the PLL's while a retune is pending
    "palpll": (".daria_pal      (daria_rgn),", ".daria_pal      (region_pll),"),
}
SEQ_MUT = ["seq_menu_dpc", "seq_auto_dpc", "seq_load_cdf", "seq_slot_dpc", "seq_rfirst_dpc", "seq_back_dpc"]
# plan 7.2: the scenarios that catch each mutant, and the WIRE summary keys
# they catch it on; each of these scenarios that runs must fail on one of
# the keys (verdict)
CATCH = {
    "nomask": (("seq_menu_dpc", "seq_auto_dpc", "seq_slot_dpc"), ("f6_busy", "wr_busy", "f6_live")),
    "nowd": (("seq_load_cdf",), ("rt_f6_early", "f6")),
    "nohold": (("seq_menu_dpc", "seq_auto_dpc", "seq_slot_dpc"), ("releases", "rs_f6_rst_low")),
    "nofrzarm": (("seq_rfirst_dpc",), ("f6_busy", "f6")),
    "nofrzpend": (("seq_back_dpc",), ("b2b", "f6")),
    "palsel": (tuple(SEQ_MUT) + ("pal_dpc",), ("rgn_bad",)),
    "palpll": (("seq_menu_dpc", "seq_auto_dpc", "seq_load_cdf", "seq_slot_dpc", "seq_back_dpc"), ("rgn_bad",)),
}
assert set(CATCH) == set(MUTANTS), "every mutant needs its CATCH entry"


def records(path):
    """the JSON lines WIRE_JSON collected; a scenario's last one counts"""
    recs = {}
    if os.path.isfile(path):
        for l in open(path):
            if l.strip():
                r = json.loads(l)
                recs[r["name"]] = r
    return recs


def verdict(name, names, recs):
    """(exit status, text): 0 CAUGHT, 1 NOT CAUGHT, 2 ERROR (wire.py verdict)"""
    scn, keys = CATCH[name]
    err = []
    for n in names:
        r = recs.get(n)
        if r is None:
            err.append("%s: no result (its run ended early)" % n)
        elif r["infra"]:
            err.append("%s: %s" % (n, "; ".join(r["infra"])[:240]))
    if err:
        return 2, "ERROR (" + " | ".join(err) + ")"
    ran = [n for n in names if n in scn and recs[n]["result"] in ("PASS", "FAIL")]
    if not ran:
        return 2, "ERROR (none of the scenarios that catch it ran: %s)" % ", ".join(scn)
    hit = {n: [k for k in recs[n]["keys"] if k in keys] for n in ran}
    missed = [n for n in ran if not hit[n]]
    if missed:
        return 1, "NOT CAUGHT: %s %s not fail on %s" % (", ".join(missed), "does" if len(missed) == 1 else "do",
                                                    " or ".join(keys)) + (
            "; caught by %s" % ", ".join(n for n in ran if hit[n]) if len(missed) < len(ran) else "")
    return 0, "CAUGHT by %s" % ", ".join("%s (%s)" % (n, ", ".join(hit[n])) for n in ran)


def mutant(name, names):
    """build and run a mutant; its verdict (exit 0, 1 or 2) as verdict()'s"""
    if name not in MUTANTS:
        print("MUTANT %s: ERROR (unknown; the mutants: %s)" % (name, ", ".join(sorted(MUTANTS))), flush=True)
        return 2
    scn = CATCH[name][0]
    S = scenarios(images())
    bad = [n for n in names if n not in S]
    if bad:
        print("MUTANT %s: ERROR (unknown scenario %s)" % (name, ", ".join(bad)), flush=True)
        return 2
    names = [n for n in names if n in scn] if names else list(scn)
    if not names:
        print("MUTANT %s: ERROR (none of the scenarios that catch it, %s, among those named)" % (name, ", ".join(scn)),
              flush=True)
        return 2
    print("-- mutant %s: scenarios %s" % (name, " ".join(names)), flush=True)
    d = os.path.join(WORK, "mut_" + name)
    tree = os.path.join(d, "tree")
    files = sh(["git", "-C", RTL_TREE, "ls-files", "src/fpga"]).stdout.split()
    for f in files:
        dst = os.path.join(tree, f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(RTL_TREE, f), dst)
    p = os.path.join(tree, "src/fpga/core/atari7800_pocket.sv")
    t = open(p).read()
    old, new = MUTANTS[name]
    if t.count(old) != 1:
        print("MUTANT %s: ERROR (its text is not in %s once)" % (name, p), flush=True)
        return 2
    open(p, "w").write(t.replace(old, new))
    print("-- mutant %s: atari7800_pocket.sv mutated in %s (from %s)" % (name, tree, RTL_TREE), flush=True)
    env = dict(os.environ, WORK=d, RTL_TREE=tree)
    me = os.path.abspath(__file__)
    r = subprocess.run([sys.executable, me, "build", "daria"], env=env, capture_output=True, text=True)
    open(os.path.join(d, "build.log"), "w").write(r.stdout + r.stderr)
    if r.returncode:
        print("MUTANT %s: ERROR (build failed: %s)" % (name, os.path.join(d, "build.log")), flush=True)
        return 2
    js = os.path.join(d, "results.json")
    if os.path.exists(js):
        os.remove(js)
    env["WIRE_JSON"] = js
    r = subprocess.run([sys.executable, me, "run"] + names, env=env, capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode not in (0, 1, 3) or "Traceback" in r.stderr:
        sys.stdout.write(r.stderr[-3000:])
    print("-- wire.py run exit %d; records in %s" % (r.returncode, js))
    rc, why = verdict(name, names, records(js))
    print("MUTANT %s: %s" % (name, why), flush=True)
    return rc


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    os.makedirs(WORK, exist_ok=True)
    if cmd == "mutant":
        if len(sys.argv) < 3:
            sys.exit("wire.py mutant NAME [SCENARIO ...] (%s)" % ", ".join(sorted(MUTANTS)))
        header()
        return mutant(sys.argv[2], sys.argv[3:])
    if cmd == "verdict":
        if len(sys.argv) < 4 or sys.argv[2] not in CATCH:
            sys.exit("wire.py verdict NAME FILE [SCENARIO ...] (%s)" % ", ".join(sorted(CATCH)))
        rc, why = verdict(sys.argv[2], sys.argv[4:] or CATCH[sys.argv[2]][0], records(sys.argv[3]))
        print("MUTANT %s: %s" % (sys.argv[2], why))
        return rc
    if cmd == "build":
        header()
        for k in (sys.argv[2:] or ("daria", "plain")):
            build(k)
        return 0
    img = images()
    S = scenarios(img)
    if cmd == "list":
        for n, (f, d, av) in S.items():
            print("%-18s %s%s" % (n, d, "" if av else "  [NOT AVAILABLE]"))
        return 0
    header()
    for k in ("daria", "plain"):
        if os.path.isfile(binary(k)):
            print("-- binary %s md5 %s" % (binary(k), md5(binary(k))))
        else:
            print("-- no %s (wire.py build %s): its scenarios fail" % (binary(k), k))
    names = sys.argv[2:] or list(S)
    for n in names:
        if n not in S:
            sys.exit("unknown scenario %s" % n)
    rc = 0
    res = open(os.path.join(WORK, "results.txt"), "a")
    js = open(os.environ["WIRE_JSON"], "a") if os.environ.get("WIRE_JSON") else None
    for n in names:
        f, d, av = S[n]
        rec = {"name": n, "result": "NOT RUN", "bad": [], "keys": [], "infra": []}
        if not av:
            line = "NOT RUN %-18s %s" % (n, d)
            rc = rc or 3
        else:
            j, s = f()
            rec.update(result="FAIL" if j.bad else "PASS", bad=j.bad, keys=j.keys, infra=j.infra)
            line = ("PASS    %-18s" % n) if not j.bad else ("FAIL    %-18s %s" % (n, "; ".join(j.bad)))
            if j.bad:
                rc = 1
            sm = s.get("sum", {})
            keys = ("releases f6 f6_win_dt calls rets abandoned smp_req misses wr_crb wr_busy wr_stop wr_drop hold_rise "
                    "prof_clk rt_f6 rs_f6 retunes b2b is_pal f6_pend rgn_bad "
                    "marker errors psram_viol locked unlocks").split()
            line += "\n        " + " ".join("%s=%s" % (k, sm.get(k)) for k in keys if k in sm)
            if s.get("note"):
                line += "\n        " + s["note"]
        print(line, flush=True)
        res.write(line + "\n")
        res.flush()
        if js:
            js.write(json.dumps(rec) + "\n")
            js.flush()
    print("VERDICT %s" % {0: "PASS", 1: "FAIL", 3: "INCOMPLETE (some scenarios not run)"}[rc])
    return rc


if __name__ == "__main__":
    sys.exit(main())
