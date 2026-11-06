"""Builds the site into _site/.

Reads Toronto Hydro exports from data/hydro/ (.xlsx or .csv) and pulls
production from the SolarEdge Monitoring API V2, then writes everything the app
needs to _site/data.json.

SolarEdge V2 uses OAuth. The refresh token changes every time it is used, so
right after each refresh the new one is saved back to the repository's secrets
with the GitHub CLI. No credential is ever written to the site.

To keep inside the free tier (about 2,000 calls a month) the build reuses the
previously published data.json and only asks SolarEdge for what changed:
today's quarter-hour production on every daytime run, and the daily history,
lifetime total and site details once a day.
"""
import base64
import csv
import datetime as dt
import glob
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo("America/Toronto")
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "_site"
API = "https://monitoringapi.solaredge.com/v2"
TOKEN_URL = API + "/oauth2/token"
AUTHORIZE_URL = "https://connect.solaredge.com/authorize"
NIGHT = (22, 5)  # scheduled runs skip SolarEdge between 10 pm and 5 am


def log(msg):
    print(msg, file=sys.stderr)


def gh_output(key, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as f:
            f.write(f"{key}={value}\n")


# ---------- Toronto Hydro ----------

def _parse_time(v):
    if isinstance(v, dt.datetime):
        return v
    if isinstance(v, dt.date):
        return dt.datetime(v.year, v.month, v.day)
    s = str(v or "").strip()
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d", "%m/%d/%Y %H:%M", "%m/%d/%Y"):
        try:
            return dt.datetime.strptime(s, fmt)
        except ValueError:
            pass
    return None


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _rows(path):
    if path.suffix.lower() == ".csv":
        with open(path, newline="", encoding="utf-8-sig") as f:
            yield from csv.reader(f)
    else:
        import openpyxl
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        for ws in wb.worksheets:
            ws.reset_dimensions()  # Toronto Hydro's export reports a wrong sheet size
            yield from ws.iter_rows(values_only=True)


def read_hydro():
    """Returns {date: [imported kWh, exported kWh]} from every file in data/hydro."""
    readings = {}
    files = sorted(glob.glob(str(ROOT / "data/hydro/*.xlsx")) + glob.glob(str(ROOT / "data/hydro/*.csv")))
    for f in files:
        imp_cols = exp_cols = None
        n = 0
        for row in _rows(Path(f)):
            cells = list(row or [])
            if imp_cols is None:
                labels = [str(c or "").lower() for c in cells]
                if any("delivered" in c for c in labels) and any("received" in c for c in labels):
                    # the export can repeat each column when the meter's channel changes
                    # part way through (e.g. from October 2026), with each row filled in only one of them
                    imp_cols = [i for i, c in enumerate(labels) if "delivered" in c]
                    exp_cols = [i for i, c in enumerate(labels) if "received" in c]
                continue
            if not cells:
                continue
            t = _parse_time(cells[0])
            imps = [v for v in (_num(cells[i]) for i in imp_cols if i < len(cells)) if v is not None]
            exps = [v for v in (_num(cells[i]) for i in exp_cols if i < len(cells)) if v is not None]
            if t is None or not imps or not exps:
                continue
            imp, exp = sum(imps), sum(exps)
            readings[t] = (imp, exp)  # keyed by timestamp, so overlapping files don't double count
            n += 1
        log(f"hydro: {Path(f).name}: {n} readings" if imp_cols is not None else f"hydro: {Path(f).name}: no Delivered/Received columns found, skipped")
    daily = defaultdict(lambda: [0.0, 0.0])
    for t, (imp, exp) in readings.items():
        d = t.date().isoformat()
        daily[d][0] += imp
        daily[d][1] += exp
    return dict(daily)


# ---------- SolarEdge V2 ----------

class AuthError(Exception):
    pass


def _http(req):
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read() or b"null")
        except ValueError:
            body = None
        return e.code, body
    except (urllib.error.URLError, OSError, ValueError) as e:
        return 0, {"error": f"network error: {e}"}


