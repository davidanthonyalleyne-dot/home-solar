(() => {
  "use strict";

  const view = document.getElementById("view");

  // Safari ignores user-scalable=no, so block its pinch gestures directly
  ["gesturestart", "gesturechange", "gestureend"].forEach((t) => document.addEventListener(t, (e) => e.preventDefault(), { passive: false }));
  const state = { data: null, month: null, day: null, lastTab: "now" };

  // ---------- helpers ----------
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const fmt = (n, dp = 0) => (n == null || isNaN(n)) ? "–" : Number(n).toLocaleString("en-CA", { minimumFractionDigits: dp, maximumFractionDigits: dp });
  const kwh = (n) => Math.abs(n) >= 100 ? fmt(n) : fmt(n, 1);
  const signed = (n) => (n < 0 ? "−" : "") + kwh(Math.abs(n));
  const parseDay = (d) => { const [y, m, dd] = d.split("-").map(Number); return new Date(y, m - 1, dd); };
  const monthName = (ym, style = "long") => { const [y, m] = ym.split("-").map(Number); return new Date(y, m - 1, 1).toLocaleDateString("en-US", { month: style, year: "numeric" }); };
  const mName = (ym) => monthName(ym).replace(/ \d+$/, "");
  const dayName = (d) => parseDay(d).toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" });
  const shortDay = (d) => parseDay(d).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  const daysIn = (ym) => { const [y, m] = ym.split("-").map(Number); return new Date(y, m, 0).getDate(); };
  const pct = (a, b) => b > 0 ? Math.round((a / b) * 100) : 0;
  const change = (a, b) => Math.round(((a - b) / b) * 100);
  const money = (n) => (n < 0 ? "−$" : "$") + Math.abs(n).toLocaleString("en-CA", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const dollars = (n) => (n < 0 ? "−$" : "$") + Math.round(Math.abs(n)).toLocaleString("en-CA");
  const chev = '<svg class="chev" viewBox="0 0 10 16" aria-hidden="true"><path d="M2 2l6 6-6 6"/></svg>';
  const contentWidth = () => Math.max(280, Math.min(560, document.documentElement.clientWidth || innerWidth) - 40);

  // ---------- data ----------
  const hydro = () => state.data.hydro || {};
  const solar = () => (state.data.solar && state.data.solar.daily && Object.keys(state.data.solar.daily).length) ? state.data.solar : null;
  const needsConnect = () => !!(state.data.solar && state.data.solar.needsConnect);
  const connectBtn = () => state.data.connectUrl ? `<a class="btn" href="${esc(state.data.connectUrl)}">Connect SolarEdge</a>` : "";
  const M = () => (state.data.money && state.data.money.months) || {};

  let _range = null;
  function solarRange() {
    if (!_range) { const k = Object.keys(solar().daily).sort(); _range = [k[0], k.at(-1)]; }
    return _range;
  }

  function months() {
    const s = new Set(Object.keys(hydro()).map((d) => d.slice(0, 7)));
    if (solar()) Object.keys(solar().daily || {}).forEach((d) => s.add(d.slice(0, 7)));
    Object.keys(M()).forEach((m) => s.add(m));
    return [...s].sort();
  }

  function defaultMonth() {
    const all = months();
    const both = all.filter((m) => Object.keys(hydro()).some((d) => d.startsWith(m)) && solar() && Object.keys(solar().daily).some((d) => d.startsWith(m)));
    return both.at(-1) || Object.keys(hydro()).map((d) => d.slice(0, 7)).sort().at(-1) || all.at(-1) || null;
  }

  // one record per calendar day of the month; fields are null where a source has no data
  function monthDays(ym) {
    const out = [];
    for (let i = 1; i <= daysIn(ym); i++) {
      const d = `${ym}-${String(i).padStart(2, "0")}`;
      const h = hydro()[d];
      // inside SolarEdge's history a missing day means the system made nothing (e.g. an outage)
      let p = solar() ? solar().daily[d] : undefined;
      // ...unless the meter shows power going out to the grid: then only the monitoring was down
      if (p == null && solar() && h && h[1] < 0.05 && d >= solarRange()[0] && d <= solarRange()[1]) p = 0;
      const r = { d, imp: h ? h[0] : null, exp: h ? h[1] : null, prod: p ?? null };
      if (r.prod != null && r.exp != null) {
        r.self = Math.max(0, r.prod - r.exp);
        r.home = r.imp + r.self;
      }
      out.push(r);
    }
    return out;
  }

  function totals(days) {
    const t = { imp: 0, exp: 0, prod: 0, self: 0, home: 0, hDays: 0, pDays: 0, bothDays: 0 };
    for (const r of days) {
      if (r.imp != null) { t.imp += r.imp; t.exp += r.exp; t.hDays++; }
      if (r.prod != null) { t.prod += r.prod; t.pDays++; }
      if (r.self != null) { t.self += r.self; t.home += r.home; t.bothDays++; }
    }
    return t;
  }

  function monthStats(ym) {
    const t = totals(monthDays(ym));
    return {
      ym, t,
      home: t.bothDays ? t.home / t.bothDays : null,
      imp: t.hDays ? t.imp / t.hDays : null,
      prod: t.pDays ? t.prod / t.pDays : null,
      cover: t.bothDays ? pct(t.self, t.home) : null,
    };
  }

  // ---------- sun and weather ----------
  const TZNAME = "America/Toronto";
  const LAT = () => (state.data.weather && state.data.weather.lat) || 43.64;
  const LON = () => (state.data.weather && state.data.weather.lon) || -79.43;

  // sunrise and sunset for any date (NOAA sunrise equation, accurate to about a minute)
  function sunTimes(d) {
    const rad = Math.PI / 180, [y, m, dd] = d.split("-").map(Number);
    const jd = Date.UTC(y, m - 1, dd, 12) / 86400000 + 2440587.5;
    const n = Math.round(jd - 2451545 + 0.0008), js = n - LON() / 360;
    const Mm = (357.5291 + 0.98560028 * js) % 360;
    const C = 1.9148 * Math.sin(Mm * rad) + 0.02 * Math.sin(2 * Mm * rad) + 0.0003 * Math.sin(3 * Mm * rad);
    const L = (Mm + C + 180 + 102.9372) % 360;
    const jt = 2451545 + js + 0.0053 * Math.sin(Mm * rad) - 0.0069 * Math.sin(2 * L * rad);
    const dec = Math.asin(Math.sin(L * rad) * Math.sin(23.4397 * rad));
    const cosw = (Math.sin(-0.833 * rad) - Math.sin(LAT() * rad) * Math.sin(dec)) / (Math.cos(LAT() * rad) * Math.cos(dec));
    const w = Math.acos(Math.max(-1, Math.min(1, cosw))) / rad;
    const ms = (j) => new Date((j - 2440587.5) * 86400000);
    return { rise: ms(jt - w / 360), set: ms(jt + w / 360) };
  }
  const clock = (t) => t.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone: TZNAME }).replace(" AM", " am").replace(" PM", " pm");
  const clockShort = (t) => clock(t).replace(/ [ap]m$/, "");
  const hoursOf = (t) => { const p = new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "numeric", hourCycle: "h23", timeZone: TZNAME }).formatToParts(t); const g = (k) => Number(p.find((x) => x.type === k).value); return g("hour") + g("minute") / 60; };
  const hm = (ms) => { const m = Math.round(ms / 60000); return `${Math.floor(m / 60)} h ${m % 60} min`; };
  const torontoToday = () => new Date().toLocaleDateString("en-CA", { timeZone: TZNAME });
  const timeOf = (iso) => iso ? new Date(iso).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: TZNAME }).replace(" AM", " am").replace(" PM", " pm") : "";
  const timeOnly = (iso) => iso ? clock(new Date(iso)) : "";

  const WX = [
    [[0], "Clear"], [[1], "Mostly clear"], [[2], "Partly cloudy"], [[3], "Cloudy"],
    [[45, 48], "Fog"], [[51, 53, 55, 56, 57], "Drizzle"], [[61, 63, 65, 66, 67, 80, 81, 82], "Rain"],
    [[71, 73, 75, 77, 85, 86], "Snow"], [[95, 96, 99], "Thunderstorms"],
  ];
  const wx = (code) => (WX.find(([codes]) => codes.includes(Number(code))) || [[], "—"])[1];
  const deg = (t) => `${Math.round(t)}°`;
  // weather glyphs drawn like the tab icons: thin rounded strokes, orange only for the sun itself
  const WXI = {
    sun: '<circle cx="12" cy="12" r="4" class="s"/><path class="s" d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M5.6 18.4L7 17M17 7l1.4-1.4"/>',
    moon: '<path d="M19 14.5A7.5 7.5 0 1 1 9.5 5a6 6 0 0 0 9.5 9.5z"/>',
    partly: '<path class="s" d="M8.5 3.5v1.5M3.5 8.5H5M5 5l1 1M12 5l-1 1"/><path class="s" d="M5.6 11.4A3.5 3.5 0 1 1 11.6 8"/><path d="M8.5 20h9a3.5 3.5 0 0 0 0-7h-.3a5 5 0 0 0-9.4 1.2A2.9 2.9 0 0 0 8.5 20z"/>',
    cloud: '<path d="M7 19h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 12.1 3.5 3.5 0 0 0 7 19z"/>',
    rain: '<path d="M7 15h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 8.1 3.5 3.5 0 0 0 7 15z"/><path d="M8.5 18l-1 2.5M12.5 18l-1 2.5M16.5 18l-1 2.5"/>',
    drizzle: '<path d="M7 15h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 8.1 3.5 3.5 0 0 0 7 15z"/><path d="M8.5 18.5v.5M12.5 18.5v.5M16.5 18.5v.5M10.5 21v.5M14.5 21v.5"/>',
    snow: '<path d="M7 14h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 7.1 3.5 3.5 0 0 0 7 14z"/><path d="M8.5 18h.01M12.5 18h.01M16.5 18h.01M10.5 21h.01M14.5 21h.01"/>',
    fog: '<path d="M4 9h16M3 13h18M6 17h12"/>',
    storm: '<path d="M7 14h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 7.1 3.5 3.5 0 0 0 7 14z"/><path d="M12.5 15l-2 3.5h3l-2 3.5"/>',
  };
  function wxKind(code, isDay) {
    const c = Number(code);
    const k = c <= 1 ? "sun" : c === 2 ? "partly" : c === 3 ? "cloud" : [45, 48].includes(c) ? "fog" : [51, 53, 55, 56, 57].includes(c) ? "drizzle"
      : [71, 73, 75, 77, 85, 86].includes(c) ? "snow" : [95, 96, 99].includes(c) ? "storm" : [61, 63, 65, 66, 67, 80, 81, 82].includes(c) ? "rain" : "cloud";
    return !isDay && k === "sun" ? "moon" : !isDay && k === "partly" ? "cloud" : k;
  }
  const wxIcon = (code, isDay) => `<svg class="wxi" viewBox="0 0 24 24" aria-hidden="true">${WXI[wxKind(code, isDay)]}</svg>`;
  const weatherDay = (d) => (state.data.weather && state.data.weather.daily && state.data.weather.daily[d]) || null;

  // current conditions straight from Open-Meteo when the app opens, falling back to the last build
  let live = null, liveAt = 0;
  function refreshLive() {
    if (Date.now() - liveAt < 10 * 60000) return;
    liveAt = Date.now();
    fetch(`https://api.open-meteo.com/v1/forecast?latitude=${LAT()}&longitude=${LON()}&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min&timezone=${encodeURIComponent(TZNAME)}&forecast_days=1`)
      .then((r) => r.json())
      .then((b) => {
        if (!b.current) return;
        live = { temp: b.current.temperature_2m, code: b.current.weather_code, isDay: b.current.is_day,
                 hi: b.daily && b.daily.temperature_2m_max[0], lo: b.daily && b.daily.temperature_2m_min[0] };
        if (route() === "now") render();
      })
      .catch(() => {});
  }
  function currentWeather() {
    if (live) return live;
    const c = state.data.weather && state.data.weather.current, t = weatherDay(torontoToday());
    return c ? { ...c, hi: t && t[0], lo: t && t[1] } : null;
  }

  // kWh per MJ/m² of sunlight, learned from nearby days (skips outages and snow)
  const _k = {};
  function factorAround(d) {
    if (d in _k) return _k[d];
    const s = solar(), wd = state.data.weather && state.data.weather.daily;
    if (!s || !wd) return (_k[d] = null);
    const t = parseDay(d).getTime(), r = [];
    for (const [day, p] of Object.entries(s.daily)) {
      const w = wd[day];
      if (!w || w[4] == null || w[4] < 2 || p == null || p < 0.5 || (w[5] || 0) > 0 || [71, 73, 75, 77, 85, 86].includes(w[2])) continue;
      if (Math.abs(parseDay(day).getTime() - t) > 30 * 86400000) continue;
      r.push(p / w[4]);
    }
    r.sort((a, b) => a - b);
    return (_k[d] = r.length >= 7 ? r[Math.floor(r.length / 2)] : (state.data.weather.factor || null));
  }
  function expectedFor(d) {
    const w = weatherDay(d), k = factorAround(d);
    return w && w[4] != null && k ? k * w[4] : null;
  }

  // ---------- bills ----------
  const billFor = (ym) => (state.data.bills || []).find((b) => !b.preSolar && b.to.slice(0, 7) === ym) || null;
  const lineSum = (lines) => Object.values(lines).reduce((a, [k, r]) => a + Math.round(k * r * 100) / 100, 0);
  const billParts = (b) => {
    const buy = lineSum(b.buy), credit = lineSum(b.credit), k = Object.values(b.buy).reduce((a, [x]) => a + x, 0);
    const current = Math.round((b.due - (b.previous || 0)) * 100) / 100;
    return { buy, credit, kwh: k, current };
  };

  // ---------- svg ----------
  const svgText = (x, y, s, cls = "", anchor = "middle") => `<text x="${x.toFixed(1)}" y="${y.toFixed(1)}" text-anchor="${anchor}" class="${cls}">${esc(s)}</text>`;
  const niceStep = (max) => { const raw = max / 4, p = 10 ** Math.floor(Math.log10(raw)), f = raw / p; return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * p; };

  // ---------- sheets ----------
  function openSheet(title, body) {
    closeSheet(true);
    const el = document.createElement("div");
    el.className = "sheet-wrap";
    el.innerHTML = `<div class="scrim" data-close></div><section class="sheet" role="dialog" aria-modal="true" aria-label="${esc(title)}">
      <header><h2>${esc(title)}</h2><button type="button" class="done" data-close>Done</button></header>
      <div class="sheet-body">${body}</div></section>`;
    document.body.appendChild(el);
    document.body.classList.add("noscroll");
    el.addEventListener("click", (e) => { if (e.target.closest("[data-close]")) closeSheet(); });
    requestAnimationFrame(() => requestAnimationFrame(() => el.classList.add("open")));
  }
  function closeSheet(now) {
    const el = document.querySelector(".sheet-wrap");
    if (!el) return;
    document.body.classList.remove("noscroll");
    if (now || matchMedia("(prefers-reduced-motion: reduce)").matches) { el.remove(); return; }
    el.classList.remove("open");
    setTimeout(() => el.remove(), 260);
  }
  const closePops = () => document.querySelectorAll(".popover:not([hidden])").forEach((p) => { p.hidden = true; p.previousElementSibling.setAttribute("aria-expanded", "false"); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") { closeSheet(); closePops(); } });
  document.addEventListener("click", (e) => { if (!e.target.closest(".statuswrap, .popwrap")) closePops(); });
  view.addEventListener("scroll", closePops, { passive: true });

  const rows = (pairs) => `<div class="rows">${pairs.filter(Boolean).map(([k, v, cls]) => `<div class="r${cls ? " " + cls : ""}"><span>${k}</span><span class="v num">${v}</span></div>`).join("")}</div>`;

  // ======================================================================
  // NOW
  // ======================================================================
  const alerts = () => (solar() && solar().alerts) || [];

  // moon phase from the mean synodic month, counted from the new moon of 6 January 2000
  function moonPhase(t) {
    const P = 29.530588853, age = (((t.getTime() - Date.UTC(2000, 0, 6, 18, 14)) / 86400000) % P + P) % P;
    const lit = (1 - Math.cos(2 * Math.PI * age / P)) / 2, waxing = age < P / 2;
    const name = age < 1.0 || age > P - 1.0 ? "New moon" : Math.abs(age - P / 2) < 1.0 ? "Full moon"
      : Math.abs(age - P / 4) < 1.0 ? "First quarter" : Math.abs(age - 3 * P / 4) < 1.0 ? "Last quarter"
      : (waxing ? "Waxing " : "Waning ") + (lit < 0.5 ? "crescent" : "gibbous");
    return { age, lit: Math.round(lit * 100), frac: lit, waxing, name };
  }
  // the lit part as seen from the northern hemisphere: waxing lights the right side
  function moonIcon(t, cx, cy, R) {
    const m = moonPhase(t), rx = Math.abs(1 - 2 * m.frac) * R;
    const lit = m.frac < 0.02 ? "" : m.frac > 0.98 ? `<circle r="${R}" class="moonlit"/>`
      : `<path d="M0,${-R}A${R},${R} 0 0 1 0,${R}A${rx.toFixed(2)},${R} 0 0 ${m.frac > 0.5 ? 1 : 0} 0,${-R}Z" class="moonlit"/>`;
    return `<g transform="translate(${cx},${cy})${m.waxing ? "" : " scale(-1,1)"}" role="img" aria-label="${esc(m.name)}, ${m.lit}% lit"><circle r="${R}" class="moondark"/>${lit}</g>`;
  }

  function todayChart(s, fresh) {
    const d = torontoToday(), st = sunTimes(d);
    const rise = hoursOf(st.rise), set = hoursOf(st.set);
    let pts = (fresh ? s.todayCurve || [] : []).map(([t, kw]) => { const [h, m] = t.split(":").map(Number); return [h + m / 60, kw]; });
    // SolarEdge reports the unfinished quarter hour as 0; while the sun is up, drop trailing zeros
    const nowH = hoursOf(new Date());
    // a real dusk tapers off; a sudden drop to 0 on the last reading is the unfinished quarter hour
    if (pts.length > 1 && pts.at(-1)[1] === 0 && pts.at(-2)[1] > 0.3) pts.pop();
    if (nowH < set) while (pts.length > 1 && pts.at(-1)[1] === 0 && pts.some((p) => p[1] > 0)) pts.pop();
    pts = pts.filter((p) => p[0] >= rise - 0.75 && p[0] <= set + 0.75);
    const exp = expectedFor(d);
    const W = contentWidth(), H = state.nowH || 200, top = 22, bot = 26, x0 = rise - 0.6, x1 = set + 0.6;
    const X = (h) => ((h - x0) / (x1 - x0)) * W;
    // what today's forecast sunlight should give, spread over daylight hours, on the same kW scale
    const expPeak = exp ? exp * Math.PI / (2 * (set - rise)) : 0;
    const ymax = Math.max(1, expPeak, ...pts.map((p) => p[1])) * 1.15;
    const Y = (v) => top + (H - top - bot) * (1 - v / ymax);
    let g = "";
    const step = ymax > 5 ? 2 : 1;
    for (let v = step; v < ymax; v += step) g += `<line x1="0" x2="${W}" y1="${Y(v).toFixed(1)}" y2="${Y(v).toFixed(1)}" class="gridline"/>` + svgText(0, Y(v) - 4, `${v} kW`, "", "start");
    g += `<line x1="0" x2="${W}" y1="${Y(0)}" y2="${Y(0)}" class="axisline"/>`;
    if (expPeak) {
      let p = "";
      for (let i = 0; i <= 48; i++) p += `${i ? "L" : "M"}${X(rise + (set - rise) * i / 48).toFixed(1)},${Y(expPeak * Math.sin(Math.PI * i / 48)).toFixed(1)}`;
      g += `<path d="${p}" class="ghost"/>`;
    }
    const isDay = nowH >= rise && nowH <= set;
    if (!isDay) g += moonIcon(new Date(), W - 14, 14, 10);
    if (pts.some((p) => p[1] > 0)) {
      const line = pts.map((p) => `${X(p[0]).toFixed(1)},${Y(p[1]).toFixed(1)}`);
      g += `<path d="M${X(pts[0][0]).toFixed(1)},${Y(0)}L${line.join("L")}L${X(pts.at(-1)[0]).toFixed(1)},${Y(0)}Z" class="sunfill"/>`;
      g += `<path d="M${line.join("L")}" class="sunline"/>`;
      const last = pts.at(-1);
      if (nowH < set + 0.5 && last[1] > 0) {
        const lx = X(last[0]), ly = Y(last[1]), hh = Math.floor(last[0]), mm = Math.round((last[0] - hh) * 60);
        const lab = new Date(2000, 0, 1, hh, mm).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" }).replace(/ [AP]M$/, "");
        g += `<circle cx="${lx.toFixed(1)}" cy="${ly.toFixed(1)}" r="4.5" class="dot"/>`;
        g += svgText(lx + (lx > W - 50 ? -8 : 8), Math.max(12, ly - 7), lab, "sunlabel", lx > W - 50 ? "end" : "start");
      }
    }
    // sunrise and sunset marked with a small horizon glyph and the time
    const horizon = (x, up) => `<g transform="translate(${x.toFixed(1)},${(Y(0) + 13).toFixed(1)})" class="rise"><path d="M-7 3h14M-4.2 3a4.2 4.2 0 0 1 8.4 0"/><path d="${up ? "M0 -7.5v-4M-2 -9.5l2-2 2 2" : "M0 -11.5v4M-2 -9.5l2 2 2-2"}" transform="translate(0,4)"/></g>`;
    g += horizon(X(rise), true) + svgText(X(rise) + 11, Y(0) + 17, clockShort(st.rise), "", "start");
    g += horizon(X(set), false) + svgText(X(set) - 11, Y(0) + 17, clockShort(st.set), "", "end");
    g += svgText(X((rise + set) / 2), Y(0) + 17, "noon");
    const label = `Solar power today from sunrise at ${clock(st.rise)} to sunset at ${clock(st.set)}`;
    return { svg: `<svg class="chart" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(label)}">${g}</svg>`, exp, st };
  }

  function nowScreen() {
    const today = new Date().toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", timeZone: TZNAME });
    const sx = solar(), al = alerts();
    const stLabel = !sx ? "" : al.length ? `${al.length === 1 ? "1 alert" : al.length + " alerts"} from SolarEdge` : sx.alertsChecked ? "System normal" : "Alerts not checked yet";
    const stNote = !sx ? "" : al.length ? "Details are at the top of this screen." : sx.alertsChecked ? `SolarEdge reported no problems when it was checked at ${esc(timeOnly(sx.alertsChecked))}.` : "";
    const dot = sx ? `<div class="statuswrap"><button type="button" class="statusdot ${al.length ? "bad" : sx.alertsChecked ? "" : "unknown"}" data-pop aria-label="${esc(stLabel)}" aria-expanded="false"><i></i></button>
      <div class="popover" role="status" hidden><b>${esc(stLabel)}</b>${stNote ? `<span>${stNote}</span>` : ""}</div></div>` : "";
    const head = `<div class="top nowhead"><div><div class="eyebrow">${esc(today)}</div><h1>Now</h1></div>
      <div class="topright">${dot}<a class="iconbtn" href="#settings" aria-label="Settings"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="2.4"/><circle cx="15" cy="17" r="2.4"/></svg></a></div></div>`;
    const s = solar();
    if (!s) {
      return head + `<section class="first"><p class="lead">SolarEdge isn't connected yet.</p>
        <p class="sub">${state.data.connectUrl ? "Sign in with your SolarEdge account and approve access to see what the panels are making." : "Add your SolarEdge client ID, client secret and site ID as repository secrets in GitHub, then run the workflow again."}</p>${connectBtn()}</section>`;
    }
    // overnight the last numbers belong to yesterday; don't show them as today's
    const fresh = !s.todayDate || s.todayDate === torontoToday();
    const { svg, exp, st } = todayChart(s, fresh), nowD = new Date();
    // after dark the last reading is stale, so don't show it as power right now
    const todayKwh = fresh ? s.today : 0, nowKw = fresh && nowD < new Date(st.set.getTime() + 30 * 60000) ? s.nowKw : 0;
    const nowNote = nowKw > 0 ? `of ${fmt(s.peakKw, 2)} kW` : nowD < st.rise ? `sunrise ${clock(st.rise)}` : nowD > st.set ? `sun set at ${clock(st.set)}` : "not producing";

    const stale = needsConnect() ? `<section class="notice"><b>SolarEdge needs you to sign in again.</b> These are the last numbers it sent.${connectBtn()}</section>`
      : s.authTroubleSince ? `<section class="notice"><b>SolarEdge isn't responding.</b> These are the last numbers it sent. The app keeps trying every hour.</section>` : "";
    const a = alerts();
    const alertBox = a.length
      ? `<section class="alerts" id="alerts">${a.map((x) => `<div class="status bad"><i class="dot-s"></i><span><b>${esc(x.type || "Alert")}</b><span class="sub">${[x.component, x.impact != null && `impact ${x.impact} of 9`, x.first && `since ${timeOf(x.first)}`].filter(Boolean).map(esc).join(" · ")}</span></span></div>`).join("")}
         <p class="sub">SolarEdge also opened an issue in your GitHub repo, which emails you.</p></section>` : "";

    const t = state.data.weather && state.data.weather.tomorrow;
    const w = currentWeather(), wrows = [];
    if (w) wrows.push([`<span class="wxrow">${wxIcon(w.code, w.isDay ?? 1)}${deg(w.temp)} and ${esc(wx(w.code).toLowerCase())}</span>`, w.hi != null ? `H ${deg(w.hi)} <span class="sub">L ${deg(w.lo)}</span>` : ""]);
    if (t) wrows.push([`<span class="wxrow">${wxIcon(t[3], 1)}Tomorrow, ${esc(wx(t[3]).toLowerCase())}</span>`, `H ${deg(t[1])} <span class="sub">L ${deg(t[2])}</span>`]);

    const since = s.installed ? s.installed.slice(0, 4) : "install";
    return `${head}${stale}${alertBox}
      <section class="first nowtop">
        <div class="pair">
          <div><div class="label">Generating now</div><div class="big num ${nowKw > 0 ? "sun" : "dim"}">${fmt(nowKw, nowKw ? 2 : 0)}<small> kW</small></div><div class="sub">${esc(nowNote)}</div></div>
          <div><div class="label">So far today</div><div class="big num">${fmt(todayKwh, 1)}<small> kWh</small></div>${exp ? `<div class="sub">${fmt(exp)} kWh expected</div>` : ""}</div>
        </div>
        ${svg}
      </section>
      ${wrows.length ? `<section class="nowwx"><div class="group-label">Weather</div>${rows(wrows)}</section>` : ""}
      <section class="nowgen">
        <div class="group-label">Generated by solar</div>
        <div class="trio num">
          <div><div class="label">This month</div><div class="n">${kwh(s.month)}</div><div class="unit">kWh</div></div>
          <div><div class="label">This year</div><div class="n">${fmt(s.year)}</div><div class="unit">kWh</div></div>
          <div><div class="label">Since ${esc(since)}</div><div class="n">${fmt(s.lifetime)}</div><div class="unit">kWh</div></div>
        </div>
        ${s.updated ? `<p class="sub updated">Updated ${esc(new Date(s.updated).toLocaleString("en-US", { month: "long", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: TZNAME }).replace(" at ", ", ").replace(" AM", " am").replace(" PM", " pm"))}</p>` : ""}
      </section>`;
  }

  // ======================================================================
  // MONTH
  // ======================================================================
  function monthStrip() {
    const year = state.month.slice(0, 4), all = new Set(months());
    const yms = Array.from({ length: 12 }, (_, i) => `${year}-${String(i + 1).padStart(2, "0")}`);
    // bar height is what the month would have cost without solar; energy when the year has no costs
    const cost = (ym) => { const m = M()[ym]; return m && m.grid != null ? m.grid + Math.max(0, m.saved || 0) : null; };
    const useMoney = yms.some((ym) => cost(ym) != null);
    const energy = (ym) => { const t = monthStats(ym).t; return t.hDays ? t.imp + t.self : t.prod || null; };
    const vs = yms.map((ym) => [ym, all.has(ym) ? (useMoney ? cost(ym) : energy(ym)) : null, all.has(ym)]);
    const mx = Math.max(1, ...vs.map(([, v]) => v || 0));
    return `<div class="strip" role="group" aria-label="Months of ${year}">${vs.map(([ym, v, has]) => {
      const on = ym === state.month, letter = new Date(Number(year), Number(ym.slice(5)) - 1, 1).toLocaleDateString("en-US", { month: "narrow" });
      return `<button type="button" data-ym="${ym}" ${has ? "" : "disabled"} aria-pressed="${on}" aria-label="${esc(monthName(ym))}">
        <span class="sb"><i class="${v == null ? (has ? "thin" : "none") : ""}" style="${v != null ? `height:${(4 + 30 * v / mx).toFixed(1)}px` : ""}"></i></span><span class="sl">${letter}</span></button>`;
    }).join("")}</div>`;
  }

  function monthHead() {
    const all = months(), i = all.indexOf(state.month);
    const prev = i > 0 ? all[i - 1] : null, next = i < all.length - 1 ? all[i + 1] : null;
    return `<div class="top"><div><div class="eyebrow">${state.month.slice(0, 4)}</div><h1>${esc(mName(state.month))}</h1></div>
      <div class="steps"><button type="button" ${prev ? `data-ym="${prev}"` : "disabled"} aria-label="Previous month">‹</button><button type="button" ${next ? `data-ym="${next}"` : "disabled"} aria-label="Next month">›</button></div></div>
      ${monthStrip()}`;
  }

  function moneyBlock(ym) {
    const m = M()[ym];
    if (!m || (m.grid == null && m.saved == null)) return "";
    const name = mName(ym), isBill = m.gridSource === "bill", sofar = m.complete === false;
    const grid = m.grid != null ? dollars(m.grid) : "–";
    let bar = "", line = "";
    if (m.grid != null && m.saved != null && m.without > 0) {
      bar = `<div class="split" role="img" aria-label="Grid ${dollars(m.grid)}, solar ${dollars(m.saved)}"><i style="flex:${m.grid};background:var(--grid)"></i><i style="flex:${Math.max(0, m.saved)};background:var(--sun)"></i></div>`;
      line = `<p class="lead">Without solar, ${esc(name)} would have cost <b class="num">${dollars(m.without)}</b>.</p>`;
    } else if (m.grid == null) {
      line = `<p class="sub">${sofar ? "The grid cost shows once the month is over and the meter data is in." : "No meter data or bill for this month, so the grid cost isn't known."}</p>`;
    }
    const src = isBill
      ? `<button type="button" class="linkline" data-sheet="bill">From your Toronto Hydro bill${chev}</button>`
      : m.grid != null ? `<p class="sub">${totals(monthDays(ym)).hDays ? "Estimated from your meter" : "Estimated from the kWh on your later bills"}. No bill on file for ${esc(name)}.</p>` : "";
    return `<section class="first">
      <div class="pair">
        <div><div class="label">Paid to the grid</div><div class="big num">${grid}</div></div>
        ${(() => {
          const note = m.credits >= 1 && m.exp != null ? `*Includes an estimated ${dollars(m.credits)} in net metering credits for ${fmt(totals(monthDays(ym)).hDays >= 25 ? totals(monthDays(ym)).exp : m.exp)} kWh sent back${m.selfValue >= 1 ? `, and ${dollars(m.selfValue)} of power the house took straight from the panels` : ""}.` : "";
          const body = `<div class="label">Saved by solar${sofar ? " so far" : ""}${note ? '<span class="ast">*</span>' : ""}</div><div class="big num sun">${m.saved != null ? dollars(m.saved) : "–"}</div>`;
          return note ? `<div class="popwrap"><button type="button" class="popbtn" data-pop aria-expanded="false" aria-label="How solar saved ${m.saved != null ? dollars(m.saved) : ""}">${body}</button><div class="popover left" role="status" hidden><span>${esc(note)}</span></div></div>` : `<div>${body}</div>`;
        })()}
      </div>${bar}${line}${src}</section>`;
  }

  function dayChart(ym) {
    const days = monthDays(ym);
    const hasHome = days.some((r) => r.home != null), hasImp = days.some((r) => r.imp != null), hasProd = days.some((r) => r.prod != null);
    if (!hasImp && !hasProd) return "";
    const segs = (r) => r.home != null ? [[r.imp, "grid"], [r.self, "sun"]] : r.imp != null ? [[r.imp, "grid"]] : (!hasImp && r.prod != null) ? [[r.prod, "sun"]] : null;
    const val = (r) => { const x = segs(r); return x ? x.reduce((a, [v]) => a + v, 0) : null; };
    const vals = days.map(val).filter((v) => v != null);
    const avg = vals.reduce((a, b) => a + b, 0) / vals.length;
    const W = contentWidth(), H = 196, top = 10, bot = 20, right = 44, n = days.length, pw = W - right, bw = pw / n;
    const step = niceStep(Math.max(...vals)), ymax = Math.ceil(Math.max(...vals) / step) * step || 1;
    const Y = (v) => top + (H - top - bot) * (1 - v / ymax);
    let g = "";
    for (let v = step; v <= ymax + 1e-9; v += step) {
      g += `<line x1="0" x2="${pw}" y1="${Y(v).toFixed(1)}" y2="${Y(v).toFixed(1)}" class="gridline"/>`;
      if (Math.abs(Y(v) - Y(avg)) > 12) g += svgText(pw + 6, Y(v) + 4, fmt(v), "", "start");
    }
    days.forEach((r, i) => {
      const x = i * bw, on = r.d === state.day, s = segs(r);
      if (on) g += `<rect x="${(x).toFixed(1)}" y="0" width="${bw.toFixed(1)}" height="${H - bot + 2}" rx="3" class="sel"/>`;
      let acc = 0;
      if (s) s.forEach(([v, c]) => { g += `<rect x="${(x + 1).toFixed(1)}" y="${Y(acc + v).toFixed(1)}" width="${Math.max(1.5, bw - 2).toFixed(1)}" height="${Math.max(0, Y(acc) - Y(acc + v)).toFixed(1)}" class="b-${c}"/>`; acc += v; });
      g += `<rect x="${x.toFixed(1)}" y="0" width="${bw.toFixed(1)}" height="${H}" class="hit" data-day="${r.d}" role="button" aria-label="${esc(dayName(r.d))}"/>`;
    });
    g += `<line x1="0" x2="${pw}" y1="${Y(avg).toFixed(1)}" y2="${Y(avg).toFixed(1)}" class="avgline"/>` + svgText(pw + 6, Y(avg) + 4, "avg " + kwh(avg).replace(/\.\d$/, (x) => avg < 10 ? x : ""), "strong", "start");
    [1, 8, 15, 22, 29].filter((d) => d <= n).forEach((d) => { g += svgText((d - 0.5) * bw, H - 4, d); });
    const legend = [(hasImp) && `<span><i class="lg-grid"></i>Grid</span>`, (hasHome || !hasImp) && `<span><i class="lg-sun"></i>Solar</span>`, `<span class="u">kWh a day</span>`].filter(Boolean).join("");
    return `<section><div class="legend">${legend}</div>
      <svg class="chart" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="group" aria-label="Daily chart, tap a day for detail">${g}</svg>
      <p class="sub">Tap a day to see it.</p></section>`;
  }

  function facts(ym) {
    const days = monthDays(ym), cur = monthStats(ym);
    const all = months(), i = all.indexOf(ym), prev = i > 0 ? monthStats(all[i - 1]) : null, pn = prev ? mName(prev.ym) : "";
    const out = [];
    const add = (p, html) => out.push([p, html]);
    const mo = Number(ym.slice(5));

    // an outage first: the meter shows nothing sent back and SolarEdge shows nothing made
    const prodDays = days.filter((r) => r.prod != null && r.prod > 0.5);
    const typical = prodDays.length ? prodDays.reduce((a, r) => a + r.prod, 0) / prodDays.length : 0;
    const dead = days.filter((r) => r.imp != null && r.exp < 0.05 && (r.prod == null || r.prod < 0.5) && typical > 8);
    if (dead.length >= 2) {
      const range = dead.length > 2 ? `${shortDay(dead[0].d)} to ${shortDay(dead.at(-1).d)}` : dead.map((r) => shortDay(r.d)).join(" and ");
      add(0, `<b class="bad">No solar on ${dead.length} days</b>, ${esc(range)}. The meter shows nothing sent back either, so the system was likely off. That's about <b>${fmt(typical * dead.length)}</b> kWh missed.`);
    }
    // production against what the sunlight predicted
    const perf = days.map((r) => [r, r.prod != null ? expectedFor(r.d) : null]).filter(([r, e]) => e != null && e > 1 && parseDay(r.d) < parseDay(torontoToday()));
    if (perf.length >= 7) {
      const act = perf.reduce((a, [r]) => a + r.prod, 0), ex = perf.reduce((a, [, e]) => a + e, 0), p = pct(act, ex);
      const weak = perf.filter(([r, e]) => e >= 8 && r.prod < 0.6 * e && !(weatherDay(r.d) && (weatherDay(r.d)[5] || 0) > 0));
      const overall = p >= 95 ? "Overall your solar output matched the available sunshine."
        : p >= 85 ? `Overall your solar output was a little under the available sunshine, at <b>${p}%</b>.`
        : `Overall your solar output fell short of the available sunshine, at <b class="bad">${p}%</b>.`;
      const names = weak.slice(0, 3).map(([r]) => shortDay(r.d));
      const more = weak.length - names.length;
      const list = more ? `${names.join(", ")} and ${more} more ${more === 1 ? "day" : "days"}` : names.length > 1 ? `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}` : names[0];
      add(p < 85 ? 1 : 4, `${overall}${weak.length ? ` ${list} underperformed.` : ""}`);
    }
    // home use against last month
    const curUse = cur.home ?? cur.imp, prevUse = prev ? (cur.home != null ? prev.home : prev.imp) : null;
    if (curUse != null && prevUse) {
      const c = change(curUse, prevUse), what = cur.home != null ? "Home use" : "Grid use";
      if (Math.abs(c) >= 5) add(2, `${what} ${c > 0 ? "rose" : "fell"} <b>${Math.abs(c)}%</b> on ${esc(pn)}, to <b>${fmt(curUse)}</b> kWh a day.${c > 15 && mo >= 9 ? " Heating has started." : c < -15 && mo <= 6 ? " Less heating as it warms up." : ""}`);
      else add(6, `${what} held steady at <b>${fmt(curUse)}</b> kWh a day.`);
    }
    // share of the house the panels covered
    if (cur.cover != null) {
      const p = prev && prev.cover != null ? prev.cover : null;
      add(3, `Solar covered <b>${cur.cover}%</b> of the house${p != null && p !== cur.cover ? `, ${cur.cover > p ? "up" : "down"} from ${p}%` : ""}.`);
    }
    // solar against the same month a year earlier
    const ly = `${Number(ym.slice(0, 4)) - 1}${ym.slice(4)}`, lys = monthStats(ly);
    if (cur.prod != null && lys.prod && lys.t.pDays >= 20) {
      const c = change(cur.prod, lys.prod);
      add(5, `Solar was <b>${Math.abs(c)}%</b> ${c >= 0 ? "higher" : "lower"} than ${esc(monthName(ly))}, ${fmt(cur.prod, 1)} kWh a day against ${fmt(lys.prod, 1)}.`);
    }
    if (cur.prod != null && prev && prev.prod && cur.home == null) {
      const c = change(cur.prod, prev.prod);
      add(5, `Solar was <b>${Math.abs(c)}%</b> ${c >= 0 ? "up" : "down"} on ${esc(pn)}.`);
    }
    const top = out.sort((a, b) => a[0] - b[0]).slice(0, 3);
    return top.length ? `<section><div class="label">What changed</div><div class="facts">${top.map(([, h]) => `<p>${h}</p>`).join("")}</div></section>` : "";
  }

  function ledger(ym) {
    const days = monthDays(ym), t = totals(days), gm = (state.data.gridMonthly || {})[ym];
    const r = [];
    const perDay = (v, n) => n ? fmt(v / n, 1) : "";
    const ic = (d, cls) => `<svg class="li ${cls}" viewBox="0 0 24 24" aria-hidden="true">${d}</svg>`;
    const icTower = ic('<path d="M12 3L8 21M12 3l4 18M7 8h10M6 13h12M9.4 13L12 17.5 14.6 13M9 8l3 5 3-5"/>', "g");
    const icSun = ic('<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M2.5 12h2M19.5 12h2M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>', "s");
    const icHome = ic('<path d="M3.5 10.5L12 3.5l8.5 7V20a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1z"/><path d="M13 10.5l-2.5 4h3l-2.5 4"/>', "s");
    const icBack = ic('<path d="M2.5 12h7M7 9l3 3-3 3"/><path d="M17 3l-3 18M17 3l3 18M14 8h6M13.3 13.5h7.4"/>', "s");
    const lab = (icon, text, sub) => `<span class="lk${sub ? " sub2" : ""}">${icon}${text}</span>`;
    if (t.hDays) r.push([lab(icTower, "Bought from grid"), kwh(t.imp), perDay(t.imp, t.hDays)]);
    else if (gm) r.push([lab(icTower, "Bought from grid <span class=\"sub\">bill</span>"), fmt(gm), ""]);
    if (t.pDays) r.push([lab(icSun, "Produced"), kwh(t.prod), perDay(t.prod, t.pDays), "sun"]);
    if (t.bothDays) r.push([lab(icHome, "Used immediately", true), kwh(t.self), perDay(t.self, t.bothDays)]);
    if (t.hDays) r.push([lab(icBack, "Sent back to grid", true), kwh(t.exp), perDay(t.exp, t.hDays)]);
    if (!r.length) return "";
    return `<section class="accsec"><details class="acc"${state.ledgerOpen ? " open" : ""}><summary>Energy Consumption (in kWh)${chev}</summary>
      <table class="ledger num"><thead><tr><th></th><th>Month</th><th>A day</th></tr></thead><tbody>
      ${r.map(([k, a, b, c]) => `<tr><td>${k}</td><td class="${c || ""}">${a}</td><td class="${c || ""}">${b}</td></tr>`).join("")}</tbody></table>
      ${t.hDays && t.hDays < daysIn(ym) || (t.pDays && t.pDays < daysIn(ym) && ym < torontoToday().slice(0, 7)) ? `<p class="sub">${[t.hDays && t.hDays < daysIn(ym) ? `Meter data for ${t.hDays} of ${daysIn(ym)} days` : "", t.pDays && t.pDays < daysIn(ym) && ym < torontoToday().slice(0, 7) ? `SolarEdge data for ${t.pDays} days` : ""].filter(Boolean).join(", ")}.</p>` : ""}
      </details></section>`;
  }

  function monthScreen() {
    if (!state.month) return `<div class="top"><div><h1>Month</h1></div></div><section class="first"><p class="lead">No data yet.</p><p class="sub">Add a Toronto Hydro export to data/hydro or connect SolarEdge.</p></section>`;
    return monthHead() + moneyBlock(state.month) + dayChart(state.month) + facts(state.month) + ledger(state.month);
  }

  function daySheet(d) {
    const r = monthDays(d.slice(0, 7)).find((x) => x.d === d);
    const p = [];
    if (r.home != null) p.push(["Home used", `<b>${kwh(r.home)} kWh</b>`]);
    if (r.imp != null) p.push(["Bought from grid", `${kwh(r.imp)} kWh`]);
    if (r.prod != null) p.push(["Solar produced", `${kwh(r.prod)} kWh`, "sun"]);
    const ex = r.prod != null ? expectedFor(r.d) : null;
    if (ex != null && ex > 0.5) p.push(["Expected from the sunlight", `${kwh(ex)} kWh <span class="sub">· ${pct(r.prod, ex)}%</span>`]);
    if (r.self != null) p.push(["Used immediately", `${kwh(r.self)} kWh`]);
    if (r.exp != null) p.push(["Sent back to grid", `${kwh(r.exp)} kWh`]);
    if (!p.length) p.push(["No data for this day", ""]);
    const wd = weatherDay(r.d), sun = sunTimes(r.d), w = [];
    if (wd) { w.push([esc(wx(wd[2])), `H ${deg(wd[0])} <span class="sub">L ${deg(wd[1])}</span>`]); if (wd[3] != null) w.push(["Sunshine", `${fmt(wd[3], 1)} h`]); }
    w.push(["Sunrise and sunset", `${clock(sun.rise)} · ${clock(sun.set)}`], ["Daylight", hm(sun.set - sun.rise)]);
    return rows(p) + `<div class="gap"></div>` + rows(w);
  }

  function billSheet(ym) {
    const b = billFor(ym), p = billParts(b), name = mName(ym);
    const tou = ["on", "mid", "off"].filter((k) => b.buy[k]).map((k) => [`<span class="indent">${{ on: "On-peak", mid: "Mid-peak", off: "Off-peak" }[k]} <span class="sub">${fmt(b.buy[k][0])} kWh at ${fmt(b.buy[k][1] * 100, 1)}¢</span></span>`, money(b.buy[k][0] * b.buy[k][1]), "minor"]);
    const r = [
      [`Electricity bought <span class="sub">${fmt(p.kwh)} kWh</span>`, money(p.buy)], ...tou,
      p.credit > 0 ? [`Energy credit <span class="sub">${fmt(b.generated)} kWh sent back</span>`, money(-p.credit), "sun"] : null,
      ["Delivery", money(b.delivery)], ["Regulatory", money(b.regulatory)],
      b.other ? ["Late payment charge", money(b.other)] : null,
      ["HST", money(b.hst)], b.rebate ? ["Ontario Electricity Rebate", money(-b.rebate)] : null,
      [`<b>${esc(name)} charges</b>`, `<b>${money(p.current)}</b>`, "total"],
    ];
    const mm = M()[ym] || {}, dc = mm.deliveryCredit || 0;
    const creditNote = p.credit > 0.5 ? `<p class="sub">Net metering also takes about <b class="sun">${money(dc)}</b> off the delivery and regulatory lines, because those are charged on what you bought minus what you sent back. Toronto Hydro folds that into the lines rather than printing it. HST is charged as if neither credit applied, while the rebate is worked out after both.</p>` : "";
    const carried = Math.abs(b.previous || 0) >= 0.5 ? (b.previous > 0 ? `The amount due was ${money(b.due)}, including ${money(b.previous)} carried over unpaid from the bill before.` : `The amount due was ${money(b.due)} after a ${money(-b.previous)} credit from the bill before.`) : "";
    return `<p class="sub">${shortDay(b.from)} to ${shortDay(b.to)} · ${fmt(p.current / p.kwh * 100, 1)}¢ per kWh all in · ${b.season} prices</p>${rows(r)}${creditNote}${carried ? `<p class="sub">${carried}</p>` : ""}`;
  }

  // ======================================================================
  // HISTORY
  // ======================================================================
  function yearTotals() {
    const ys = {};
    for (const [k, m] of Object.entries(M())) {
      const y = (ys[k.slice(0, 4)] ||= { grid: 0, saved: 0, gridN: 0, last: null, first: null });
      y.grid += m.grid || 0; y.saved += m.saved || 0;
      if (m.grid != null) { y.gridN++; y.last = k; y.first ||= k; }
    }
    if (solar()) for (const [d, v] of Object.entries(solar().daily)) { const y = (ys[d.slice(0, 4)] ||= { grid: 0, saved: 0, gridN: 0 }); y.prod = (y.prod || 0) + (v || 0); }
    return ys;
  }

  function historyChart() {
    const ys = Object.keys(yearTotals()).sort().reverse();
    if (!ys.length) return "";
    const W = contentWidth(), rowH = 64, lab = 42, top = 6, H = ys.length * rowH + 18, bw = (W - lab) / 12;
    const vals = ys.flatMap((y) => Array.from({ length: 12 }, (_, i) => { const m = M()[`${y}-${String(i + 1).padStart(2, "0")}`]; return m ? (m.grid || 0) + Math.max(0, m.saved || 0) : 0; }));
    const mx = Math.max(1, ...vals), sc = (v) => (rowH - 16) * v / mx;
    let g = "";
    ys.forEach((y, r) => {
      const base = top + r * rowH + rowH - 10;
      g += svgText(0, base - 2, y, "strong", "start") + `<line x1="${lab}" x2="${W}" y1="${base}" y2="${base}" class="axisline"/>`;
      for (let i = 0; i < 12; i++) {
        const ym = `${y}-${String(i + 1).padStart(2, "0")}`, m = M()[ym], x = lab + i * bw + 2, w = Math.max(2, bw - 4);
        if (!m) continue;
        const gh = m.grid != null ? sc(m.grid) : 0, sh = m.saved != null ? sc(Math.max(0, m.saved)) : 0;
        if (ym === state.month) g += `<circle cx="${(x + w / 2).toFixed(1)}" cy="${base + 5}" r="2.2" class="seldot"/>`;
        if (gh) g += `<rect x="${x.toFixed(1)}" y="${(base - gh).toFixed(1)}" width="${w.toFixed(1)}" height="${gh.toFixed(1)}" class="b-grid${m.gridSource === "estimate" ? " est" : ""}"/>`;
        if (sh) g += `<rect x="${x.toFixed(1)}" y="${(base - gh - sh).toFixed(1)}" width="${w.toFixed(1)}" height="${sh.toFixed(1)}" class="b-sun"/>`;
        g += `<rect x="${(x - 2).toFixed(1)}" y="${base - rowH + 10}" width="${bw.toFixed(1)}" height="${rowH}" class="hit" data-ym="${ym}" data-go="month" role="button" aria-label="${esc(monthName(ym))}: paid ${m.grid != null ? dollars(m.grid) : "unknown"}, saved ${m.saved != null ? dollars(m.saved) : "unknown"}"/>`;
      }
    });
    "JFMAMJJASOND".split("").forEach((c, i) => { g += svgText(lab + i * bw + bw / 2, H - 2, c); });
    return `<section><div class="label">Cost each month, from the <b class="ink">grid</b> and saved by <b class="sun">solar</b>. Same scale every year.</div>
      <svg class="chart" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="group" aria-label="Monthly cost by year">${g}</svg>
      <p class="sub">Paler bars are estimates. Tap a month to open it.</p></section>`;
  }

  function historyScreen() {
    const ms = Object.entries(M());
    if (!ms.length) return `<div class="top"><div><h1>History</h1></div></div><section class="first"><p class="lead">No cost history yet.</p></section>`;
    const grid = ms.reduce((a, [, m]) => a + (m.grid || 0), 0), saved = ms.reduce((a, [, m]) => a + (m.saved || 0), 0);
    const first = ms.map(([k]) => k).sort()[0], missing = ms.filter(([, m]) => m.grid == null && m.complete !== false).length;
    const ys = yearTotals(), thisYear = torontoToday().slice(0, 4);
    const instY = solar() && solar().installed ? solar().installed.slice(0, 4) : null;
    const trs = Object.keys(ys).sort().reverse().map((y) => {
      const v = ys[y];
      const note = y === thisYear && v.last ? ` <span class="sub">to ${new Date(2000, Number(v.last.slice(5)) - 1, 1).toLocaleDateString("en-US", { month: "short" })}</span>` : v.first && v.first.slice(5) !== "01" ? ` <span class="sub">from ${new Date(2000, Number(first.slice(5)) - 1, 1).toLocaleDateString("en-US", { month: "short" })}</span>` : "";
      const target = (y === thisYear || !v.last) ? (Object.keys(M()).filter((k) => k.startsWith(y) && M()[k].grid != null).at(-1) || `${y}-01`) : v.last;
      return `<tr data-ym="${target}" data-go="month"><td>${y}${note}</td><td>${dollars(v.grid)}</td><td class="sun">${dollars(v.saved)}</td><td>${v.prod != null ? fmt(v.prod) : "–"}</td></tr>`;
    }).join("");
    const bt = (state.data.money && state.data.money.backtest) || [];
    // the typical miss: three in four estimated months land at least this close to the bill
    const offs = bt.map((b) => Math.abs(b.off)).sort((a, b) => a - b), typ = offs.length ? offs[Math.floor(offs.length * 0.75)] : null;
    return `<div class="top"><div><div class="eyebrow">Since ${esc(monthName(first))}</div><h1>History</h1></div></div>
      <section class="first">
        <div class="pair">
          <div><div class="label">Paid to the grid</div><div class="big num${dollars(grid).length > 6 ? " long" : ""}">${dollars(grid)}</div></div>
          <div><div class="label">Saved by solar</div><div class="big num sun${dollars(grid).length > 6 ? " long" : ""}">${dollars(saved)}</div></div>
        </div>
        <div class="split"><i style="flex:${grid};background:var(--grid)"></i><i style="flex:${Math.max(0, saved)};background:var(--sun)"></i></div>
        <p class="lead">Solar has taken about <b>${pct(saved, grid + saved)}%</b> off what power would have cost.</p>
        ${missing ? `<p class="sub">${missing} month${missing > 1 ? "s" : ""} with no meter data or bill ${missing > 1 ? "aren't" : "isn't"} counted.</p>` : ""}
      </section>
      ${historyChart()}
      <section>
        <table class="ledger years num"><thead><tr><th></th><th>Paid</th><th>Saved</th><th>Made, kWh</th></tr></thead><tbody>${trs}</tbody></table>
        <button type="button" class="linkline" data-sheet="method">Months with a bill use the bill. The rest are estimated${typ != null ? `, usually within ${fmt(Math.max(1, Math.ceil(typ * 100)))}% of the real bill` : ""}.${chev}</button>
      </section>`;
  }

  function methodSheet() {
    const md = (state.data.money && state.data.money.model) || {}, bt = (state.data.money && state.data.money.backtest) || [];
    const r = bt.map((b) => [esc(monthName(b.month, "short")), `${money(b.estimate)} <span class="sub">bill ${money(b.bill)} · ${b.off >= 0 ? "+" : "−"}${fmt(Math.abs(b.off) * 100, 1)}%</span>`]);
    const yr = Object.entries(md.byYear || {}).at(-1), rt = yr ? yr[1] : { fixed: 0, perKwh: 0, reg: 0 };
    const carriedNow = Object.values(M()).some((x) => x.carried);
    return `<p>Months with a Toronto Hydro bill use what the bill charged. For the other months, the app prices each hour your meter recorded at Ontario's time-of-use rates and applies the net metering rules the way your bills do:</p>
      <p>Each kWh sent back earns a credit at the price of the hour it went out. Delivery (in ${yr ? yr[0] : "the latest year"}, ${money(rt.fixed)} a month plus ${fmt(rt.perKwh * 100, 2)}¢ per kWh) and regulatory charges (${fmt(rt.reg * 100, 2)}¢ per kWh) are charged on what you bought minus what you sent back, so sending power out cuts them too. HST is 13% of the charges as if no credit applied. The Ontario Electricity Rebate is taken off the electricity total after all credits.</p>
      <p>If credits ever came to more than a month's electricity charges, the extra would carry forward and be written off after 12 months. ${carriedNow ? "That has happened in some months, and the app carries it." : "That hasn't happened yet. Even your sunniest month still bought more than it sent back, so every credit has been used on the bill it was earned on."}</p>
      <p>Solar's saving is what the month would have cost with no panels, minus what it did cost. Power the house used straight from the panels is priced at the hours the sun was out, when time-of-use rates are higher.</p>
      ${r.length ? `<div class="label" style="margin-top:8px">Estimates checked against your bills</div>${rows(r)}` : ""}`;
  }

  // ======================================================================
  // SETTINGS
  // ======================================================================
  const pretty = (name) => name.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, (c) => c.toUpperCase()).replace(/\bAc\b/, "AC").replace(/\bDc\b/, "DC");
  function inverterRows() {
    const inv = solar() && solar().inverter;
    if (!inv || !inv.metrics) return "";
    const m = inv.metrics, names = Object.keys(m);
    const livem = names.filter((n) => !(typeof m[n].max === "number" && m[n].max === 0 && m[n].min === 0));
    const pick = (re) => livem.find((n) => re.test(n));
    const order = [pick(/^power$|^ac.*power|activepower/i), pick(/mode|status|state/i), pick(/temp/i), pick(/^voltage$|^ac.*volt/i), pick(/^current$|^ac.*curr/i), pick(/freq/i), pick(/dc.*power/i), pick(/dc.*volt/i), pick(/^energy$/i)];
    const shown = [...new Set(order.filter(Boolean)), ...livem.filter((n) => !order.includes(n))].slice(0, 8);
    const LABELS = { power: "Output", energy: "Energy in the last hour", voltage: "Grid voltage", current: "Current", frequency: "Grid frequency", temperature: "Temperature" };
    const UNITS = { C: "°C", CELSIUS: "°C", W: " W", WATT: " W", V: " V", VOLT: " V", HZ: " Hz", HERTZ: " Hz", A: " A", AMPERE: " A", WH: " Wh", KWH: " kWh" };
    const unitOf = (x) => { const u = String(x.unit || "").toUpperCase(); return UNITS[u] ?? (x.unit ? " " + x.unit.toLowerCase() : ""); };
    const MODES = { MPPT: "Producing", SLEEPING: "Sleeping", NIGHT: "Night", NIGHT_MODE: "Night", THROTTLED: "Limited", FAULT: "Fault", STARTING: "Starting up", OFF: "Off", SHUTTING_DOWN: "Shutting down", STANDBY: "Standby", LOCKED: "Locked" };
    const val = (x) => typeof x.latest === "number" ? fmt(x.latest, Math.abs(x.latest) < 100 ? 1 : 0) + unitOf(x) : esc(MODES[String(x.latest).toUpperCase()] || String(x.latest ?? "–").replace(/_/g, " ").toLowerCase().replace(/^./, (c) => c.toUpperCase()));
    return `<div class="group-label">Inverter readings</div>${rows(shown.map((n) => [esc(LABELS[n] || pretty(n)), val(m[n])]))}<p class="sub">Hourly from SolarEdge, last at ${esc(timeOf(inv.at))}.</p>`;
  }

  function settingsScreen() {
    const d = state.data, s = d.solar, h = Object.keys(hydro()).sort(), e = s && s.equipment;
    const ok = s && s.connected && !s.needsConnect;
    const sol = [
      ["Status", ok ? `<span class="okc">Connected</span>` : s && s.needsConnect && s.daily ? "Sign-in expired" : "Not connected"],
      ok && s.peakKw && ["System size", `${fmt(s.peakKw, 2)} kW`],
      ok && s.installed && ["Installed", esc(new Date(s.installed + "T12:00").toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }))],
    ];
    if (e) {
      (e.inverters || []).forEach((i) => {
        sol.push(["Inverter", esc(i.model || i.name || "–")]);
        if (i.firmware) sol.push(["Firmware", esc(i.firmware)]);
        if (i.communication) sol.push(["Connection", esc(({ WIFI: "Wi-Fi", ETHERNET: "Ethernet", LAN: "Ethernet", CELLULAR: "Cellular" })[String(i.communication).toUpperCase()] || pretty(String(i.communication).toLowerCase()))]);
      });
      // the inverter's own count is what's actually wired in; SolarEdge's inventory can list a replaced optimizer
      const connected = (e.inverters || []).reduce((a, i) => a + (Number(i.optimizers) || 0), 0) || e.optimizers;
      const models = [...new Set((e.optimizerModels || []).map((m) => m.split("-")[0]))];
      if (connected != null) sol.push(["Optimizers", `${connected}${models.length ? " · " + esc(models.join(", ")) : ""}`]);
    }
    if (ok && s.alertsChecked) sol.push(["Alerts checked", esc(timeOf(s.alertsChecked))]);
    const bills = (d.bills || []).filter((b) => !b.preSolar);
    return `<div class="top"><div><h1>Settings</h1></div><button type="button" class="done" data-back>Done</button></div>
      <section class="first"><div class="group-label">SolarEdge</div>${rows(sol)}
        ${ok ? `<p class="sub">Refreshes every hour during the day.${s.error ? " The last refresh failed, so these are the previous numbers." : ""}</p>` : connectBtn() + `<p class="sub">${d.connectUrl ? "You'll sign in with SolarEdge, then paste a one-time code into GitHub." : "Add SOLAREDGE_CLIENT_ID, SOLAREDGE_CLIENT_SECRET, SOLAREDGE_SITE_ID and GH_PAT under Settings, Secrets and variables, Actions in your GitHub repository."}</p>`}
        ${inverterRows()}
      </section>
      <section><div class="group-label">Toronto Hydro</div>${rows([
        ["Meter data", h.length ? `${esc(shortDay(h[0]))}, ${h[0].slice(0, 4)} to ${esc(shortDay(h.at(-1)))}, ${h.at(-1).slice(0, 4)}` : "None yet"],
        bills.length && ["Bills", `${bills.length} · ${esc(monthName(bills[0].to.slice(0, 7), "short"))} to ${esc(monthName(bills.at(-1).to.slice(0, 7), "short"))}`],
      ])}<p class="sub">To add meter data, download it from MyTorontoHydro and upload the file to the data/hydro folder in GitHub. The site rebuilds on its own.</p></section>
      <section><div class="group-label">Security</div>${rows([
        ["Data", state.encrypted ? "Encrypted" : "Not encrypted"],
        state.encrypted && ["Unlock", esc(HomeSolarLock.status())],
      ])}
        ${state.encrypted ? `<button type="button" class="linkline danger" id="lockapp">Lock and forget this device</button><p class="sub">You'll need your passphrase to open the app here again.</p>` : `<p class="sub">Add a SITE_PASSPHRASE secret in GitHub to encrypt everything the site publishes.</p>`}
      </section>
      <section><p class="sub">Weather data by <a href="https://open-meteo.com/">Open-Meteo.com</a>. Sunrise and sunset are calculated for Parkdale. Built ${esc(timeOf(d.generated))}${state.version ? `. Version ${esc(state.version)}` : ""}.</p></section>`;
  }

  // ---------- routing ----------
  const screens = { now: nowScreen, month: monthScreen, history: historyScreen, settings: settingsScreen };
  const OLD = { overview: "month", days: "month", solar: "now", sources: "settings" };
  function route() { const r = location.hash.slice(1) || "now"; return screens[r] ? r : OLD[r] || "now"; }

  let fitting = false;
  function render() {
    const r = route();
    if (OLD[location.hash.slice(1)]) { history.replaceState(null, "", "#" + r); }
    if (r !== "settings") state.lastTab = r;
    view.innerHTML = screens[r]();
    document.querySelectorAll(".tabs a").forEach((a) => { if (a.dataset.tab === r) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current"); });
    if (r === "now" && !fitting) {
      const tabs = document.querySelector(".tabs"), tb = tabs ? tabs.getBoundingClientRect().height : 0;
      const used = view.scrollHeight - parseFloat(getComputedStyle(view).paddingBottom) + tb + 8;
      const next = Math.max(130, Math.min(340, (state.nowH || 200) + innerHeight - used));
      if (Math.abs(next - (state.nowH || 200)) > 4) { state.nowH = next; fitting = true; view.innerHTML = screens.now(); fitting = false; }
    }
    document.title = { now: "Now", month: mName(state.month || "2000-01"), history: "History", settings: "Settings" }[r] + " · Home Solar";
  }

  view.addEventListener("click", (e) => {
    const pop = e.target.closest("[data-pop]");
    if (pop) {
      const box = pop.nextElementSibling, open = box.hidden;
      box.hidden = !open; pop.setAttribute("aria-expanded", String(open));
      return;
    }
    const sh = e.target.closest("[data-sheet]");
    if (sh) {
      if (sh.dataset.sheet === "bill") openSheet(`${mName(state.month)} bill`, billSheet(state.month));
      if (sh.dataset.sheet === "method") openSheet("How costs are worked out", methodSheet());
      return;
    }
    const m = e.target.closest("[data-ym]");
    if (m && !m.disabled) {
      state.month = m.dataset.ym; state.day = null;
      if (m.dataset.go === "month" && route() !== "month") { location.hash = "#month"; return; }
      render(); return;
    }
    if (e.target.closest("[data-back]")) { location.hash = "#" + (state.lastTab || "now"); return; }
    if (e.target.closest("#lockapp")) { HomeSolarLock.forget(); location.reload(); return; }
    const d = e.target.closest("[data-day]");
    if (d) { state.day = d.dataset.day; render(); openSheet(dayName(state.day), daySheet(state.day)); }
  });
  view.addEventListener("toggle", (e) => { if (e.target.matches("details.acc")) state.ledgerOpen = e.target.open; }, true);
  view.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && e.target.matches("[role=button]")) { e.preventDefault(); e.target.dispatchEvent(new MouseEvent("click", { bubbles: true })); }
  });
  window.addEventListener("hashchange", () => { closeSheet(true); render(); view.scrollTo(0, 0); });
  let lastW = innerWidth;
  window.addEventListener("resize", () => { if (state.data && Math.abs(innerWidth - lastW) > 20) { lastW = innerWidth; render(); } });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && state.data) { refreshLive(); render(); } });

  // pull to refresh: the page scrolls inside <main>, so the tab bar never moves with it
  const ptr = document.createElement("div");
  ptr.className = "ptr"; ptr.setAttribute("aria-hidden", "true");
  ptr.innerHTML = '<svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v4h-4"/></svg>';
  document.body.appendChild(ptr);
  let pullY = null, pulled = 0, refreshing = false;
  const PULL = 70;
  view.addEventListener("touchstart", (e) => { pullY = view.scrollTop <= 0 && !refreshing ? e.touches[0].clientY : null; pulled = 0; }, { passive: true });
  view.addEventListener("touchmove", (e) => {
    if (pullY == null || document.body.classList.contains("locked")) return;
    pulled = Math.max(0, (e.touches[0].clientY - pullY) * 0.5);
    ptr.style.opacity = Math.min(1, pulled / PULL);
    ptr.style.transform = `translateY(${Math.min(pulled, PULL)}px) rotate(${pulled * 4}deg)`;
    ptr.classList.toggle("ready", pulled >= PULL);
  }, { passive: true });
  view.addEventListener("touchend", () => {
    if (pullY == null) return;
    pullY = null;
    if (pulled >= PULL) refresh();
    else { ptr.style.opacity = 0; ptr.style.transform = ""; }
  });
  function refresh() {
    refreshing = true;
    ptr.classList.add("spin"); ptr.style.opacity = 1; ptr.style.transform = `translateY(${PULL}px)`;
    const finish = () => { refreshing = false; ptr.classList.remove("spin", "ready"); ptr.style.opacity = 0; ptr.style.transform = ""; };
    checkVersion();
    fetch("data.json", { cache: "no-store" })
      .then((r) => { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then((data) => HomeSolarLock.isEncrypted(data) ? HomeSolarLock.reopen(data).catch(() => HomeSolarLock.unlock(view, data)) : data)
      .then((data) => {
        const keep = state.month;
        state.data = data; _range = null; for (const k in _k) delete _k[k];
        state.month = months().includes(keep) ? keep : defaultMonth();
        liveAt = 0; refreshLive(); render();
      })
      .catch(() => {})
      .finally(() => setTimeout(finish, 300));
  }

  // Home Screen apps on iPhone can hold on to an old copy of the page. Each time the app
  // opens or comes back, ask for the latest page and reload if its code version changed.
  const myVer = ((document.querySelector('script[src*="app.js"]') || {}).src || "").match(/v=([\w.]+)/)?.[1] || null;
  state.version = myVer;
  function checkVersion() {
    if (!myVer) return;
    fetch(`./?check=${Date.now()}`, { cache: "no-store" })
      .then((r) => r.text())
      .then((t) => { const v = (t.match(/app\.js\?v=([\w.]+)/) || [])[1]; if (v && v !== myVer) location.replace(`./?v=${v}${location.hash}`); })
      .catch(() => {});
  }
  checkVersion();
  document.addEventListener("visibilitychange", () => { if (!document.hidden) checkVersion(); });

  view.innerHTML = '<p class="loading">Loading…</p>';
  fetch("data.json", { cache: "no-store" })
    .then((r) => { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then((data) => { state.encrypted = HomeSolarLock.isEncrypted(data); return state.encrypted ? HomeSolarLock.unlock(view, data) : data; })
    .then((data) => {
      state.data = data; state.month = defaultMonth(); render(); refreshLive();
    })
    .catch(() => { view.innerHTML = '<h1>Home Solar</h1><p class="sub">Couldn\'t load data.json. If you opened index.html straight from your computer, run the build and serve the _site folder instead.</p>'; });
})();
