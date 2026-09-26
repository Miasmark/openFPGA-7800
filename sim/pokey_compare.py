#!/usr/bin/env python3
"""Compare tb_pokey output (rtl_<AUDC>.txt) with pokey_model.py (model_<AUDC>.txt)."""
import sys
m = sys.argv[1]
r = dict(tuple(map(int, l.split()[1:])) for l in open(f"rtl_{m}.txt"))
o = dict(tuple(map(int, l.split()[1:])) for l in open(f"model_{m}.txt"))
bad = [(f, r.get(f), o[f]) for f in range(256)
       if r.get(f) is None or abs(r[f] - o[f]) > max(2, o[f] * 0.02)]
print(f"AUDC=${m}: {256 - len(bad)}/256 AUDF values match the model")
for f, a, b in bad[:30]:
    print(f"   AUDF {f:3d}: RTL {a} transitions, model {b}")