def token_request(data):
    """POST to the token endpoint. Known clients use JSON with the credentials in
    the body; fall back to a form post with Basic auth if that is refused."""
    cid, secret = os.environ["SOLAREDGE_CLIENT_ID"].strip(), os.environ["SOLAREDGE_CLIENT_SECRET"].strip()
    headers = {"Accept": "application/json", "User-Agent": "home-solar"}
    attempts = [
        urllib.request.Request(TOKEN_URL, method="POST",
                               data=json.dumps({**data, "client_id": cid, "client_secret": secret}).encode(),
                               headers={**headers, "Content-Type": "application/json"}),
        urllib.request.Request(TOKEN_URL, method="POST", data=urllib.parse.urlencode(data).encode(),
                               headers={**headers, "Content-Type": "application/x-www-form-urlencoded",
                                        "Authorization": "Basic " + base64.b64encode(f"{cid}:{secret}".encode()).decode()}),
    ]
    last = None
    for req in attempts:
        status, body = _http(req)
        if status < 400 and isinstance(body, dict) and body.get("access_token"):
            return body
        last = last or f"HTTP {status}: {(body or {}).get('error_description') or (body or {}).get('detail') or (body or {}).get('error') or ''}".strip()
        if status >= 500 or status == 0:
            break
    raise AuthError(f"token request refused ({last})")


def save_refresh_token(token):
    """Store the new refresh token as a repository secret. It must happen right
    away: the old one stopped working the moment it was used."""
    if not os.environ.get("GH_TOKEN") or not os.environ.get("GITHUB_REPOSITORY"):
        raise RuntimeError("GH_PAT secret is missing, so the new refresh token can't be saved")
    print(f"::add-mask::{token}")
    subprocess.run(["gh", "secret", "set", "SOLAREDGE_REFRESH_TOKEN", "--repo", os.environ["GITHUB_REPOSITORY"]],
                   input=token.encode(), check=True, capture_output=True)


CALLS = 0


def api_get(token, path, params=None):
    global CALLS
    CALLS += 1
    url = f"{API}{path}" + ("?" + urllib.parse.urlencode(params, doseq=True) if params else "")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                                               "User-Agent": "home-solar"})
    for attempt in range(2):
        status, body = _http(req)
        if status == 429 and attempt == 0:
            time.sleep(15)
            continue
        if status in (401, 403):
            raise AuthError(f"{path}: HTTP {status}")
        if status >= 400 or status == 0:
            raise RuntimeError(f"{path}: HTTP {status} {body}")
        return body
    raise RuntimeError(f"{path}: rate limited")


def _instant(t):
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _find(data, *keys):
    """First value for any of keys, searching nested dicts."""
    if isinstance(data, dict):
        for k in keys:
            if k in data and data[k] is not None:
                return data[k]
        for v in data.values():
            r = _find(v, *keys)
            if r is not None:
                return r
    return None


def _series(body):
    """[(datetime or None, Wh)] from a {unit, values:[{timestamp, value}]} envelope."""
    values = _find(body, "values") if not isinstance(body, list) else body
    unit = str(_find(body, "unit", "units") or "WH").upper() if isinstance(body, dict) else "WH"
    factor = {"WH": 1, "KWH": 1000, "MWH": 1e6, "W": 1, "KW": 1000}.get(unit, 1)
    out = []
    for v in values or []:
        if not isinstance(v, dict):
            continue
        ts = v.get("timestamp") or v.get("date") or v.get("time")
        val = v.get("value")
        out.append((_ts(ts), None if val is None else float(val) * factor))
    return out


def _ts(s):
    if not s:
        return None
    s = str(s).replace("Z", "+00:00").replace(" ", "T")
    try:
        t = dt.datetime.fromisoformat(s)
    except ValueError:
        return None
    return t.astimezone(TZ) if t.tzinfo else t.replace(tzinfo=TZ)


def _day_of(t):
    # DAY buckets may come back as local midnight or as UTC midnight; adding
    # 12 hours lands both on the right calendar day.
    return (t + dt.timedelta(hours=12)).date().isoformat()


