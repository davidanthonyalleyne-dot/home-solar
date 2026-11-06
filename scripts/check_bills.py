"""Checks each bill in data/bills.json adds up the way the printed bill does.
Run it after typing in a new bill: python3 scripts/check_bills.py"""
import json
import sys
from pathlib import Path

bills = json.loads((Path(__file__).resolve().parent.parent / "data/bills.json").read_text())["bills"]
bad = 0
for b in bills:
    buy = sum(round(k * r, 2) for k, r in b["buy"].values())
    cred = sum(round(k * r, 2) for k, r in b["credit"].values())
    elec = round(buy - cred + b["delivery"] + b["regulatory"], 2)
    due = round(b["electricity"] + b["other"] + b["hst"] - b["rebate"] + b["previous"], 2)
    kwh = round(sum(k for k, _ in b["buy"].values()), 3)
    gen = round(sum(k for k, _ in b["credit"].values()), 3)
    problems = []
    if abs(elec - b["electricity"]) > 0.05: problems.append(f"electricity lines add to {elec}, bill says {b['electricity']}")
    if abs(due - b["due"]) > 0.02: problems.append(f"amount due works out to {due}, bill says {b['due']}")
    if abs(kwh - b["used"]) > 0.05: problems.append(f"bought kWh add to {kwh}, bill says {b['used']}")
    if abs(gen - b["generated"]) > 0.05: problems.append(f"credited kWh add to {gen}, bill says {b['generated']}")
    print(f"{b['to']}: {'ok' if not problems else '; '.join(problems)}")
    bad += bool(problems)
sys.exit(1 if bad else 0)
