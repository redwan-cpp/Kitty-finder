#!/usr/bin/env python3 -I
"""Compare two bench.py results: spike/bench-compare.py baseline tuned"""
import json, os, sys

here = os.path.dirname(os.path.abspath(__file__))
a_name, b_name = sys.argv[1], sys.argv[2]
a = json.load(open(os.path.join(here, f"bench-{a_name}.json")))
b = json.load(open(os.path.join(here, f"bench-{b_name}.json")))
width = max(map(len, a))
print(f"{'':<{width}}  {a_name:>9}  {b_name:>9}  change")
for k in a:
    if k not in b:
        continue
    x, y = a[k], b[k]
    change = f"{x / y:5.1f}× faster" if y < x * 0.9 else (f"{y / x:5.1f}× slower" if y > x * 1.1 else "  same")
    print(f"{k:<{width}}  {x:8.2f}s  {y:8.2f}s  {change}")