def fetch_daily(token, start, end):
    """Daily production (kWh) between two local dates. Falls back to month-sized
    requests if the API won't return the whole span in one call."""
    def one(a, b):
        body = api_get(token, f"/sites/{SITE}/energy", {
            "resolution": "DAY", "unit": "WH",
            "from": _instant(dt.datetime.combine(a, dt.time(), TZ)),
            "to": _instant(min(dt.datetime.combine(b + dt.timedelta(days=1), dt.time(), TZ), dt.datetime.now(TZ)))})
        return {_day_of(t): round(v / 1000, 2) for t, v in _series(body) if t and v is not None}
    try:
        return one(start, end)
    except RuntimeError as e:
        if (end - start).days <= 31:
            raise
        log(f"solaredge: long daily span refused ({e}), fetching month by month")
        out, a = {}, start
        while a <= end:
            b = min(a + dt.timedelta(days=30), end)
            out.update(one(a, b))
            a = b + dt.timedelta(days=1)
            time.sleep(7)  # 10 calls a minute
        return out


def authorize_url():
    cid, base = os.environ.get("SOLAREDGE_CLIENT_ID", "").strip(), os.environ.get("PAGES_URL", "").rstrip("/")
    if not cid or not base:
        return None
    return AUTHORIZE_URL + "?" + urllib.parse.urlencode({
        "response_type": "code", "client_id": cid, "redirect_uri": f"{base}/callback.html",
        "scope": "SITE_DATA DEVICE_DATA", "access_duration": "24", "external_id": "home-solar"})


def previous_data():
    base = os.environ.get("PAGES_URL", "").rstrip("/")
    if not base:
        return {}
    try:
        with urllib.request.urlopen(f"{base}/data.json?ts={int(time.time())}", timeout=20) as r:
            return json.load(r)
    except Exception as e:
        log(f"previous data.json not available ({e}), starting fresh")
        return {}


def sun_times(day):
    """Sunrise and sunset in Toronto time for a date (NOAA sunrise equation)."""
    import math
    rad = math.pi / 180
    jd = dt.datetime(day.year, day.month, day.day, 12, tzinfo=dt.timezone.utc).timestamp() / 86400 + 2440587.5
    n = round(jd - 2451545 + 0.0008)
    js = n - LON / 360
    M = (357.5291 + 0.98560028 * js) % 360
    C = 1.9148 * math.sin(M * rad) + 0.02 * math.sin(2 * M * rad) + 0.0003 * math.sin(3 * M * rad)
    L = (M + C + 180 + 102.9372) % 360
    jt = 2451545 + js + 0.0053 * math.sin(M * rad) - 0.0069 * math.sin(2 * L * rad)
    dec = math.asin(math.sin(L * rad) * math.sin(23.4397 * rad))
    cosw = (math.sin(-0.833 * rad) - math.sin(LAT * rad) * math.sin(dec)) / (math.cos(LAT * rad) * math.cos(dec))
    w = math.acos(max(-1, min(1, cosw))) / rad
    to_dt = lambda j: dt.datetime.fromtimestamp((j - 2440587.5) * 86400, dt.timezone.utc).astimezone(TZ)
    return to_dt(jt - w / 360), to_dt(jt + w / 360)


def _flat_numbers(obj, prefix="", out=None):
    out = {} if out is None else out
    if isinstance(obj, dict):
        for k, v in obj.items():
            _flat_numbers(v, f"{prefix}{k}." if isinstance(v, dict) else f"{prefix}{k}", out)
    elif isinstance(obj, (int, float)) and not isinstance(obj, bool):
        out[prefix.rstrip(".")] = obj
    elif isinstance(obj, str) and prefix.lower().endswith(("unit", "units")):
        out[prefix.rstrip(".")] = obj
    return out


def _list_in(body, *keys):
    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        for k in keys:
            if isinstance(body.get(k), list):
                return body[k]
        for v in body.values():
            r = _list_in(v, *keys)
            if r:
                return r
    return []


def parse_alerts(body):
    out = []
    for a in _list_in(body, "alerts", "list"):
        if not isinstance(a, dict):
            continue
        comp = a.get("component")
        out.append({
            "id": a.get("alertId") or a.get("id"),
            "type": a.get("type") or a.get("name"),
            "category": a.get("category"),
            "impact": a.get("impact"),
            "component": comp.get("name") if isinstance(comp, dict) else comp,
            "first": a.get("firstTrigger"),
            "last": a.get("lastTrigger"),
            "codes": a.get("errorCodes") or [],
        })
    return out


