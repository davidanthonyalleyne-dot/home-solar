"""What the grid costs and what solar saves, month by month.

Where a Toronto Hydro bill covers the month, the grid cost is the bill's own
charges. Otherwise it is estimated from your meter data with Ontario's net
metering rules (O. Reg. 541/05), which your bills follow to the cent:

  energy      kWh bought at time-of-use prices, less a credit for each kWh sent
              back at the price of the period it was sent in
  delivery    a fixed monthly part, plus a per-kWh part charged on NET kWh
              (bought minus sent back), so exports earn a delivery credit too
  regulatory  per NET kWh, the same way
  HST         13% of the charges before the delivery credit and energy credit
  rebate      the Ontario Electricity Rebate, a share of the electricity line
              after all credits
  carry-over  if credits ever exceed a month's electricity charges, the excess
              carries forward and is written off after 12 months

Solar savings are what the same month would have cost with no panels (every kWh
the house used bought from the grid) minus what it did cost, both worked out
with the same rules so modelling error doesn't leak into the saving.
"""
import datetime as dt
from collections import defaultdict

# Ontario Regulated Price Plan, $/kWh: (from date, off, mid, on)
TOU_PRICES = [
    ("2022-11-01", 0.074, 0.102, 0.151),
    ("2023-11-01", 0.087, 0.122, 0.182),
    ("2024-11-01", 0.076, 0.122, 0.158),
    ("2025-11-01", 0.098, 0.157, 0.203),
]
# Ontario Electricity Rebate as a share of pre-tax charges, by period (checked against the bills)
OER = [("2022-11-01", 0.117), ("2023-11-01", 0.193), ("2024-11-01", 0.131), ("2025-11-01", 0.235)]
HST = 0.13


def _period(table, day):
    row = table[0]
    for r in table:
        if r[0] <= day:
            row = r
    return row


def prices(day):
    _, off, mid, on = _period(TOU_PRICES, day)
    return {"off": off, "mid": mid, "on": on}


def oer(day):
    return _period(OER, day)[1]


