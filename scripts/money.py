"""What the grid costs and what solar saves, month by month.

Where a Toronto Hydro bill covers the month, the grid cost is the bill's own
charges. Otherwise it is estimated from your meter data with the same pieces a
bill has, learned from your bills:

  energy      kWh bought at Ontario's time-of-use prices, less kWh sent back
              at the same prices (net metering credits only the energy line)
  delivery    a fixed monthly part plus a per-kWh part (fitted to your bills)
  regulatory  per kWh bought
  then HST is added and the Ontario Electricity Rebate taken off

Solar savings are the credits for what you sent back, plus everything the house
used straight from the panels. A kWh you never had to buy saves its energy
price and the per-kWh delivery and regulatory charges, with tax and rebate
applied the same way as on the bill.
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
HST_DEFAULT = 0.16  # as charged on these bills (HST is worked out before net metering credits)


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


def _fit_delivery(bills):
    """delivery = fixed + per_kwh * kWh bought, least squares over the bills."""
    pts = [(b["used"], b["delivery"]) for b in bills]
    if len(pts) < 3:
        return 31.0, 0.035
    n = len(pts)
    mx = sum(x for x, _ in pts) / n
    my = sum(y for _, y in pts) / n
    sxx = sum((x - mx) ** 2 for x, _ in pts)
    slope = sum((x - mx) * (y - my) for x, y in pts) / sxx if sxx else 0.035
    return my - slope * mx, slope


def build_money(hydro, solar_daily, intervals, bills, grid_monthly, today):
    bills = bills or []
    grid_monthly = grid_monthly or {}
    solar_daily = solar_daily or {}
    fixed, d_kwh = _fit_delivery(bills)
    reg_kwh = (sum(b["regulatory"] for b in bills) / sum(b["used"] for b in bills)) if bills else 0.006
    # effective HST share differs by season on these bills (it's worked out before solar credits)
    def _median(xs, default):
        xs = sorted(xs)
        return xs[len(xs) // 2] if xs else default
    hst_by = {season: _median([b["hst"] / (b["electricity"] + b.get("other", 0)) for b in bills if b.get("season") == season], None)
              for season in ("summer", "winter")}
    hst_all = _median([b["hst"] / (b["electricity"] + b.get("other", 0)) for b in bills], HST_DEFAULT)
    hst_for = lambda ym: hst_by["summer" if 5 <= int(ym[5:]) <= 10 else "winter"] or hst_all
    hst = hst_all
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

        # price of a kWh bought this month, and what a kWh sent back earns
        if b:
            kb = sum(k for k, _ in b["buy"].values())
            buy_rate = sum(k * r for k, r in b["buy"].values()) / kb if kb else 0
            kc = sum(k for k, _ in b["credit"].values())
            credit_rate = sum(k * r for k, r in b["credit"].values()) / kc if kc else buy_rate
            tax = (b["electricity"] + b.get("other", 0) + b["hst"] - b["rebate"]) / (b["electricity"] + b.get("other", 0))
        else:
            mi, me = mix(ym, "imp"), mix(ym, "exp")
            buy_rate = sum(pr[p] * mi[p] for p in pr)
            credit_rate = sum(pr[p] * me[p] for p in pr)
            tax = 1 + hst_for(ym) - o
        avoided = buy_rate + d_kwh + reg_kwh  # pre-tax value of a kWh the house didn't have to buy

        # grid cost
        if b:
            grid = round(b["due"] - b.get("previous", 0), 2)
            source = "bill"
        elif imp is not None and exp is not None and complete:
            pre = fixed + imp * (buy_rate + d_kwh + reg_kwh) - exp * credit_rate
            grid = round(pre * tax, 2)
            source = "estimate"
        else:
            grid, source = None, None

        credits = round(exp * credit_rate * tax, 2) if exp is not None else None
        self_value = round(self_used * avoided * tax, 2) if self_used is not None else None
        saved = round((credits or 0) + (self_value or 0), 2) if credits is not None or self_value is not None else None
        if saved is None and prod is not None and m["pDays"] >= 1:
            # no meter data at all: value production as if all used in the house (upper bound avoided)
            r = ratio.get(ym[5:])
            share = sum(r) / len(r) if r else 0.3
            e2 = prod * share
            credits = round(e2 * credit_rate * tax, 2)
            self_value = round((prod - e2) * avoided * tax, 2)
            saved = round(credits + self_value, 2)
            est.append("sent back")

        out[ym] = {
            "grid": grid, "gridSource": source, "saved": saved, "credits": credits, "selfValue": self_value,
            "without": round(grid + saved, 2) if grid is not None and saved is not None else None,
            "imp": None if imp is None else round(imp, 1), "exp": None if exp is None else round(exp, 1),
            "selfUsed": None if self_used is None else round(self_used, 1), "prod": None if prod is None else round(prod, 1),
            "buyRate": round(buy_rate, 4), "avoidedRate": round(avoided * tax, 4), "creditRate": round(credit_rate * tax, 4),
            "complete": complete, "estimated": est,
        }

    # backtest: estimate the billed months from meter data alone, to show how close estimates are
    backtest = []
    for ym, b in by_month_bill.items():
        m = months.get(ym)
        if not m or m["hDays"] < 25:
            continue
        mi, me = mix(ym, "imp"), mix(ym, "exp")
        pr, o = prices(f"{ym}-01"), oer(f"{ym}-01")
        br = sum(pr[p] * mi[p] for p in pr)
        cr = sum(pr[p] * me[p] for p in pr)
        est = (fixed + m["imp"] * (br + d_kwh + reg_kwh) - m["exp"] * cr) * (1 + hst_for(ym) - o)
        actual = b["due"] - b.get("previous", 0)
        backtest.append({"month": ym, "estimate": round(est, 2), "bill": round(actual, 2), "off": round(est / actual - 1, 3)})

    return {
        "months": out,
        "model": {"fixedDelivery": round(fixed, 2), "deliveryPerKwh": round(d_kwh, 4), "regulatoryPerKwh": round(reg_kwh, 4), "hstSummer": hst_by["summer"] and round(hst_by["summer"], 3), "hstWinter": hst_by["winter"] and round(hst_by["winter"], 3)},
        "backtest": backtest,
    }