def parse_equipment(body):
    devices = [d for d in _list_in(body, "devices", "device", "list") if isinstance(d, dict)]
    inv = [d for d in devices if str(d.get("type", "")).upper() == "INVERTER"]
    opt = [d for d in devices if str(d.get("type", "")).upper() == "OPTIMIZER"]
    return {
        "inverters": [{"name": i.get("name"), "manufacturer": i.get("manufacturer"),
                       "model": i.get("model") or i.get("partNumber"), "firmware": i.get("firmwareVersion") or i.get("cpuVersion"),
                       "communication": i.get("communicationType") or i.get("communicationMethod"),
                       "optimizers": i.get("connectedOptimizers")} for i in inv],
        "optimizers": len(opt) if devices else None,
        "optimizerModels": sorted({o.get("model") or o.get("partNumber") for o in opt} - {None}),
    }


def parse_telemetry(body):
    """{metric: {unit, latest, max, min, series:[[HH:MM, value]]}} for the first inverter."""
    invs = body.get("inverters") if isinstance(body, dict) else None
    if not isinstance(invs, dict) or not invs:
        return None
    metrics = next(iter(invs.values()))
    out = {}
    for name, series in (metrics or {}).items():
        if not isinstance(series, dict):
            continue
        pts = []
        for v in series.get("values") or []:
            if not isinstance(v, dict):
                continue
            t = _ts(v.get("timestamp"))
            pts.append([t.strftime("%H:%M") if t else None, v.get("value")])
        nums = [x for _, x in pts if isinstance(x, (int, float)) and not isinstance(x, bool)]
        latest = next((x for _, x in reversed(pts) if x is not None), None)
        out[name] = {"unit": series.get("unit"), "latest": latest,
                     "max": max(nums) if nums else None, "min": min(nums) if nums else None, "series": pts[-24:]}
    return out


