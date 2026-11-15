"""Summarise an xctrace time-profile export: which functions the main thread spent its time in.
Prints the app's own functions (inclusive) and the heaviest frames overall."""
import sys, collections, xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
ids = {}
for el in root.iter():
    i = el.get("id")
    if i: ids[i] = el

def res(el):
    r = el.get("ref")
    return ids.get(r, el) if r else el

own, any_ = collections.Counter(), collections.Counter()
total = 0
for row in root.iter("row"):
    th = row.find("thread")
    if th is None: continue
    th = res(th)
    if "Main" not in (th.get("fmt") or "") and "main" not in (th.get("fmt") or ""): continue
    bt = row.find("backtrace")
    if bt is None: continue
    bt = res(bt)
    total += 1
    seen = set()
    for fr in bt.findall("frame"):
        fr = res(fr)
        name = fr.get("name") or "?"
        b = fr.find("binary")
        bn = res(b).get("name") if b is not None else ""
        key = (name[:150], bn)
        if key in seen: continue
        seen.add(key)
        any_[key] += 1
        if bn.startswith("Solar"): own[key] += 1
print("main thread samples", total)
print("--- Solar's own functions (inclusive samples)")
for (n, b), c in own.most_common(40): print(f"{c:6d}  {n}")
print("--- heaviest frames overall")
for (n, b), c in any_.most_common(40): print(f"{c:6d}  {b:20.20s} {n}")
