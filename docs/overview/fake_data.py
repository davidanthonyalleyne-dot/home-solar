"""Makes the sample data for the overview screenshots: every energy and money figure is
scaled and jittered, so the pictures look real without showing the household's numbers.

    python3 docs/overview/fake_data.py real-data.json sample-data.json
"""
import json
import random
import sys

random.seed(7)
F = 0.63  # overall scale
KEEP = {"peakKw", "buyRate", "avoidedRate", "creditRate", "hst", "iter", "off", "watts", "count", "acKw", "dcKw",
        "fixed", "perKwh", "reg", "strings"}


def fake(x, key=""):
    if isinstance(x, dict):
        return {k: (v if k in KEEP else fake(v, k)) for k, v in x.items()}
    if isinstance(x, list):
        # [kWh, rate] pairs on bills keep their rate
        if key in ("on", "mid", "off") and len(x) == 2:
            return [fake(x[0]), x[1]]
        return [fake(v, key) for v in x]
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        return x
    return round(x * F * random.uniform(0.9, 1.1), 2)


d = json.load(open(sys.argv[1]))
for k in ("hydro", "bills", "money", "gridMonthly", "uploads"):
    if k in d:
        d[k] = fake(d[k], k)
s = d.get("solar") or {}
for k in ("daily", "lifetimeBase", "lifetimeBaseToday", "today", "month", "year", "lifetime", "nowKw", "benefits"):
    if k in s:
        s[k] = fake(s[k], k)
if s.get("todayCurve"):
    s["todayCurve"] = [[t, round(kw * F, 3)] for t, kw in s["todayCurve"]]
s["lifetime"] = s.get("lifetimeBase", s.get("lifetime"))
if d.get("system"):
    d["system"]["private"] = {}
json.dump(d, open(sys.argv[2], "w"))
print("sample data written to", sys.argv[2])