def read_solaredge(prev):
    """Returns (solar block, token_lost).

    Calls are spread out to fit the free tier (about 2,000 a month):
      daylight, every run   today's quarter hours and live power (2)
      every 3 hours         open alerts (5 am to 11 pm), inverter readings (daylight)
      once a day            site details, daily history, lifetime, equipment, benefits (5)
      once after sunset     final quarter hours for the day (1)
    Nothing is called, and the token isn't touched, when nothing is due.
    """
    global SITE
    SITE = os.environ.get("SOLAREDGE_SITE_ID", "").strip()
    refresh = os.environ.get("SOLAREDGE_REFRESH_TOKEN", "").strip()
    has_app = os.environ.get("SOLAREDGE_CLIENT_ID") and os.environ.get("SOLAREDGE_CLIENT_SECRET") and SITE
    if not has_app:
        log("solaredge: client ID, client secret or site ID not set, building without production data")
        return None, False
    if not refresh:
        log("solaredge: not connected yet, run the Connect SolarEdge workflow")
        return ({**prev, "connected": False, "needsConnect": True} if prev.get("daily") else {"connected": False, "needsConnect": True}), False

    now = dt.datetime.now(TZ)
    today = now.date()
    rise, sset = sun_times(today)
    fetched = dict(prev.get("fetched") or {})
    def due(key, hours):
        t = fetched.get(key)
        return not t or (now - dt.datetime.fromisoformat(t)) >= dt.timedelta(hours=hours, minutes=-10)
    daylight = rise - dt.timedelta(minutes=30) <= now <= sset + dt.timedelta(minutes=45)
    fresh = not prev.get("daily")
    need = {
        "history": fresh or (prev.get("historyDate") != today.isoformat() and now.hour >= NIGHT[1]),
        "today": fresh or daylight or prev.get("todayDate") != today.isoformat()
                 or (now > sset + dt.timedelta(minutes=45) and prev.get("finalDate") != today.isoformat()),
        "power": daylight,
        "alerts": NIGHT[1] <= now.hour < 23 and due("alerts", 3),
        "telemetry": daylight and due("telemetry", 3),
    }
    if not any(need.values()):
        log("solaredge: nothing due, reusing the last data")
        return prev, False

    try:
        tok = token_request({"grant_type": "refresh_token", "refresh_token": refresh})
    except AuthError as e:
        log(f"solaredge: {e}. Access has expired, run the Connect SolarEdge workflow again")
        return {**prev, "connected": False, "needsConnect": True, "error": "SolarEdge access expired"}, False
    if tok.get("refresh_token"):
        try:
            save_refresh_token(tok["refresh_token"])
        except Exception as e:
            log(f"::error::Couldn't save the new SolarEdge refresh token: {e}. Run Connect SolarEdge again.")
            return {**prev, "connected": False, "needsConnect": True, "error": "SolarEdge token couldn't be saved"}, True
    access = tok["access_token"]

    solar = dict(prev) if prev.get("connected") or prev.get("daily") else {}
    solar.update({"connected": True, "needsConnect": False, "error": None})
    stamp = now.isoformat(timespec="minutes")
    try:
        if need["history"]:
            d = api_get(access, f"/sites/{SITE}")
            solar["peakKw"] = _find(d, "peakPower") or solar.get("peakKw")
            inst = _find(d, "installationDate")
            solar["installed"] = str(inst)[:10] if inst else solar.get("installed")
            solar["status"] = _find(d, "activationStatus", "status") or solar.get("status")

            daily = dict(solar.get("daily") or {})
            start = dt.date.fromisoformat(max(daily)) - dt.timedelta(days=3) if daily else today - dt.timedelta(days=364)
            daily.update(fetch_daily(access, start, today))
            cutoff = (today - dt.timedelta(days=400)).isoformat()
            solar["daily"] = {k: v for k, v in sorted(daily.items()) if k >= cutoff}

            since = dt.date.fromisoformat(solar["installed"]) if solar.get("installed") else today - dt.timedelta(days=3650)
            body = api_get(access, f"/sites/{SITE}/energy", {
                "resolution": "YEAR", "unit": "WH",
                "from": _instant(dt.datetime.combine(since.replace(month=1, day=1), dt.time(), TZ)),
                "to": _instant(now)})
            solar["lifetimeBase"] = round(sum(v for _, v in _series(body) if v) / 1000, 1)
            solar["lifetimeBaseToday"] = solar["daily"].get(today.isoformat(), 0)

            for key, fn in (("equipment", lambda: parse_equipment(api_get(access, f"/sites/{SITE}/devices", {"types": ["INVERTER", "OPTIMIZER"]}))),
                            ("benefits", lambda: _flat_numbers(api_get(access, f"/sites/{SITE}/environmental-benefits", {"unit": "METRIC"})))):
                try:
                    solar[key] = fn()
                except AuthError:
                    raise
                except Exception as e:  # optional extras: never fail the build over them
                    log(f"solaredge: {key} unavailable: {e}")
            solar["historyDate"] = today.isoformat()

        if need["today"]:
            body = api_get(access, f"/sites/{SITE}/energy", {
                "resolution": "QUARTER_HOUR", "unit": "WH",
                "from": _instant(dt.datetime.combine(today, dt.time(), TZ)), "to": _instant(now)})
            qh = [(t, v) for t, v in _series(body) if t and t.date() == today]
            today_kwh = round(sum(v for _, v in qh if v) / 1000, 2)
            last = next(((t, v) for t, v in reversed(qh) if v is not None), None)
            solar["todayCurve"] = [[t.strftime("%H:%M"), round((v or 0) * 4 / 1000, 2)] for t, v in qh]
            solar["nowKw"] = round(last[1] * 4 / 1000, 2) if last and (now - last[0]) < dt.timedelta(minutes=45) else 0
            solar["updated"] = last[0].isoformat() if last else solar.get("updated")
            solar["today"], solar["todayDate"] = today_kwh, today.isoformat()
            if now > sset + dt.timedelta(minutes=45):
                solar["finalDate"] = today.isoformat()

        if need["power"]:
            try:
                body = api_get(access, f"/sites/{SITE}/power", {
                    "resolution": "QUARTER_HOUR",
                    "from": _instant(max(dt.datetime.combine(today, dt.time(), TZ), now - dt.timedelta(hours=11))),
                    "to": _instant(now)})
                pts = [(t, v) for t, v in _series(body) if t and v is not None]
                if pts and (now - pts[-1][0]) < dt.timedelta(minutes=45):
                    solar["nowKw"] = round(pts[-1][1] / 1000, 2)
                    solar["powerAt"] = pts[-1][0].isoformat()
                elif not pts or (now - pts[-1][0]) >= dt.timedelta(minutes=45):
                    solar["nowKw"] = 0
            except AuthError:
                raise
            except Exception as e:
                log(f"solaredge: power unavailable: {e}")

        if need["alerts"]:
            try:
                solar["alerts"] = parse_alerts(api_get(access, f"/sites/{SITE}/alerts", {"only-open": "true", "alerts-in-page": "50"}))
                solar["alertsChecked"] = stamp
                fetched["alerts"] = stamp
            except AuthError:
                raise
            except Exception as e:
                log(f"solaredge: alerts unavailable: {e}")

        if need["telemetry"]:
            try:
                tel = parse_telemetry(api_get(access, f"/sites/{SITE}/inverters/telemetry", {
                    "resolution": "HOUR", "from": _instant(dt.datetime.combine(today, dt.time(), TZ)), "to": _instant(now)}))
                if tel:
                    solar["inverter"] = {"at": stamp, "metrics": tel}
                fetched["telemetry"] = stamp
            except AuthError:
                raise
            except Exception as e:
                fetched["telemetry"] = stamp  # don't retry every hour if the plan doesn't include it
                log(f"solaredge: inverter readings unavailable: {e}")
    except AuthError as e:
        log(f"solaredge: {e}")
        return {**prev, "connected": False, "needsConnect": True, "error": "SolarEdge refused the request"}, False
    except Exception as e:
        log(f"solaredge: request failed, keeping the last data: {e}")
        return {**(prev or {}), "error": str(e)[:200]}, False

    solar["fetched"] = fetched
    daily = solar["daily"]
    if solar.get("todayDate") == today.isoformat():
        daily[today.isoformat()] = solar["today"]
    ym, y = today.strftime("%Y-%m"), str(today.year)
    solar["month"] = round(sum(v for k, v in daily.items() if k.startswith(ym)), 1)
    solar["year"] = round(sum(v for k, v in daily.items() if k.startswith(y)), 1)
    solar["lifetime"] = round(solar.get("lifetimeBase", 0) - solar.get("lifetimeBaseToday", 0) + daily.get(today.isoformat(), 0), 1)
    log(f"solaredge: {CALLS} API calls ({', '.join(k for k, v in need.items() if v)}), today {daily.get(today.isoformat(), 0)} kWh, "
        f"{len(solar.get('alerts') or [])} open alerts")
    return solar, False


