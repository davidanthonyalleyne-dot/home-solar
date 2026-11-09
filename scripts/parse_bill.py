"""Reads a Toronto Hydro bill PDF into the same shape as an entry in data/bills.json.

Uses pdftotext -layout. Only numbers are kept: no name, address or account number.
A bill that doesn't add up the way the printed one does is refused, so nothing
half-read ever reaches the app.

    python3 scripts/parse_bill.py some-bill.pdf   # prints the entry and whether it checks out
"""
import datetime as dt
import json
import re
import subprocess
import sys

MONTHS = {m: i + 1 for i, m in enumerate("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC".split())}
PERIOD = {"On-peak": "on", "Mid-peak": "mid", "Off-peak": "off"}


def _date(s):
    m = re.match(r"([A-Za-z]{3})\s+(\d{1,2})\s+(\d{4})", s.strip())
    return dt.date(int(m.group(3)), MONTHS[m.group(1).upper()], int(m.group(2)))


def _money(s):
    return float(s.replace(",", "").replace("$", ""))


def text_of(pdf_path):
    return subprocess.run(["pdftotext", "-layout", pdf_path, "-"], capture_output=True, text=True, check=True).stdout


def parse(text, earlier=()):
    """Returns (bill, problems). earlier: bills already stored, to line up the start date."""
    first = lambda pat: (re.search(pat, text, re.M) or [None, None])[1]
    bill = {}
    bill["statement"] = _date(first(r"Statement Date\s+([A-Za-z]{3} \d{2} \d{4})")).isoformat()

    # meter reading period; older bills count from the previous reading, newer ones from the day after
    m = re.search(r"([A-Z]{3} \d{2} \d{4}) TO ([A-Z]{3} \d{2} \d{4})", text)
    start, end = _date(m.group(1)), _date(m.group(2))
    prev = max((b for b in earlier if b["to"] < end.isoformat()), key=lambda b: b["to"], default=None)
    if prev and 0 <= (start - dt.date.fromisoformat(prev["to"])).days <= 1:
        start = dt.date.fromisoformat(prev["to"])
    bill["from"], bill["to"] = start.isoformat(), end.isoformat()

    seasons = re.findall(r"Time of use - (Summer|Winter)", text)
    bill["season"] = (seasons[-1] if seasons else "Summer").lower()

    # time-of-use lines; a bill that spans a price change lists each period twice, so add them up
    buy, credit = {}, {}
    for k, label, rate, amt, cr in re.findall(
            r"^\s*([\d,]+\.\d+) kWh (On-peak|Mid-peak|Off-peak)[^@]*@ \$(-?[\d.]+) / kWh\s+([\d,]+\.\d{2})( CR)?", text, re.M):
        side = credit if rate.startswith("-") else buy
        p = PERIOD[label]
        side.setdefault(p, []).append((float(k.replace(",", "")), abs(float(rate))))

    def merge(lines):
        # one line: the printed rate; a price change mid-bill: the kWh-weighted rate
        k = sum(x for x, _ in lines)
        if len(lines) == 1:
            return [round(k, 3), lines[0][1]]
        return [round(k, 3), round(sum(x * r for x, r in lines) / k, 6) if k else lines[-1][1]]
    bill["buy"] = {p: merge(buy.get(p, [(0.0, 0.0)])) for p in ("on", "mid", "off")}
    # a period with nothing sent back still carries its price, as on the stored bills
    bill["credit"] = {p: merge(credit[p]) if p in credit else [0, bill["buy"][p][1]] for p in ("on", "mid", "off")}

    bill["used"] = round(sum(k for k, _ in bill["buy"].values()), 3)
    gen = first(r"Generated\s*\n\s*[\d.]+\s+[\d.]+\s+([\d,]+\.\d+)")
    bill["generated"] = float(gen.replace(",", "")) if gen else round(sum(k for k, _ in bill["credit"].values()), 3)
    if bill["generated"] == 0:
        bill["generated"] = 0

    amt = lambda label: sum(_money(x) for x in re.findall(rf"^\s*{label}\s+([\d,]+\.\d{{2}})", text, re.M))
    bill["delivery"] = round(amt("Delivery"), 2)
    bill["regulatory"] = round(amt("Regulatory"), 2)
    bill["electricity"] = _money(first(r"Your Total Electricity Charges\s+([\d,]+\.\d{2})"))
    bill["hst"] = _money(first(r"H\.S\.T\.[^\n]*?\s([\d,]+\.\d{2})") or "0")
    bill["rebate"] = _money(first(r"Ontario Electricity Rebate\s+([\d,]+\.\d{2})") or "0")
    bf = re.search(r"Balance Forward\s+([\d,]+\.\d{2})( CR)?", text)
    bill["previous"] = (-1 if bf and bf.group(2) else 1) * _money(bf.group(1)) if bf else 0.0
    bill["due"] = _money(first(r"Total Amount Due[^$\n]*\$([\d,]+\.\d{2})"))
    # anything else on the bill (a one-time charge, say) is what's left over
    other = round(bill["due"] - (bill["electricity"] + bill["hst"] - bill["rebate"] + bill["previous"]), 2)
    bill["other"] = other if abs(other) >= 0.02 else 0
    bill = {k: bill[k] for k in ("statement", "from", "to", "season", "used", "generated", "buy", "credit",
                                 "delivery", "regulatory", "electricity", "other", "hst", "rebate", "previous", "due")}
    return bill, check(bill)


def check(b):
    """The same sums as scripts/check_bills.py."""
    buy = sum(round(k * r, 2) for k, r in b["buy"].values())
    cred = sum(round(k * r, 2) for k, r in b["credit"].values())
    elec = round(buy - cred + b["delivery"] + b["regulatory"], 2)
    problems = []
    if abs(elec - b["electricity"]) > 0.05:
        problems.append(f"electricity lines add to {elec}, bill says {b['electricity']}")
    if b["used"] <= 0:
        problems.append("no electricity lines found")
    if b["other"] and abs(b["other"]) > 100:
        problems.append(f"{b['other']} left over after the listed charges")
    return problems


if __name__ == "__main__":
    from pathlib import Path
    earlier = json.loads((Path(__file__).resolve().parent.parent / "data/bills.json").read_text())["bills"]
    for f in sys.argv[1:]:
        b, problems = parse(text_of(f), earlier)
        print(json.dumps(b))
        print("  ->", "ok" if not problems else "; ".join(problems))