def holidays(year):
    """Ontario TOU holidays: priced off-peak all day."""
    d = dt.date
    def nth(month, weekday, n):
        x = d(year, month, 1)
        x += dt.timedelta(days=(weekday - x.weekday()) % 7)
        return x + dt.timedelta(weeks=n - 1)
    def observed(x):  # on a weekend, the following Monday
        return x + dt.timedelta(days=(7 - x.weekday()) % 7) if x.weekday() >= 5 else x
    # Easter (anonymous Gregorian algorithm) for Good Friday
    a, b, c = year % 19, year // 100, year % 100
    g = (b - (b + 8) // 25 + 1) // 3
    h = (19 * a + b - b // 4 - g + 15) % 30
    l = (32 + 2 * (b % 4) + 2 * (c // 4) - h - c % 4) % 7
    m = (a + 11 * h + 22 * l) // 451
    easter = d(year, (h + l - 7 * m + 114) // 31, (h + l - 7 * m + 114) % 31 + 1)
    victoria = d(year, 5, 24) - dt.timedelta(days=(d(year, 5, 24).weekday()) % 7)
    xmas, boxing = d(year, 12, 25), d(year, 12, 26)
    if xmas.weekday() == 5:
        xmas_obs, boxing_obs = d(year, 12, 27), d(year, 12, 28)
    elif xmas.weekday() == 6:
        xmas_obs, boxing_obs = d(year, 12, 26), d(year, 12, 27)
    elif boxing.weekday() == 5:
        xmas_obs, boxing_obs = xmas, d(year, 12, 28)
    else:
        xmas_obs, boxing_obs = xmas, boxing
    return {observed(d(year, 1, 1)), nth(2, 0, 3), easter - dt.timedelta(days=2), victoria, observed(d(year, 7, 1)),
            nth(8, 0, 1), nth(9, 0, 1), nth(10, 0, 2), xmas_obs, boxing_obs}


_hol = {}


def tou_period(t):
    """'on', 'mid' or 'off' for the hour starting at local time t."""
    day = t.date()
    if day.year not in _hol:
        _hol[day.year] = holidays(day.year)
    if t.weekday() >= 5 or day in _hol[day.year]:
        return "off"
    h = t.hour
    summer = 5 <= t.month <= 10
    if h < 7 or h >= 19:
        return "off"
    if summer:
        return "on" if 11 <= h < 17 else "mid"
    return "mid" if 11 <= h < 17 else "on"


def _line(pts):
    n = len(pts)
    mx = sum(x for x, _ in pts) / n
    my = sum(y for _, y in pts) / n
    sxx = sum((x - mx) ** 2 for x, _ in pts)
    slope = sum((x - mx) * (y - my) for x, y in pts) / sxx if sxx else 0
    return my - slope * mx, slope


def _fit_rates(bills):
    """Per calendar year (Toronto Hydro's rates change in January): delivery = fixed +
    per_kwh * net kWh, and regulatory per net kWh. Years with too few bills borrow
    the nearest year that has them."""
    by = defaultdict(list)
    for b in bills:
        # a short bill (the first one after a meter change, say) carries a prorated fixed
        # charge, which would bend the fixed + per-kWh line
        if (dt.date.fromisoformat(b["to"]) - dt.date.fromisoformat(b["from"])).days < 20:
            continue
        by[b["to"][:4]].append(b)
    out = {}
    for y, bs in by.items():
        # two bills fit a line exactly; fine when their kWh differ enough to separate fixed from per-kWh
        if len(bs) < 2 or (len(bs) == 2 and abs((bs[0]["used"] - bs[0]["generated"]) - (bs[1]["used"] - bs[1]["generated"])) < 300):
            continue
        net = [(b["used"] - b["generated"], b) for b in bs]
        fixed, per = _line([(x, b["delivery"]) for x, b in net])
        reg = sum(b["regulatory"] for _, b in net) / sum(x for x, _ in net)
        out[y] = {"fixed": fixed, "perKwh": per, "reg": reg}
    if not out:
        out["0"] = {"fixed": 37.0, "perKwh": 0.03, "reg": 0.006}
    def rates(ym):
        y = ym[:4]
        if y in out:
            return out[y]
        return out[min(out, key=lambda k: abs(int(k) - int(y)))]
    return out, rates


def _months_between(a, b):
    return (int(b[:4]) - int(a[:4])) * 12 + int(b[5:7]) - int(a[5:7])


def month_cost(imp, exp, buy_rate, credit_rate, r, o, bank=0.0):
    """One month's bill under the net metering rules. Returns (total, electricity line,
    credit carried forward)."""
    buy = imp * buy_rate
    credit = exp * credit_rate
    net = imp - exp
    delivery = r["fixed"] + r["perKwh"] * net
    regulatory = r["reg"] * net
    hst = HST * (buy + delivery + r["perKwh"] * exp + regulatory)
    elec = buy - credit + delivery + regulatory - bank
    carry = 0.0
    if elec < 0:  # more credit than charges: carry the excess forward
        carry, elec = -elec, 0.0
    return elec + hst - o * elec, elec, carry


def build_money(hydro, solar_daily, intervals, bills, grid_monthly, today):
    bills = bills or []
    grid_monthly = grid_monthly or {}
    solar_daily = solar_daily or {}
    # bills from before the net meter (and solar) went in: no solar to model, but what was
    # paid still counts toward its calendar year (each bill goes to the month it ends in)
    before = defaultdict(lambda: {"grid": 0.0, "imp": 0.0})
    for b in bills:
        if b.get("preSolar"):
            x = before[b["to"][:7]]
            x["grid"] += b["due"] - b.get("previous", 0); x["imp"] += b["used"]
    bills = [b for b in bills if not b.get("preSolar")]
    fitted, rates = _fit_rates(bills)
    by_month_bill = {b["to"][:7]: b for b in bills}

    # time-of-use split of bought and sent-back kWh, from hourly readings
    split = defaultdict(lambda: {"imp": defaultdict(float), "exp": defaultdict(float)})
    for t, (imp, exp) in intervals.items():
        s = split[t.strftime("%Y-%m")]
        p = tou_period(t)
        s["imp"][p] += imp
        s["exp"][p] += exp

    def mix(ym, kind):
        """Shares of a month's kWh in each TOU period: its own hourly data, else the same
        calendar month in another year, else a bill from the same season."""
        for key in [ym] + sorted((k for k in split if k[5:] == ym[5:]), reverse=True):
            tot = sum(split[key][kind].values()) if key in split else 0
            if tot > 1:
                return {p: split[key][kind][p] / tot for p in ("on", "mid", "off")}
        for b in bills:
            if b["to"][5:7] == ym[5:]:
                src = b["buy"] if kind == "imp" else b["credit"]
                tot = sum(k for k, _ in src.values())
                if tot > 0:
                    return {p: src[p][0] / tot for p in ("on", "mid", "off")}
        return {"on": 0.18, "mid": 0.22, "off": 0.60} if kind == "imp" else {"on": 0.55, "mid": 0.15, "off": 0.30}

    # monthly kWh: bought, sent back, produced
    months = defaultdict(lambda: {"imp": 0.0, "exp": 0.0, "hDays": 0, "prod": 0.0, "pDays": 0})
    for d, (imp, exp) in hydro.items():
        m = months[d[:7]]
        m["imp"] += imp; m["exp"] += exp; m["hDays"] += 1
    for d, p in solar_daily.items():
        if p is None:
            continue
        m = months[d[:7]]
        m["prod"] += p; m["pDays"] += 1

    # share of production sent back in each calendar month, for months with no meter data
    ratio = defaultdict(list)
    for ym, m in months.items():
        if m["hDays"] >= 25 and m["pDays"] >= 25 and m["prod"] > 1:
            ratio[ym[5:]].append(min(1, m["exp"] / m["prod"]))
    for ym, b in by_month_bill.items():
        m = months.get(ym)
        if m and m["pDays"] >= 25 and m["prod"] > 1 and m["hDays"] < 25:
            ratio[ym[5:]].append(min(1, b["generated"] / m["prod"]))

    out = {}
    bank, bank_from = 0.0, None
    today_ym = today.strftime("%Y-%m")
    for ym in sorted(set(months) | set(by_month_bill) | set(grid_monthly)):
        m = months[ym]
        first_day = f"{ym}-01"
        pr, o = prices(first_day), oer(first_day)
        b = by_month_bill.get(ym)
        complete = ym < today_ym
        est = []

        # kWh for the month
        if b:
            imp, exp = b["used"], b["generated"]
        elif m["hDays"] >= 25:
            imp, exp = m["imp"], m["exp"]
        elif ym in grid_monthly:
            imp = grid_monthly[ym]
            r = ratio.get(ym[5:])
            exp = (sum(r) / len(r)) * m["prod"] if r and m["prod"] else None
            if exp is not None:
                est.append("sent back")
        else:
            imp = exp = None
        if m["hDays"] and m["hDays"] < 25 and not b:
            complete = False
        prod = m["prod"] if m["pDays"] else None
        self_used = max(0.0, prod - exp) if prod is not None and exp is not None else None

        # price of a kWh bought this month, what a kWh sent back earns, and what a kWh the
        # panels supplied straight to the house would have cost (bought in sunlit hours)
        r = rates(ym)
        mi, me = mix(ym, "imp"), mix(ym, "exp")
        sun_rate = sum(pr[p] * me[p] for p in pr)
        if b:
            kb = sum(k for k, _ in b["buy"].values())
            buy_rate = sum(k * x for k, x in b["buy"].values()) / kb if kb else 0
            kc = sum(k for k, _ in b["credit"].values())
            credit_rate = sum(k * x for k, x in b["credit"].values()) / kc if kc > 5 else sun_rate
            if kc > 5:
                sun_rate = credit_rate
        else:
            buy_rate = sum(pr[p] * mi[p] for p in pr)
            credit_rate = sun_rate

        # credit carried in from earlier months, written off after 12 months
        if bank and _months_between(bank_from, ym) > 12:
            bank, bank_from = 0.0, None

        # grid cost
        with_cost = None
        if imp is not None and exp is not None:
            with_cost, _, carry = month_cost(imp, exp, buy_rate, credit_rate, r, o, bank)
            bank, bank_from = (carry, bank_from or ym) if carry else (0.0, None)
        if b:
            grid = round(b["due"] - b.get("previous", 0), 2)
            source = "bill"
        elif with_cost is not None and complete:
            grid, source = round(with_cost, 2), "estimate"
        else:
            grid, source = None, None

        # what solar saved: the same month with no panels, minus the month as it was
        credits = self_value = saved = None
        if with_cost is not None and self_used is not None:
            eff = (imp * buy_rate + self_used * sun_rate) / (imp + self_used) if imp + self_used else buy_rate
            without_cost = month_cost(imp + self_used, 0, eff, 0, r, o)[0]
            no_export = month_cost(imp, 0, buy_rate, 0, r, o)[0]
            credits = round(no_export - with_cost, 2)
            saved = round(without_cost - with_cost, 2)
            self_value = round(saved - credits, 2)
        elif with_cost is not None and exp is not None and prod is None:
            credits = saved = round(month_cost(imp, 0, buy_rate, 0, r, o)[0] - with_cost, 2)
        elif prod is not None and m["pDays"] >= 1:
            # no meter data at all: split production by the usual share sent back that month
            rr = ratio.get(ym[5:])
            e2 = prod * (sum(rr) / len(rr) if rr else 0.3)
            base = imp if imp is not None else 1000.0
            w = month_cost(base, e2, buy_rate, credit_rate, r, o)[0]
            credits = round(month_cost(base, 0, buy_rate, 0, r, o)[0] - w, 2)
            eff = (base * buy_rate + (prod - e2) * sun_rate) / (base + prod - e2)
            saved = round(month_cost(base + prod - e2, 0, eff, 0, r, o)[0] - w, 2)
            self_value = round(saved - credits, 2)
            est.append("sent back")
        avoided = (buy_rate + r["perKwh"] + r["reg"]) * (1 + HST - o)
        line_credit = round(exp * (r["perKwh"] + r["reg"]), 2) if exp is not None else None

        out[ym] = {
            "grid": grid, "gridSource": source, "saved": saved, "credits": credits, "selfValue": self_value,
            "without": round(grid + saved, 2) if grid is not None and saved is not None else None,
            "imp": None if imp is None else round(imp, 1), "exp": None if exp is None else round(exp, 1),
            "selfUsed": None if self_used is None else round(self_used, 1), "prod": None if prod is None else round(prod, 1),
            "buyRate": round(buy_rate, 4), "avoidedRate": round(avoided, 4), "creditRate": round(credit_rate, 4),
            "deliveryCredit": line_credit, "carried": round(bank, 2) if bank else 0,
            "complete": complete, "estimated": est,
        }

    # months paid for before the panels went on
    for ym, x in before.items():
        if ym in out:  # the month the panels were switched on: add the bills that ended before it
            o_ = out[ym]
            if o_["grid"] is not None:
                o_["grid"] = round(o_["grid"] + x["grid"], 2)
                if o_["imp"] is not None: o_["imp"] = round(o_["imp"] + x["imp"], 1)
                if o_["without"] is not None: o_["without"] = round(o_["grid"] + o_["saved"], 2)
                o_["beforeSolarGrid"] = round(x["grid"], 2)
        else:
            out[ym] = {"grid": round(x["grid"], 2), "gridSource": "bill", "preSolar": True, "saved": None, "credits": None, "selfValue": None,
                       "without": round(x["grid"], 2), "imp": round(x["imp"], 1), "exp": 0.0, "selfUsed": None, "prod": None,
                       "complete": True, "estimated": []}
    out = dict(sorted(out.items()))

    # backtest: estimate the billed months from meter data alone, to show how close estimates are
    backtest = []
    for ym, b in by_month_bill.items():
        m = months.get(ym)
        if not m or m["hDays"] < 25:
            continue
        mi, me = mix(ym, "imp"), mix(ym, "exp")
        pr, o = prices(f"{ym}-01"), oer(f"{ym}-01")
        est = month_cost(m["imp"], m["exp"], sum(pr[p] * mi[p] for p in pr), sum(pr[p] * me[p] for p in pr), rates(ym), o)[0]
        actual = b["due"] - b.get("previous", 0)
        backtest.append({"month": ym, "estimate": round(est, 2), "bill": round(actual, 2), "off": round(est / actual - 1, 3)})

    return {
        "months": out,
        "model": {"hst": HST, "byYear": {y: {k: round(v, 4) for k, v in x.items()} for y, x in sorted(fitted.items())}},
        "backtest": backtest,
    }