# ---------- weather (Open-Meteo, free, no key) ----------
# Parkdale, rounded to about 1 km. Weather data by Open-Meteo.com, CC BY 4.0.
LAT, LON = 43.64, -79.43
WEATHER_START = "2026-01-01"
DAILY_VARS = "temperature_2m_max,temperature_2m_min,weather_code,sunshine_duration,shortwave_radiation_sum,snowfall_sum"
WEATHER_FIELDS = 6  # high, low, code, sunshine hours, sunlight MJ/m², snowfall cm


def _get_json(url, params):
    req = urllib.request.Request(url + "?" + urllib.parse.urlencode(params), headers={"User-Agent": "home-solar"})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.load(r)
    if isinstance(body, dict) and body.get("error"):
        raise RuntimeError(body.get("reason"))
    return body


def _daily_rows(body):
    d = body.get("daily") or {}
    out = {}
    for i, day in enumerate(d.get("time") or []):
        hi, lo = d["temperature_2m_max"][i], d["temperature_2m_min"][i]
        if hi is None or lo is None:
            continue
        col = lambda k: (d.get(k) or [None] * (i + 1))[i]
        sun, ghi, snow = col("sunshine_duration"), col("shortwave_radiation_sum"), col("snowfall_sum")
        out[day] = [round(hi, 1), round(lo, 1), d["weather_code"][i], None if sun is None else round(sun / 3600, 1),
                    None if ghi is None else round(ghi, 2), None if snow is None else round(snow, 1)]
    return out


def read_weather(prev):
    """Daily high, low, conditions and sunshine hours since Jan 1 2026, plus the
    current conditions. The archive runs a few days behind, so the last two
    weeks come from the forecast service, which also gives today and now."""
    w = dict(prev or {})
    daily = dict(w.get("daily") or {})
    if any(len(v) < WEATHER_FIELDS for v in daily.values()):  # older format: fetch the history again
        daily, w = {}, {k: v for k, v in w.items() if k not in ("archivedThrough", "archiveDate")}
    today = dt.datetime.now(TZ).date()
    base = {"latitude": LAT, "longitude": LON, "timezone": "America/Toronto"}
    if w.get("archiveDate") != today.isoformat():
        start = (dt.date.fromisoformat(w["archivedThrough"]) + dt.timedelta(days=1)) if w.get("archivedThrough") else dt.date.fromisoformat(WEATHER_START)
        end = today - dt.timedelta(days=2)
        if start <= end:
            try:
                rows = _daily_rows(_get_json("https://archive-api.open-meteo.com/v1/archive",
                                             {**base, "start_date": start.isoformat(), "end_date": end.isoformat(), "daily": DAILY_VARS}))
                daily.update(rows)
                if rows:
                    w["archivedThrough"] = max(rows)
                w["archiveDate"] = today.isoformat()
            except Exception as e:
                log(f"weather: archive request failed, keeping what we have: {e}")
    try:
        body = _get_json("https://api.open-meteo.com/v1/forecast", {**base, "past_days": 14, "forecast_days": 2,
                                                                      "daily": DAILY_VARS, "current": "temperature_2m,weather_code,is_day"})
        rows = _daily_rows(body)
        tomorrow = (today + dt.timedelta(days=1)).isoformat()
        w["tomorrow"] = [tomorrow] + rows.pop(tomorrow) if tomorrow in rows else None
        daily.update({k: v for k, v in rows.items() if k <= today.isoformat()})
        c = body.get("current") or {}
        if c.get("temperature_2m") is not None:
            w["current"] = {"time": c.get("time"), "temp": round(c["temperature_2m"], 1), "code": c.get("weather_code"), "isDay": c.get("is_day")}
    except Exception as e:
        log(f"weather: forecast request failed, keeping what we have: {e}")
    w["daily"] = {k: v for k, v in sorted(daily.items()) if k >= WEATHER_START}
    w["lat"], w["lon"] = LAT, LON
    log(f"weather: {len(w['daily'])} days")
    return w


# ---------- expected production and problems ----------

def solar_factor(solar_daily, weather_daily, around, days=30):
    """kWh produced per MJ/m² of sunlight, learned from the system's own recent
    days (median, skipping outages and snowy days)."""
    lo, hi = (around - dt.timedelta(days=days)).isoformat(), around.isoformat()
    ratios = []
    for d, p in solar_daily.items():
        w = weather_daily.get(d)
        if not (lo <= d <= hi) or not w or w[4] is None or w[4] < 2 or p is None or p < 0.5:
            continue
        if (w[5] or 0) > 0 or w[2] in (71, 73, 75, 77, 85, 86):
            continue
        ratios.append(p / w[4])
    ratios.sort()
    return ratios[len(ratios) // 2] if len(ratios) >= 7 else None


def find_problems(solar, weather):
    """Things worth a notification. Each has a stable key so it is reported once."""
    if not solar or not solar.get("connected"):
        return []
    out = []
    now = dt.datetime.now(TZ)
    today = now.date()
    for a in solar.get("alerts") or []:
        detail = "\n".join(f"- **{k}:** {v}" for k, v in (("Type", a.get("type")), ("Part", a.get("component")),
                           ("Category", a.get("category")), ("Impact (1 low to 9 high)", a.get("impact")),
                           ("First seen", a.get("first")), ("Last seen", a.get("last")),
                           ("Error codes", ", ".join(map(str, a.get("codes") or [])) or None)) if v not in (None, ""))
        out.append({"key": f"alert-{a.get('id')}", "kind": "alert",
                    "title": f"SolarEdge alert: {a.get('type') or 'unknown'}" + (f" ({a.get('component')})" if a.get("component") else ""),
                    "body": f"SolarEdge is reporting an open alert on your system.\n\n{detail}\n\nCheck the SolarEdge app for details, or contact your installer if it doesn't clear."})
    wd = (weather or {}).get("daily") or {}
    snowy = lambda d: bool(wd.get(d)) and ((wd[d][5] or 0) > 0 or wd[d][2] in (71, 73, 75, 77, 85, 86))
    rise, sset = sun_times(today)
    if solar.get("todayDate") == today.isoformat() and rise + dt.timedelta(hours=3) < now < sset - dt.timedelta(hours=1) \
            and (solar.get("today") or 0) < 0.05 and not snowy(today.isoformat()):
        out.append({"key": f"outage-{today}", "kind": "outage", "title": f"No solar production yet today ({today:%b} {today.day})",
                    "body": f"The panels haven't produced anything since sunrise at {rise:%-I:%M %p}, and it's now {now:%-I:%M %p}. "
                            "If it isn't snow covered, check the inverter (its light should be green) and the SolarEdge app."})
    mode = ((solar.get("inverter") or {}).get("metrics") or {})
    for name, m in mode.items():
        v = str(m.get("latest") or "")
        if "mode" in name.lower() and any(x in v.upper() for x in ("FAULT", "ERROR", "SHUTDOWN", "LOCKED")) and rise < now < sset:
            out.append({"key": f"mode-{today}", "kind": "mode", "title": f"Inverter reports {v.title()}",
                        "body": f"SolarEdge's inverter readings show its mode as **{v}** during daylight. Check the inverter and the SolarEdge app."})
    y = (today - dt.timedelta(days=1)).isoformat()
    k = solar_factor(solar.get("daily") or {}, wd, today - dt.timedelta(days=2))
    p, w = (solar.get("daily") or {}).get(y), wd.get(y)
    if k and p is not None and w and w[4]:
        exp = k * w[4]
        if exp >= 8 and p < 0.4 * exp and not snowy(y):
            out.append({"key": f"low-{y}", "kind": "low", "title": f"Solar well below expected on {dt.date.fromisoformat(y):%b} {dt.date.fromisoformat(y).day}",
                        "body": f"The panels made {p:.1f} kWh against about {exp:.0f} kWh expected from that day's sunlight ({p / exp:.0%}). "
                                "One day can be a fluke; if it keeps happening, look for shading, dirt, or a fault."})
    return out


# ---------- build ----------

def main():
    hydro = read_hydro()
    prev = previous_data()
    solar, token_lost = read_solaredge(prev.get("solar") or {})
    panels_file = ROOT / "data/panels.json"
    panels = json.loads(panels_file.read_text()) if panels_file.exists() else None

    weather = read_weather(prev.get("weather"))
    if solar and solar.get("daily") and weather.get("daily"):
        weather["factor"] = solar_factor(solar["daily"], weather["daily"], dt.datetime.now(TZ).date())
    problems = find_problems(solar, weather)
    checked = solar and solar.get("alertsChecked")
    fresh_check = bool(checked) and dt.datetime.now(TZ) - dt.datetime.fromisoformat(checked) < dt.timedelta(minutes=30)
    (ROOT / "problems.json").write_text(json.dumps({"alertsChecked": fresh_check, "problems": problems}, indent=1))
    data = {
        "generated": dt.datetime.now(TZ).isoformat(timespec="minutes"),
        "hydro": {d: [round(v[0], 2), round(v[1], 2)] for d, v in sorted(hydro.items())},
        "solar": solar,
        "panels": panels,
        "weather": weather,
        "connectUrl": authorize_url() if solar and solar.get("needsConnect") else None,
        "repo": os.environ.get("GITHUB_REPOSITORY"),
    }
    if OUT.exists():
        shutil.rmtree(OUT)
    shutil.copytree(ROOT / "web", OUT)
    (OUT / "data.json").write_text(json.dumps(data, separators=(",", ":")))
    gh_output("token_lost", "true" if token_lost else "false")
    log(f"built _site/ with {len(hydro)} hydro days, solar {'connected' if solar and solar.get('connected') else 'not connected'}")


SITE = ""

if __name__ == "__main__":
    main()
