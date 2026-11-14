(() => {
  "use strict";

  const view = document.getElementById("view");

  // Safari ignores user-scalable=no, so block its pinch gestures directly
  ["gesturestart", "gesturechange", "gestureend"].forEach((t) => document.addEventListener(t, (e) => e.preventDefault(), { passive: false }));
  const state = { data: null, month: null, day: null, lastTab: "now", histView: "cost" };
  try { if (localStorage.getItem("histView") === "energy") state.histView = "energy"; } catch (_) {}

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
  // iPad in landscape (and anything as wide): a sidebar instead of the tab bar, and room for two columns on Now
  const WIDE = matchMedia("(min-width: 1000px)");
  const wide = () => WIDE.matches;
  const NOW_SIDE = 340, NOW_GAP = 44;
  // iPhone turned sideways: Now and Month split into two columns (Settings can turn this off)
  const LAND = matchMedia("(orientation: landscape) and (max-height: 500px)");
  const land = () => LAND.matches && !wide() && lsGet("landscape") !== false;
  let landCol = false;  // true while drawing the chart that sits in the right-hand column
  const LAND_LEFT = 280, LAND_GAP = 30;
  const contentWidth = () => {
    if (land()) {
      const cs = getComputedStyle(view), inner = view.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
      return Math.round(landCol ? inner - LAND_LEFT - LAND_GAP : route() === "history" ? inner : Math.min(620, inner));
    }
    if (!wide()) return Math.max(280, Math.min(560, document.documentElement.clientWidth || innerWidth) - 40);
    const cs = getComputedStyle(view), inner = view.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
    return Math.round(document.body.classList.contains("r-now") ? inner - NOW_SIDE - NOW_GAP : Math.min(720, inner));
  };

  // ---------- data ----------
  const hydro = () => state.data.hydro || {};
  const solar = () => (state.data.solar && state.data.solar.daily && Object.keys(state.data.solar.daily).length) ? state.data.solar : null;
  const needsConnect = () => !!(state.data.solar && state.data.solar.needsConnect);
  // on iPhone the SolarEdge app can grab the sign-in link and never send you back; a link pasted
  // into Safari's address bar always opens as a web page, so offer a copy of it too
  const connectBtn = () => state.data.connectUrl ? `<a class="btn" href="${esc(state.data.connectUrl)}" target="_blank" rel="noopener">Connect SolarEdge</a><button type="button" class="linkline copylink" data-copy="${esc(state.data.connectUrl)}">Copy the sign-in link instead</button>` : "";
  const M = () => (state.data.money && state.data.money.months) || {};

  let _range = null;
  function solarRange() {
    if (!_range) { const k = Object.keys(solar().daily).sort(); _range = [k[0], k.at(-1)]; }
    return _range;
  }

  function months() {
    const s = new Set(Object.keys(hydro()).map((d) => d.slice(0, 7)));
    if (solar()) Object.keys(solar().daily || {}).forEach((d) => s.add(d.slice(0, 7)));
    Object.entries(M()).forEach(([m, x]) => { if (!x.preSolar) s.add(m); });
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
  // weather glyphs drawn like the tab icons: thin grey strokes, with only the sun in orange.
  // Each moves a little (style.css): the sun glows, clouds drift, mist thins, rain and snow fall, stars twinkle.
  // "moon" is the clear-night icon, now just stars
  const WXI = {
    sun: '<circle class="wa glow" cx="12" cy="12" r="8"/><circle class="sunc" cx="12" cy="12" r="5.6"/>',
    moon: '<path class="wa st d0" d="M9.5 6.60Q9.91 9.59 12.90 10Q9.91 10.41 9.5 13.40Q9.09 10.41 6.10 10Q9.09 9.59 9.5 6.60Z"/><path class="wa st d1" d="M17.5 4.50Q17.74 6.26 19.50 6.5Q17.74 6.74 17.5 8.50Q17.26 6.74 15.50 6.5Q17.26 6.26 17.5 4.50Z"/><path class="wa st d2" d="M16 14.60Q16.29 16.71 18.40 17Q16.29 17.29 16 19.40Q15.71 17.29 13.60 17Q15.71 16.71 16 14.60Z"/>',
    partly: '<defs><mask id="wxm@" maskUnits="userSpaceOnUse" x="-4" y="-4" width="32" height="32"><rect x="-4" y="-4" width="32" height="32" fill="#fff"/><g transform="translate(2.2 2.4)"><path class="wa dr" d="M7 19h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 12.1 3.5 3.5 0 0 0 7 19z" fill="#000" stroke="#000" stroke-width="4"/></g></mask></defs><g mask="url(#wxm@)"><circle class="wa glow" cx="9" cy="9" r="6.4"/><circle class="sunc" cx="9" cy="9" r="4.6"/></g><g transform="translate(2.2 2.4)"><path class="wa dr" d="M7 19h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 12.1 3.5 3.5 0 0 0 7 19z"/></g>',
    cloud: '<path class="wa dr slow" d="M7 19h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 12.1 3.5 3.5 0 0 0 7 19z"/>',
    rain: '<path d="M7 15h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 8.1 3.5 3.5 0 0 0 7 15z"/><path class="wa rn d0" d="M8.5 18l-1 2.5"/><path class="wa rn d1" d="M12.5 18l-1 2.5"/><path class="wa rn d2" d="M16.5 18l-1 2.5"/>',
    drizzle: '<path d="M7 15h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 8.1 3.5 3.5 0 0 0 7 15z"/><path class="wa dz d0" d="M8.5 18.5v.5"/><path class="wa dz d1" d="M12.5 18.5v.5"/><path class="wa dz d2" d="M16.5 18.5v.5"/><path class="wa dz d3" d="M10.5 21v.5"/><path class="wa dz d4" d="M14.5 21v.5"/>',
    snow: '<path d="M7 14h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 7.1 3.5 3.5 0 0 0 7 14z"/><path class="wa sn d0" d="M8.5 18h.01"/><path class="wa sn d1" d="M12.5 18h.01"/><path class="wa sn d2" d="M16.5 18h.01"/><path class="wa sn d3" d="M10.5 21h.01"/><path class="wa sn d4" d="M14.5 21h.01"/>',
    fog: '<defs><filter id="wxf@" x="-20%" y="-60%" width="140%" height="220%"><feGaussianBlur stdDeviation=".6"/></filter></defs><g filter="url(#wxf@)"><rect class="wa bk" x="3" y="6.5" width="15" height="2.6" rx="1.3"/><rect class="wa bk d1" x="6" y="11.2" width="15" height="2.6" rx="1.3"/><rect class="wa bk d2" x="4" y="15.9" width="13" height="2.6" rx="1.3"/></g>',
    storm: '<path d="M7 14h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 7.1 3.5 3.5 0 0 0 7 14z"/><path class="wa bolt" d="M12.5 15l-2 3.5h3l-2 3.5"/>',
  };
  function wxKind(code, isDay) {
    const c = Number(code);
    const k = c <= 1 ? "sun" : c === 2 ? "partly" : c === 3 ? "cloud" : [45, 48].includes(c) ? "fog" : [51, 53, 55, 56, 57].includes(c) ? "drizzle"
      : [71, 73, 75, 77, 85, 86].includes(c) ? "snow" : [95, 96, 99].includes(c) ? "storm" : [61, 63, 65, 66, 67, 80, 81, 82].includes(c) ? "rain" : "cloud";
    return !isDay && k === "sun" ? "moon" : !isDay && k === "partly" ? "cloud" : k;
  }
  let wxN = 0;  // masks and filters need ids of their own in each icon
  const wxIcon = (code, isDay) => { const n = ++wxN; return `<svg class="wxi" viewBox="0 0 24 24" aria-hidden="true">${WXI[wxKind(code, isDay)].replace(/@/g, n)}</svg>`; };
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
    const acMax = (state.data.system && state.data.system.inverter && state.data.system.inverter.acKw) || Infinity;
    const ymax = Math.max(1, Math.min(expPeak, acMax), ...pts.map((p) => p[1])) * 1.15;
    const Y = (v) => top + (H - top - bot) * (1 - v / ymax);
    let g = "";
    const step = ymax > 5 ? 2 : 1;
    for (let v = step; v < ymax; v += step) g += `<line x1="0" x2="${W}" y1="${Y(v).toFixed(1)}" y2="${Y(v).toFixed(1)}" class="gridline"/>` + svgText(0, Y(v) - 4, `${v} kW`, "", "start");
    g += `<line x1="0" x2="${W}" y1="${Y(0)}" y2="${Y(0)}" class="axisline"/>`;
    if (expPeak) {
      let p = "";
      for (let i = 0; i <= 48; i++) p += `${i ? "L" : "M"}${X(rise + (set - rise) * i / 48).toFixed(1)},${Y(Math.min(acMax, expPeak * Math.sin(Math.PI * i / 48))).toFixed(1)}`;
      g += `<path d="${p}" class="ghost"/>`;
    }
    const isDay = nowH >= rise && nowH <= set;
    if (!isDay) {
      // tap the moon to show its phase underneath; tap again to hide it
      const m = moonPhase(new Date());
      g += `<g class="moonbtn" data-moon role="button" tabindex="0" aria-expanded="${!!state.moonOpen}" aria-label="Moon: ${esc(m.name)}"><circle cx="${W - 14}" cy="14" r="22" class="hit"/>${moonIcon(new Date(), W - 14, 14, 10)}</g>`;
      if (state.moonOpen) g += svgText(W, 40, m.name, "moonname", "end");
    }
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

  // what the status dot shows: red for a problem with the system itself (SolarEdge alerts, an
  // inverter fault, no output on a clear day), yellow when the app can't get data from SolarEdge
  function systemStatus() {
    const s = state.data.solar;
    if (!s) return null;
    const items = [], when = (iso) => iso ? esc(timeOf(iso)) : "";
    for (const x of (s.alerts || [])) items.push({ level: "bad", title: x.type || "SolarEdge alert",
      note: [x.component, x.impact != null && `impact ${x.impact} of 9`, x.first && `since ${timeOf(x.first)}`].filter(Boolean).map(esc).join(" · ") + ". SolarEdge also opened an issue in your GitHub repo, which emails you." });
    const m = (s.inverter && s.inverter.metrics) || {}, modeName = Object.keys(m).find((k) => /mode|status|state/i.test(k));
    const mode = modeName ? String(m[modeName].latest || "").toUpperCase() : "";
    const d = torontoToday(), sun = sunTimes(d), now = new Date(), wd = weatherDay(d);
    const daylight = now > sun.rise && now < sun.set;
    if (daylight && /FAULT|ERROR|SHUTDOWN|LOCKED/.test(mode)) items.push({ level: "bad", title: "Inverter fault", note: `The inverter reports ${esc(mode.toLowerCase().replace(/_/g, " "))}. Check its light and the SolarEdge app.` });
    const age = s.updated ? Date.now() - Date.parse(s.updated) : 0;
    const fresh = s.todayDate === d && !s.needsConnect && !s.authTroubleSince && age < 75 * 60000;
    if (!s.needsConnect && !s.authTroubleSince && age > 90 * 60000 && age < 36 * 3600000) items.push({ level: "warn", title: `Numbers are ${esc(ago(s.updated).replace(" ago", ""))} old`,
      note: `GitHub hasn't run the hourly update since ${when(s.updated)}, so today's figures stop there. Solar has asked it to run now; fresh numbers usually follow within a few minutes. Your panels are probably fine.` });
    const snowy = wd && ((wd[5] || 0) > 0 || [71, 73, 75, 77, 85, 86].includes(wd[2]));
    if (fresh && daylight && now - sun.rise > 3 * 3600000 && (s.today || 0) < 0.05 && !snowy) items.push({ level: "bad", title: "No production today", note: `Nothing since sunrise at ${clock(sun.rise)}. Check the inverter's light and the SolarEdge app.` });
    let connect = false;
    if (s.needsConnect) { connect = !!state.data.connectUrl; items.push({ level: "warn", title: "SolarEdge needs you to sign in again", note: `The app can't get new numbers until you do. Showing the last ones, from ${when(s.updated)}.` }); }
    else if (s.authTroubleSince) { connect = !!state.data.connectUrl; items.push({ level: "warn", title: "No live data from SolarEdge", note: `SolarEdge has refused to renew the app's access since ${when(s.authTroubleSince)}, so the numbers are from ${when(s.updated)}. Your panels are fine. Signing in again usually fixes it.` }); }
    if (!items.length) items.push(s.alertsChecked ? { level: "ok", title: "System normal", note: `SolarEdge reported no problems when it was checked at ${esc(timeOnly(s.alertsChecked))}.` } : { level: "unknown", title: "Alerts not checked yet", note: "" });
    const level = items.some((x) => x.level === "bad") ? "bad" : items.some((x) => x.level === "warn") ? "warn" : items[0].level;
    return { level, items, connect, label: items.map((x) => x.title).join(", ") };
  }

  // "just now", "12 min ago", "3 hr ago", then the date and time once it's a day old
  function ago(iso) {
    const t = new Date(iso), min = Math.round((Date.now() - t) / 60000);
    if (min < 1) return "just now";
    if (min < 60) return `${min} min ago`;
    if (min < 24 * 60) return `${Math.round(min / 60)} hr ago`;
    return t.toLocaleString("en-US", { month: "long", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: TZNAME }).replace(" at ", ", ").replace(" AM", " am").replace(" PM", " pm");
  }

  // ---------- Now, wide: the cards down the right ----------
  let fc = null, fcAt = 0;  // a week of forecast, with weather codes for the icons
  function loadForecast() {
    if (fc && Date.now() - fcAt < 30 * 60000) return;
    fcAt = Date.now();
    askWeather().then(() => { if (fc && route() === "now" && wide()) render(); });
  }
  function daysCard(t) {
    loadForecast();
    let rws = [];
    if (fc) rws = fc.filter((r) => r.d > torontoToday()).slice(0, 5);
    else if (t) rws = [{ d: t[0], code: t[3], hi: t[1], lo: t[2], kwh: null }];
    if (!rws.length) return "";
    return `<div class="card"><div class="group-label">Coming days</div><div class="fcrows">${rws.map((r) => `
      <div class="fc"><span class="fcd">${esc(parseDay(r.d).toLocaleDateString("en-US", { weekday: "short" }))}</span>${wxIcon(r.code, 1)}
        <span class="fct num">${deg(r.hi).replace("-", "−")} <span class="sub">${deg(r.lo).replace("-", "−")}</span></span><span class="fck num">${r.kwh != null ? `${fmt(r.kwh, r.kwh < 10 ? 1 : 0)}<small> kWh</small>` : ""}</span></div>`).join("")}</div>
      ${fc ? `<p class="sub">Expected solar, from forecast sunlight and what the panels made on similar days.</p>` : ""}</div>`;
  }
  function monthCard(s) {
    const ym = torontoToday().slice(0, 7), n = daysIn(ym), today = Number(torontoToday().slice(8));
    const vals = Array.from({ length: n }, (_, i) => { const d = `${ym}-${String(i + 1).padStart(2, "0")}`; return [d, s.daily[d]]; });
    const mx = Math.max(1, ...vals.map(([, v]) => v || 0)), W = NOW_SIDE - 40, H = 84, bw = W / n;
    let g = "";
    vals.forEach(([d, v], i) => {
      const x = i * bw + 1, w = Math.max(2, bw - 2.5);
      if (i + 1 > today) { g += `<rect x="${x.toFixed(1)}" y="${H - 3}" width="${w.toFixed(1)}" height="3" rx="1.5" class="future"/>`; return; }
      const h = v ? Math.max(3, (H - 6) * v / mx) : 3;
      g += `<rect x="${x.toFixed(1)}" y="${(H - h).toFixed(1)}" width="${w.toFixed(1)}" height="${h.toFixed(1)}" rx="1.5" class="${i + 1 === today ? "today" : "past"}"/>`;
      g += `<rect x="${(i * bw).toFixed(1)}" y="0" width="${bw.toFixed(1)}" height="${H}" class="hit" data-day="${d}" role="button" aria-label="${esc(dayName(d))}${v != null ? `: ${kwh(v)} kWh` : ""}"/>`;
    });
    const m = M()[ym], saved = m && m.saved != null ? m.saved : null;
    return `<div class="card"><div class="group-label">${esc(mName(ym))} so far</div>
      <div class="cardbig num">${kwh(s.month)}<small> kWh</small></div>
      ${saved != null ? `<div class="sub">Saved about ${dollars(saved)}</div>` : ""}
      <svg class="chart mini" width="${W}" height="${H + 16}" viewBox="0 0 ${W} ${H + 16}" role="group" aria-label="Solar each day this month">${g}
        ${svgText(1, H + 14, "1", "", "start")}${svgText(W - 1, H + 14, String(n), "", "end")}</svg></div>`;
  }
  function heatCard() {
    const th = state.data.thermostat && state.data.thermostat.daily;
    if (!th) return "";
    const last = Object.keys(th).sort().at(-1);
    if (!last || Date.parse(torontoToday()) - Date.parse(last) > 3 * 864e5) return "";
    const v = th[last], when = last === torontoToday() ? "today" : "on " + dayName(last);
    const parts = [`The heat pump ran ${fmt(v[0], 1)} hours ${when}`];
    if (v[1] > 0.1) parts.push(`backup heat ${fmt(v[1], 1)}`);
    if (v[2] > 0.1) parts.push(`cooling ${fmt(v[2], 1)}`);
    return `<div class="card"><div class="group-label">Heating</div>
      <p class="lead">${v[5] != null ? `Inside ${deg(v[5])}${v[4] != null ? `, set to ${deg(v[4])}` : ""}. ` : ""}${esc(parts.join(", "))}${v[1] > 0.1 ? "" : ", no backup heat"}.</p></div>`;
  }

  function nowScreen() {
    const today = new Date().toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", timeZone: TZNAME });
    const sys = systemStatus();
    const dot = sys ? `<div class="statuswrap"><button type="button" class="statusdot ${sys.level}" data-pop aria-label="${esc(sys.label)}" aria-expanded="false"><i></i></button>
      <div class="popover status-pop" role="status" hidden>${sys.items.map((x) => `<div class="pi ${x.level}"><i></i><div><b>${esc(x.title)}</b>${x.note ? `<span>${x.note}</span>` : ""}</div></div>`).join("")}${sys.connect ? connectBtn() : ""}</div></div>` : "";
    const cw = currentWeather();
    const wxNow = cw ? `<span class="wxnow">${wxIcon(cw.code, cw.isDay ?? 1)}${deg(cw.temp)} ${esc(wx(cw.code).toLowerCase())}</span>` : "";
    const head = `<div class="top nowhead"><div><div class="eyebrow">${esc(today)}${wxNow}</div><h1>Now</h1></div>
      <div class="topright">${dot}</div></div>`;
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
    // without a working link to SolarEdge there is no live reading; say so rather than show an old one
    const offline = !!(s.needsConnect || s.authTroubleSince);
    const nowNote = offline && nowD > st.rise && nowD < st.set ? "no live reading" : nowKw > 0 ? `of ${fmt(s.peakKw, 2)} kW` : nowD < st.rise ? `sunrise ${clock(st.rise)}` : nowD > st.set ? `sun set at ${clock(st.set)}` : "not producing";
    const nowBig = offline && nowD > st.rise && nowD < st.set ? "–" : fmt(nowKw, nowKw ? 2 : 0);
    const smallDay = todayKwh > 0 && todayKwh < 1;
    const todayBig = offline && !fresh ? "–" : smallDay ? fmt(todayKwh * 1000) : fmt(todayKwh, 1);
    const todayNote = offline ? (fresh ? `as of ${esc(timeOnly(s.updated))}` : "waiting for SolarEdge") : exp ? `${fmt(exp)} kWh expected` : "";

    const t = state.data.weather && state.data.weather.tomorrow;
    const wrows = [];
    if (t) wrows.push([`<span class="wxrow">${wxIcon(t[3], 1)}Tomorrow, ${esc(wx(t[3]).toLowerCase())}</span>`, `H ${deg(t[1])} <span class="sub">L ${deg(t[2])}</span>`]);

    const since = s.installed ? s.installed.slice(0, 4) : "install";
    if (land()) {
      landCol = true; const big = todayChart(s, fresh).svg; landCol = false;
      return `<div class="landgrid"><div class="landl">${head}
        <div class="pair">
          <div><div class="label">Generating now</div><div class="big num ${nowKw > 0 && !offline ? "sun" : "dim"}">${nowBig}<small> kW</small></div><div class="sub">${esc(nowNote)}</div></div>
          <div><div class="label">So far today</div><div class="big num${offline ? " dim" : ""}">${todayBig}<small> ${smallDay && !(offline && !fresh) ? "Wh" : "kWh"}</small></div>${todayNote ? `<div class="sub">${todayNote}</div>` : ""}</div>
        </div>
        ${t ? `<div class="landwx"><span class="wxrow">${wxIcon(t[3], 1)}Tomorrow, ${esc(wx(t[3]).toLowerCase())}</span><span>H ${deg(t[1])} <span class="sub">L ${deg(t[2])}</span></span></div>` : ""}
        <div class="landtotwrap"><div class="label landtotl">Generated by solar, kWh</div><div class="trio ruled num landtot">
          <div><div class="label">This month</div><div class="n">${kwh(s.month)}</div></div>
          <div><div class="label">This year</div><div class="n">${fmt(s.year)}</div></div>
          <div><div class="label">Since ${esc(since)}</div><div class="n">${fmt(s.lifetime)}</div></div>
        </div></div></div>
        <div class="landr">${big}</div></div>`;
    }
    if (wide()) return `${head}<div class="nowgrid"><div class="nowmain">
      <section class="first nowtop">
        <div class="pair">
          <div><div class="label">Generating now</div><div class="big num ${nowKw > 0 && !offline ? "sun" : "dim"}">${nowBig}<small> kW</small></div><div class="sub">${esc(nowNote)}</div></div>
          <div><div class="label">So far today</div><div class="big num${offline ? " dim" : ""}">${todayBig}<small> ${smallDay && !(offline && !fresh) ? "Wh" : "kWh"}</small></div>${todayNote ? `<div class="sub">${todayNote}</div>` : ""}</div>
        </div>
        ${svg}
      </section>
      <section class="nowgen">
        <div class="group-label">Generated by solar</div>
        <div class="trio ruled num">
          <div><div class="label">This month</div><div class="n">${kwh(s.month)}</div><div class="unit">kWh</div></div>
          <div><div class="label">This year</div><div class="n">${fmt(s.year)}</div><div class="unit">kWh</div></div>
          <div><div class="label">Since ${esc(since)}</div><div class="n">${fmt(s.lifetime)}</div><div class="unit">kWh</div></div>
        </div>
      </section></div>
      <aside class="nowside">${daysCard(t)}${monthCard(s)}${heatCard()}</aside></div>`;
    return `${head}
      <section class="first nowtop">
        <div class="pair">
          <div><div class="label">Generating now</div><div class="big num ${nowKw > 0 && !offline ? "sun" : "dim"}">${nowBig}<small> kW</small></div><div class="sub">${esc(nowNote)}</div></div>
          <div><div class="label">So far today</div><div class="big num${offline ? " dim" : ""}">${todayBig}<small> ${smallDay && !(offline && !fresh) ? "Wh" : "kWh"}</small></div>${todayNote ? `<div class="sub">${todayNote}</div>` : ""}</div>
        </div>
        ${svg}
      </section>
      ${wrows.length ? `<section class="nowwx">${rows(wrows)}</section>` : ""}
      <section class="nowgen">
        <div class="group-label">Generated by solar</div>
        <div class="trio ruled num">
          <div><div class="label">This month</div><div class="n">${kwh(s.month)}</div><div class="unit">kWh</div></div>
          <div><div class="label">This year</div><div class="n">${fmt(s.year)}</div><div class="unit">kWh</div></div>
          <div><div class="label">Since ${esc(since)}</div><div class="n">${fmt(s.lifetime)}</div><div class="unit">kWh</div></div>
        </div>
        ${s.updated ? `<p class="sub updated">Updated ${esc(ago(s.updated))}</p>` : ""}
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
    const prev = i > 0 ? all[i - 1] : null, next = i < all.length - 1 ? all[i + 1] : null, latest = defaultMonth();
    return `<div class="top"><div><div class="eyebrow">${state.month.slice(0, 4)}</div><h1>${esc(mName(state.month))}</h1></div>
      <div class="steps"><button type="button" ${prev ? `data-ym="${prev}"` : "disabled"} aria-label="Previous month">‹</button><button type="button" ${next ? `data-ym="${next}"` : "disabled"} aria-label="Next month">›</button>${latest && state.month < latest ? `<button type="button" class="latest" data-ym="${latest}" aria-label="Jump to ${esc(mName(latest))}"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 5l7 7-7 7M18 5v14"/></svg></button>` : ""}</div></div>
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

  // the ecobee's history for the month: how long the heat pump and backup heat ran
  const TH = { heat: 0, aux: 1, cool: 2, fan: 3, set: 4, inside: 5, out: 6, hum: 7 };
  function heatingBlock(ym) {
    const t = state.data.thermostat;
    if (!t || !t.daily) return "";
    const ds = Object.entries(t.daily).filter(([d]) => d.slice(0, 7) === ym);
    if (ds.length < 3) return "";
    const sum = (k) => ds.reduce((a, [, v]) => a + (v[TH[k]] || 0), 0);
    const heat = sum("heat"), aux = sum("aux"), cool = sum("cool");
    const sets = ds.map(([, v]) => v[TH.set]).filter((x) => x != null), setAvg = sets.length ? sets.reduce((a, b) => a + b, 0) / sets.length : null;
    const outOf = (d, v) => v[TH.out] != null ? v[TH.out] : weatherDay(d) ? (weatherDay(d)[0] + weatherDay(d)[1]) / 2 : null;
    const dd = ds.reduce((a, [d, v]) => { const o = outOf(d, v); return a + (o == null ? 0 : Math.max(0, 18 - o)); }, 0);
    const fanAll = ds.filter(([, v]) => v[TH.fan] >= 23.5).length;
    const W = contentWidth(), H = 150, top = 26, bot = 20, right = 44, n = daysIn(ym), pw = W - right, bw = pw / n;
    const most = Math.max(1, ...ds.map(([, v]) => (v[TH.heat] || 0) + (v[TH.aux] || 0)));
    const step = niceStep(most), ymax = Math.ceil(most / step) * step;
    const Y = (v) => top + (H - top - bot) * (1 - v / ymax);
    let g = "";
    for (let v = step; v <= ymax + 1e-9; v += step) g += `<line x1="0" x2="${pw}" y1="${Y(v).toFixed(1)}" y2="${Y(v).toFixed(1)}" class="gridline"/>` + svgText(pw + 6, Y(v) + 4, `${fmt(v)} h`, "", "start");
    const by = Object.fromEntries(ds);
    for (let i = 0; i < n; i++) {
      const d = `${ym}-${String(i + 1).padStart(2, "0")}`, v = by[d];
      if (!v) continue;
      const x = i * bw, hp = v[TH.heat] || 0, ax = v[TH.aux] || 0;
      if (d === state.day) g += `<rect x="${x.toFixed(1)}" y="${top - 6}" width="${bw.toFixed(1)}" height="${H - bot + 8 - top}" rx="3" class="sel"/>` + svgText(Math.min(pw - 40, Math.max(40, x + bw / 2)), 14, `${shortDay(d)}: ${fmt(hp + ax, 1)} h${v[TH.set] != null ? `, set ${fmt(v[TH.set], 1)}°` : ""}`, "strong");
      g += `<rect x="${(x + 1).toFixed(1)}" y="${Y(hp).toFixed(1)}" width="${Math.max(1.5, bw - 2).toFixed(1)}" height="${(Y(0) - Y(hp)).toFixed(1)}" class="b-heat"/>`;
      if (ax > 0) g += `<rect x="${(x + 1).toFixed(1)}" y="${Y(hp + ax).toFixed(1)}" width="${Math.max(1.5, bw - 2).toFixed(1)}" height="${(Y(hp) - Y(hp + ax)).toFixed(1)}" class="b-aux"/>`;
      g += `<rect x="${x.toFixed(1)}" y="0" width="${bw.toFixed(1)}" height="${H}" class="hit" data-day="${d}" role="button" aria-label="${esc(dayName(d))}: heating ${fmt(hp + ax, 1)} hours"/>`;
    }
    [1, 8, 15, 22, 29].filter((d) => d <= n).forEach((d) => { g += svgText((d - 0.5) * bw, H - 4, d); });
    const notes = [];
    if (dd > 15 && heat + aux > 0) notes.push(`About <b>${fmt((heat + aux) / dd, 1)} hours</b> of heating for each degree the day averaged below 18°C.`);
    if (aux > 0.5) notes.push(`<b class="bad">Backup heat ran ${fmt(aux, 1)} hours.</b> It uses two to three times the power of the heat pump for the same warmth.`);
    else if (heat > 5) notes.push("No backup heat this month; the heat pump did it all.");
    if (fanAll >= 3) notes.push(`The fan ran all day on <b>${fanAll} days</b>, which adds a few kWh a day.`);
    if (ds.length < n && ym < torontoToday().slice(0, 7)) notes.push(`Thermostat data for ${ds.length} of ${n} days.`);
    return `<section><div class="group-label">Heating</div>
      <div class="trio ruled num">
        <div><div class="label">Heat pump</div><div class="n">${fmt(heat)}</div><div class="unit">hours</div></div>
        <div><div class="label">Backup heat</div><div class="n${aux > 0.5 ? " bad" : ""}">${fmt(aux, aux && aux < 10 ? 1 : 0)}</div><div class="unit">hours</div></div>
        <div><div class="label">${cool > heat ? "Cooling" : "Set to"}</div><div class="n">${cool > heat ? fmt(cool) : setAvg != null ? fmt(setAvg, 1) : "–"}</div><div class="unit">${cool > heat ? "hours" : "⌀ °C"}</div></div>
      </div>
      <div class="legend" style="margin-top: 14px"><span><i class="lg-heat"></i>Heat pump</span>${aux > 0 ? `<span><i class="lg-aux"></i>Backup heat</span>` : ""}<span class="u">hours a day</span></div>
      <svg class="chart" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="group" aria-label="Heating hours each day">${g}</svg>
      ${notes.map((x) => `<p class="sub">${x}</p>`).join("")}
      <p class="sub">From your ecobee thermostat's history.</p></section>`;
  }

  function dayChart(ym) {
    const days = monthDays(ym);
    const hasHome = days.some((r) => r.home != null), hasImp = days.some((r) => r.imp != null), hasProd = days.some((r) => r.prod != null);
    if (!hasImp && !hasProd) return "";
    const segs = (r) => r.home != null ? [[r.imp, "grid"], [r.self, "sun"]] : r.imp != null ? [[r.imp, "grid"]] : (!hasImp && r.prod != null) ? [[r.prod, "sun"]] : null;
    const val = (r) => { const x = segs(r); return x ? x.reduce((a, [v]) => a + v, 0) : null; };
    const vals = days.map(val).filter((v) => v != null);
    const avg = vals.reduce((a, b) => a + b, 0) / vals.length;
    const W = contentWidth(), H = 214, top = 28, bot = 20, right = 44, n = days.length, pw = W - right, bw = pw / n;
    const step = niceStep(Math.max(...vals)), ymax = Math.ceil(Math.max(...vals) / step) * step || 1;
    const Y = (v) => top + (H - top - bot) * (1 - v / ymax);
    let g = "";
    for (let v = step; v <= ymax + 1e-9; v += step) {
      g += `<line x1="0" x2="${pw}" y1="${Y(v).toFixed(1)}" y2="${Y(v).toFixed(1)}" class="gridline"/>`;
      if (Math.abs(Y(v) - Y(avg)) > 12) g += svgText(pw + 6, Y(v) + 4, fmt(v), "", "start");
    }
    days.forEach((r, i) => {
      const x = i * bw, on = r.d === state.day, s = segs(r);
      if (on) {
        g += `<rect x="${(x).toFixed(1)}" y="${top - 6}" width="${bw.toFixed(1)}" height="${H - bot + 8 - top}" rx="3" class="sel"/>`;
        const v = val(r), cx = Math.min(pw - 40, Math.max(40, x + bw / 2));
        g += svgText(cx, 14, `${shortDay(r.d)}: ${v != null ? kwh(v) + " kWh" : "no data"}`, "strong");
      }
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
    if (land()) {
      landCol = true; const chart = dayChart(state.month); landCol = false;
      return `<div class="landgrid"><div class="landl">${monthHead()}${moneyBlock(state.month)}</div><div class="landr">${chart}</div></div>` + facts(state.month) + heatingBlock(state.month) + ledger(state.month);
    }
    return monthHead() + moneyBlock(state.month) + dayChart(state.month) + facts(state.month) + heatingBlock(state.month) + ledger(state.month);
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
    const th = state.data.thermostat && state.data.thermostat.daily && state.data.thermostat.daily[r.d], t = [];
    if (th) {
      t.push(["Heat pump ran", `${fmt(th[0], 1)} h`]);
      if (th[1] > 0) t.push([`<span class="bad">Backup heat ran</span>`, `<span class="bad">${fmt(th[1], 1)} h</span>`]);
      if (th[2] > 0) t.push(["Cooling ran", `${fmt(th[2], 1)} h`]);
      if (th[4] != null) t.push(["Thermostat set to", `⌀ ${fmt(th[4], 1)}°`]);
      if (th[5] != null) t.push(["Inside", `⌀ ${fmt(th[5], 1)}°${th[7] != null ? ` <span class="sub">${fmt(th[7])}% humidity</span>` : ""}`]);
    }
    return rows(p) + `<div class="gap"></div>` + rows(w) + (t.length ? `<div class="gap"></div>` + rows(t) : "");
  }

  // a month from before the panels: just the bill (or bills) that ended in it
  function preSolarSheet(ym) {
    const bs = (state.data.bills || []).filter((b) => b.preSolar && b.to.slice(0, 7) === ym);
    const short = (d) => parseDay(d).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
    return bs.map((b) => {
      const days = Math.round((parseDay(b.to) - parseDay(b.from)) / 864e5);
      return `<p class="sub">${esc(short(b.from))} to ${esc(short(b.to))} · ${days} days</p>` + rows([
        ["Electricity used", `${fmt(b.used)} kWh`],
        ["Charges", money(b.electricity)], ["HST", money(b.hst)], b.rebate ? ["Ontario Electricity Rebate", money(-b.rebate)] : null,
        ["This bill", `<b>${money(b.due - (b.previous || 0))}</b>`]]);
    }).join(`<div class="gap"></div>`) + `<p class="sub">Before the panels were switched on, so there's no solar or meter detail for this month.</p>`;
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
    const nDays = Math.round((parseDay(b.to) - parseDay(b.from)) / 86400000);
    const issued = b.statement ? `, issued ${parseDay(b.statement).toLocaleDateString("en-US", { month: "long", day: "numeric" })}` : "";
    return `<p class="period">${shortDay(b.from)} to ${shortDay(b.to)}, ${b.to.slice(0, 4)}</p><p class="sub">${nDays} days${issued} · ${fmt(p.current / p.kwh * 100, 1)}¢ per kWh all in · ${b.season} prices</p>${rows(r)}${creditNote}${carried ? `<p class="sub">${carried}</p>` : ""}`;
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
    const yt = yearTotals(), ys = Object.keys(yt).sort().reverse();
    if (!ys.length) return "";
    const W = contentWidth(), rowH = 64, lab = 50, top = 6, H = ys.length * rowH + 18, bw = (W - lab) / 12;
    const vals = ys.flatMap((y) => Array.from({ length: 12 }, (_, i) => { const m = M()[`${y}-${String(i + 1).padStart(2, "0")}`]; return m ? (m.grid || 0) + Math.max(0, m.saved || 0) : 0; }));
    const mx = Math.max(1, ...vals), sc = (v) => (rowH - 16) * v / mx;
    let g = "";
    ys.forEach((y, r) => {
      const base = top + r * rowH + rowH - 10;
      g += svgText(0, base - 18, y, "strong", "start") + svgText(0, base - 2, dollars(yt[y].grid), "", "start") + `<line x1="${lab}" x2="${W}" y1="${base}" y2="${base}" class="axisline"/>`;
      for (let i = 0; i < 12; i++) {
        const ym = `${y}-${String(i + 1).padStart(2, "0")}`, m = M()[ym], x = lab + i * bw + 2, w = Math.max(2, bw - 4);
        if (!m) continue;
        const gh = m.grid != null ? sc(m.grid) : 0, sh = m.saved != null ? sc(Math.max(0, m.saved)) : 0;
        if (ym === state.month) g += `<circle cx="${(x + w / 2).toFixed(1)}" cy="${base + 5}" r="2.2" class="seldot"/>`;
        if (gh) g += `<rect x="${x.toFixed(1)}" y="${(base - gh).toFixed(1)}" width="${w.toFixed(1)}" height="${gh.toFixed(1)}" class="b-grid${m.gridSource === "estimate" ? " est" : ""}"/>`;
        if (sh) g += `<rect x="${x.toFixed(1)}" y="${(base - gh - sh).toFixed(1)}" width="${w.toFixed(1)}" height="${sh.toFixed(1)}" class="b-sun"/>`;
        g += `<rect x="${(x - 2).toFixed(1)}" y="${base - rowH + 10}" width="${bw.toFixed(1)}" height="${rowH}" class="hit" ${m.preSolar ? `data-presolar="${ym}"` : `data-ym="${ym}" data-go="month"`} role="button" aria-label="${esc(monthName(ym))}: paid ${m.grid != null ? dollars(m.grid) : "unknown"}, saved ${m.saved != null ? dollars(m.saved) : "unknown"}"/>`;
      }
    });
    "JFMAMJJASOND".split("").forEach((c, i) => { g += svgText(lab + i * bw + bw / 2, H - 2, c); });
    return `<section><div class="label">Cost each month, from the <b class="ink">grid</b> and saved by <b class="sun">solar</b>. Same scale every year.</div>
      <svg class="chart" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="group" aria-label="Monthly cost by year">${g}</svg>
      <p class="sub">Paler bars are estimates. Tap a month to open it.${Object.values(M()).some((m) => m.preSolar) ? " Months before the panels show the bill only." : ""}</p></section>`;
  }

  // what the panels made each month, one row per year on one scale
  function prodByMonth() {
    const out = {};
    if (solar()) for (const [d, v] of Object.entries(solar().daily)) out[d.slice(0, 7)] = (out[d.slice(0, 7)] || 0) + (v || 0);
    return out;
  }
  function energyChart() {
    const pm = prodByMonth(), ys = [...new Set(Object.keys(pm).map((k) => k.slice(0, 4)))].sort().reverse();
    if (!ys.length) return "";
    const W = contentWidth(), rowH = 64, lab = 50, top = 6, H = ys.length * rowH + 18, bw = (W - lab) / 12;
    const mx = Math.max(1, ...Object.values(pm)), sc = (v) => (rowH - 16) * v / mx, cur = torontoToday().slice(0, 7);
    let g = "";
    ys.forEach((y, r) => {
      const base = top + r * rowH + rowH - 10, tot = Object.entries(pm).filter(([k]) => k.startsWith(y)).reduce((a, [, v]) => a + v, 0);
      g += svgText(0, base - 18, y, "strong", "start") + svgText(0, base - 2, fmt(tot), "", "start") + `<line x1="${lab}" x2="${W}" y1="${base}" y2="${base}" class="axisline"/>`;
      for (let i = 0; i < 12; i++) {
        const ym = `${y}-${String(i + 1).padStart(2, "0")}`, v = pm[ym], x = lab + i * bw + 2, w = Math.max(2, bw - 4);
        if (v == null) continue;
        const h = Math.max(0.5, sc(v));
        g += `<rect x="${x.toFixed(1)}" y="${(base - h).toFixed(1)}" width="${w.toFixed(1)}" height="${h.toFixed(1)}" class="b-sun${ym === cur ? " est" : ""}"/>`;
        g += `<rect x="${(x - 2).toFixed(1)}" y="${base - rowH + 10}" width="${bw.toFixed(1)}" height="${rowH}" class="hit" data-ym="${ym}" data-go="month" role="button" aria-label="${esc(monthName(ym))}: ${fmt(v)} kWh"/>`;
      }
    });
    "JFMAMJJASOND".split("").forEach((c, i) => { g += svgText(lab + i * bw + bw / 2, H - 2, c); });
    return `<section><div class="label">kWh generated each month, with the year's total. Same scale every year.</div>
      <svg class="chart" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="group" aria-label="Solar generation by month and year">${g}</svg>
      <p class="sub">Tap a month to open it.</p></section>`;
  }
  // Ontario's grid is mostly nuclear and hydro: about 30 g of CO2 per kWh
  const CO2_KG = 0.03, EV_KWH_100KM = 25;
  const lifetimeKwh = () => solar() ? (solar().lifetime || Object.values(solar().daily).reduce((a, v) => a + (v || 0), 0)) : 0;
  const co2Line = () => lifetimeKwh() ? `<p class="co2"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 21c-4-3-7-6.5-7-10.5A7 7 0 0 1 12 3a7 7 0 0 1 7 7.5c0 4-3 7.5-7 10.5z"/><path d="M12 21V10M12 14l-3-2.5M12 12l3-2.5"/></svg>Avoided about ${fmt(Math.round(lifetimeKwh() * CO2_KG / 10) * 10)} kg of CO₂ since ${esc(solar().installed ? solar().installed.slice(0, 4) : "install")}</p>` : "";
  function energyView() {
    const total = lifetimeKwh(), since = solar() && solar().installed ? monthName(solar().installed.slice(0, 7)) : "install";
    const km = Math.round(total / EV_KWH_100KM * 100 / 1000) * 1000;
    // how many months of the house's own use that is, from the last twelve full months
    const recent = Object.entries(M()).filter(([, m]) => m.imp != null && m.selfUsed != null && m.complete !== false).slice(-12);
    const perMonth = recent.length ? recent.reduce((a, [, m]) => a + m.imp + m.selfUsed, 0) / recent.length : 0;
    const houseMonths = perMonth ? Math.round(total / perMonth) : null;
    const note = `*At about ${EV_KWH_100KM} kWh per 100 km, what a Taycan uses in mixed driving.${houseMonths ? ` It's also about ${houseMonths} months of what your house uses.` : ""}`;
    return `<section class="first">
        <div class="label">Generated by solar since ${esc(since)}</div>
        <div class="big num sun">${fmt(total)}<small> kWh</small></div>
        ${total ? `<div class="popwrap"><button type="button" class="popbtn evline" data-pop aria-expanded="false"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 15.5v-2.2c0-.8.5-1.5 1.3-1.8L7 10.5l2.4-3.2c.4-.5 1-.8 1.6-.8h4.5c.7 0 1.3.3 1.7.9L19 10.5l1.4.5c.4.2.6.6.6 1v3.5"/><circle cx="7" cy="16" r="2"/><circle cx="17" cy="16" r="2"/><path d="M9 16h6"/></svg><span>Enough to drive an EV about ${fmt(km)} km<span class="ast">*</span></span></button><div class="popover below" role="status" hidden><span>${esc(note)}</span></div></div>` : ""}
      </section>
      ${energyChart()}
      <section>${co2Line()}</section>`;
  }
  const hasClimate = () => !!(state.data.thermostat && state.data.thermostat.daily && Object.keys(state.data.thermostat.daily).length >= 20);
  const histSwitch = () => { const vs = ["cost", "energy", ...(hasClimate() ? ["climate"] : [])];
    return `<div class="seg${vs.length > 2 ? " three" : ""}" role="group" aria-label="Show ${vs.length > 2 ? "cost, energy or climate" : "cost or energy"}">${vs.map((v) => `<button type="button" data-hview="${v}" aria-pressed="${state.histView === v}">${{ cost: "Cost", energy: "Energy", climate: "Climate" }[v]}</button>`).join("")}</div>`; };

  // ---------- Climate: heating and cooling from the ecobee thermostat, against the meter ----------
  // Daily rows are [heat pump h, backup h, cooling h, fan h, heat set °C, indoor °C, outdoor °C, humidity %].
  const climYears = () => [...new Set(Object.keys(state.data.thermostat.daily).map((d) => d.slice(0, 4)))].sort();
  // a calendar year (January to December) for the Climate view, or the last 12 months for the cold-weather page
  function climateData(year) {
    const t = state.data.thermostat.daily, ks = Object.keys(t).sort();
    let from, last;
    if (year) { from = `${year}-01-01`; last = `${year}-12-31`; }
    else { last = ks.at(-1); from = new Date(Date.parse(last + "T12:00:00Z") - 364 * 864e5).toISOString().slice(0, 10); }
    const days = ks.filter((d) => d >= from && d <= last).map((d) => {
      const v = t[d], w = weatherDay(d), h = hydro()[d];
      const out = v[6] != null ? v[6] : w ? (w[0] + w[1]) / 2 : null;
      return { d, heat: v[0] || 0, aux: v[1] || 0, cool: v[2] || 0, fan: v[3] || 0, set: v[4], inside: v[5], out, grid: h ? h[0] : null };
    });
    const hs = state.data.system && state.data.system.heating, auxKw = (hs && hs.backupHeat && hs.backupHeat.kw) || 7.5;
    // what a kWh from the grid cost on average over the same months
    const ms = Object.entries(M()).filter(([k, m]) => k >= from.slice(0, 7) && k <= last.slice(0, 7) && m.grid != null && m.imp);
    const rate = ms.length ? ms.reduce((a, [, m]) => a + m.grid, 0) / ms.reduce((a, [, m]) => a + m.imp, 0) : 0.15;
    return { days, from, last, auxKw, rate };
  }
  function climateView() {
    const ys = climYears(), year = ys.includes(state.climYear) ? state.climYear : ys.at(-1);
    const { days, auxKw, rate } = climateData(year);
    const sum = (k, ds = days) => ds.reduce((a, r) => a + r[k], 0);
    const heat = sum("heat"), aux = sum("aux"), cool = sum("cool");
    const auxCold = days.filter((r) => r.out != null && r.out < -5).reduce((a, r) => a + r.aux, 0);
    const auxDays = days.filter((r) => r.aux > 0.1).length;
    // months, oldest first
    const byM = {};
    days.forEach((r) => { const m = (byM[r.d.slice(0, 7)] ||= { heat: 0, aux: 0, cool: 0, out: [], n: 0 }); m.heat += r.heat; m.aux += r.aux; m.cool += r.cool; m.n++; if (r.out != null) m.out.push(r.out); });
    const mk = Array.from({ length: 12 }, (_, i) => `${year}-${String(i + 1).padStart(2, "0")}`);
    mk.forEach((k) => { byM[k] ||= { heat: 0, aux: 0, cool: 0, out: [], n: 0, empty: true }; });
    // months with no readings yet show last year's same month, faded
    const prev = {};
    if (mk.some((k) => byM[k].empty)) climateData(String(Number(year) - 1)).days.forEach((r) => { const m = (prev[r.d.slice(5, 7)] ||= { heat: 0, aux: 0, cool: 0, out: [] }); m.heat += r.heat; m.aux += r.aux; m.cool += r.cool; if (r.out != null) m.out.push(r.out); });
    mk.forEach((k) => { const p = prev[k.slice(5)]; if (byM[k].empty && p && p.heat + p.aux + p.cool > 0) byM[k].ghost = p; });
    const ghosts = mk.some((k) => byM[k].ghost);
    const W = contentWidth(), H = 210, top = 12, bot = 40, pw = W - 40, bw = pw / Math.max(mk.length, 1);
    const most = Math.max(1, ...mk.map((k) => { const m = byM[k].ghost || byM[k]; return Math.max(m.heat + m.aux, m.cool); }));
    const step = niceStep(most), ymax = Math.ceil(most / step) * step, Y = (v) => top + (H - top - bot) * (1 - v / ymax);
    let g = "";
    for (let v = step; v <= ymax + 1e-9; v += step) g += `<line x1="0" x2="${pw}" y1="${Y(v).toFixed(1)}" y2="${Y(v).toFixed(1)}" class="gridline"/>` + svgText(pw + 6, Y(v) + 4, `${fmt(v)} h`, "", "start");
    mk.forEach((k, i) => {
      const m = byM[k], x = i * bw + 3, w = Math.max(2, bw - 6), cx = x + w / 2;
      const bar = (a, b, cls) => b > a ? `<rect x="${x.toFixed(1)}" y="${Y(b).toFixed(1)}" width="${w.toFixed(1)}" height="${(Y(a) - Y(b)).toFixed(1)}" rx="2" class="${cls}"/>` : "";
      if (m.empty) {
        const p = m.ghost;
        if (p) {
          g += `<g class="lastyr">${p.cool > p.heat + p.aux ? bar(0, p.cool, "b-cool") : bar(0, p.heat, "b-heat") + bar(p.heat, p.heat + p.aux, "b-aux")}</g>`;
          if (p.out.length) g += svgText(cx, H - 6, `${Math.round(p.out.reduce((a, b) => a + b, 0) / p.out.length)}°`.replace("-", "−"), "minor lastyr", "middle");
        }
        g += svgText(cx, H - 22, new Date(2000, i, 1).toLocaleDateString("en-US", { month: "narrow" }), "minor", "middle"); return;
      }
      g += m.cool > m.heat + m.aux ? bar(0, m.cool, "b-cool") : bar(0, m.heat, "b-heat") + bar(m.heat, m.heat + m.aux, "b-aux");
      const o = m.out.length ? m.out.reduce((a, b) => a + b, 0) / m.out.length : null;
      g += svgText(cx, H - 22, new Date(2000, Number(k.slice(5)) - 1, 1).toLocaleDateString("en-US", { month: "narrow" }), "", "middle");
      if (o != null) g += svgText(cx, H - 6, `${Math.round(o)}°`.replace("-", "−"), "minor", "middle");
      g += `<rect x="${(i * bw).toFixed(1)}" y="0" width="${bw.toFixed(1)}" height="${H}" class="hit" data-ym="${k}" data-go="month" role="button" aria-label="${esc(monthName(k))}: heating ${fmt(m.heat + m.aux)} hours, cooling ${fmt(m.cool)} hours"/>`;
    });
    g += svgText(pw + 6, H - 6, "⌀", "", "start");
    g += `<line x1="0" x2="${pw}" y1="${Y(0).toFixed(1)}" y2="${Y(0).toFixed(1)}" class="axisline"/>`;
    // the most recent stretch where heat ran flat out and the house still fell behind its setting
    let run = [], worst = null;
    days.forEach((r) => {
      const behind = r.heat >= 23.5 && r.inside != null && r.set != null && r.inside < r.set - 1.5;
      if (behind) run.push(r); else { if (run.length >= 3) worst = run; run = []; }
    });
    if (run.length >= 3) worst = run;
    let callout = "";
    if (worst) {
      const lo = Math.min(...worst.map((r) => r.inside)), hi = Math.max(...worst.map((r) => r.inside)), setv = Math.max(...worst.map((r) => r.set));
      const kwh = worst.every((r) => r.grid != null) ? worst.reduce((a, r) => a + r.grid, 0) : null;
      const span = `${shortDay(worst[0].d)} to ${worst[0].d.slice(0, 7) === worst.at(-1).d.slice(0, 7) ? Number(worst.at(-1).d.slice(8)) : shortDay(worst.at(-1).d)}`;
      callout = `<section class="alerts"><p class="lead"><b class="bad">${esc(span)}: the house couldn't keep up</b></p>
        <p class="sub">The heat ran all day${worst.every((r) => r.aux > 12) ? ", backup heat too," : ""} and the house still sat at ${fmt(lo, 0)} to ${fmt(hi, 0)}°C against a ${fmt(setv, 0)}°C setting.${kwh ? ` Those ${worst.length} days drew about ${fmt(Math.round(kwh / 100) * 100)} kWh from the grid.` : ""} Worth a service call before the next cold snap.</p></section>`;
    }
    // heating per degree of cold: the latest month with real heating against the same month a year before
    const hdd = (ds) => ds.reduce((a, r) => a + (r.out == null ? 0 : Math.max(0, 18 - r.out)), 0);
    const all = Object.keys(state.data.thermostat.daily).sort(), tday = state.data.thermostat.daily;
    const monthStat = (ym) => { const ds = all.filter((d) => d.startsWith(ym)).map((d) => ({ heat: tday[d][0] || 0, aux: tday[d][1] || 0, set: tday[d][4], out: tday[d][6] != null ? tday[d][6] : weatherDay(d) ? (weatherDay(d)[0] + weatherDay(d)[1]) / 2 : null }));
      const dd = hdd(ds); if (ds.length < 20 || dd < 60) return null;
      const sets = ds.map((r) => r.set).filter((x) => x != null);
      return { ym, per: ds.reduce((a, r) => a + r.heat + r.aux, 0) / dd, set: sets.length ? sets.reduce((a, b) => a + b, 0) / sets.length : null }; };
    let cmp = "";
    for (const ym of [...new Set(all.map((d) => d.slice(0, 7)))].reverse()) {
      const a = monthStat(ym), prevYm = `${Number(ym.slice(0, 4)) - 1}${ym.slice(4)}`, b = a && monthStat(prevYm);
      if (a && b) {
        const ch = Math.round((a.per / b.per - 1) * 100), sd = a.set != null && b.set != null ? a.set - b.set : 0;
        const why = Math.abs(sd) >= 1 ? (sd > 0 && ch > 0 ? ", much of it from the warmer setting" : sd < 0 && ch < 0 ? ", much of it from the cooler setting" : "") : "";
        cmp = `<section><div class="group-label">Heating per degree of cold</div>${rows([
          [esc(monthName(b.ym)), `${fmt(b.per, 2)} h${b.set != null ? ` <span class="sub">set to ⌀ ${fmt(b.set, 0)}°</span>` : ""}`],
          [esc(monthName(a.ym)), `${fmt(a.per, 2)} h${a.set != null ? ` <span class="sub">set to ⌀ ${fmt(a.set, 0)}°</span>` : ""}`]])}
          <p class="sub">Hours of heating for each degree a day averaged below 18°C. ${Math.abs(ch) < 5 ? "About the same as a year before." : `About ${Math.abs(ch)}% ${ch > 0 ? "more" : "less"} heating for the same cold${why}.`}</p></section>`;
        break;
      }
    }
    return `<section class="first">
        <div class="climhead"><div class="group-label">Heating and cooling, ${year}${days.length && days.at(-1).d < `${year}-12-31` && year === ys.at(-1) ? " so far" : ""}</div>
          <div class="steps"><button type="button" ${ys.indexOf(year) > 0 ? `data-climyear="${ys[ys.indexOf(year) - 1]}"` : "disabled"} aria-label="Previous year">‹</button><button type="button" ${ys.indexOf(year) < ys.length - 1 ? `data-climyear="${ys[ys.indexOf(year) + 1]}"` : "disabled"} aria-label="Next year">›</button></div></div>
        <div class="trio num">
          <div><div class="label">Heating</div><div class="n heat">${fmt(heat)}</div><div class="unit">hours</div></div>
          <div><div class="label">Backup heat</div><div class="n${aux > 1 ? " bad" : ""}">${fmt(aux)}</div><div class="unit">hours</div></div>
          <div><div class="label">Cooling</div><div class="n cool">${fmt(cool)}</div><div class="unit">hours</div></div>
        </div>
        <p class="lead">${aux > 1 ? `Backup heat cost about <b>${dollars(Math.round(aux * auxKw * rate / 10) * 10)}</b>. It ran on ${auxDays} days${auxCold / aux > 0.5 ? `, and ${pct(auxCold, aux)}% of its hours were on days below −5°C` : ""}.` : "The heat pump did all the heating; backup heat didn't run."}</p>
      </section>
      <section><div class="legend"><span><i class="lg-heat"></i>Heating</span><span><i class="lg-aux"></i>Backup heat</span><span><i class="lg-cool"></i>Cooling</span><span class="u">hours a month</span></div>
        <svg class="chart" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="group" aria-label="Heating and cooling hours by month, tap a month to open it">${g}</svg>
        <p class="sub">Monthly average outdoor temperatures. Tap a month to open it.${ghosts ? ` Faded bars are the same months in ${Number(year) - 1}, until this year's readings come in.` : ""}</p></section>
      ${callout}${cmp}
      <section><button type="button" class="linkline big" data-cold><span>How the house handles cold</span>${chev}</button>
        <p class="sub">From your ecobee thermostat's history and your meter readings. Costs are estimates.</p></section>`;
  }

  function coldView() {
    const { days, auxKw, rate } = climateData();
    const bins = {};
    days.filter((r) => r.out != null && r.grid != null).forEach((r) => {
      const b = Math.floor(r.out / 5) * 5, x = (bins[b] ||= { n: 0, grid: 0, aux: 0, heat: 0 });
      x.n++; x.grid += r.grid; x.aux += Math.min(r.grid, r.aux * auxKw); x.heat += r.heat;
    });
    const bk = Object.keys(bins).map(Number).sort((a, b) => a - b).filter((b) => bins[b].n >= 3 && b <= 25);
    if (!bk.length) return `<p class="sub">Not enough days with both thermostat and meter data yet.</p>`;
    const avg = (b, k) => bins[b][k] / bins[b].n;
    const W = contentWidth(), H = 230, top = 18, bot = 40, pw = W - 40, bw = pw / bk.length;
    const most = Math.max(...bk.map((b) => avg(b, "grid"))), step = niceStep(most), ymax = Math.ceil(most / step) * step, Y = (v) => top + (H - top - bot) * (1 - v / ymax);
    let g = "";
    for (let v = step; v <= ymax + 1e-9; v += step) g += `<line x1="0" x2="${pw}" y1="${Y(v).toFixed(1)}" y2="${Y(v).toFixed(1)}" class="gridline"/>` + svgText(pw + 6, Y(v) + 4, fmt(v), "", "start");
    bk.forEach((b, i) => {
      const gr = avg(b, "grid"), ax = avg(b, "aux"), x = i * bw + 3, w = Math.max(2, bw - 6), cx = x + w / 2;
      g += `<rect x="${x.toFixed(1)}" y="${Y(gr - ax).toFixed(1)}" width="${w.toFixed(1)}" height="${(Y(0) - Y(gr - ax)).toFixed(1)}" rx="2" class="b-gridk"/>`;
      if (ax > 0.5) g += `<rect x="${x.toFixed(1)}" y="${Y(gr).toFixed(1)}" width="${w.toFixed(1)}" height="${(Y(gr - ax) - Y(gr)).toFixed(1)}" rx="2" class="b-aux"/>`;
      g += svgText(cx, Y(gr) - 5, fmt(gr), "strong", "middle") + svgText(cx, H - 22, `${b}°`.replace("-", "−"), "", "middle") + svgText(cx, H - 6, `${bins[b].n} d`, "minor", "middle");
    });
    g += `<line x1="0" x2="${pw}" y1="${Y(0).toFixed(1)}" y2="${Y(0).toFixed(1)}" class="axisline"/>`;
    // where backup heat starts, and where the heat pump runs all day
    // a band counts as needing backup heat when it averages over 3 hours a day of it
    const auxFrom = [...bk].reverse().find((b) => avg(b, "aux") > 3 * auxKw), flat = [...bk].reverse().find((b) => avg(b, "heat") >= 23);
    const deg = (b) => `<b>${String(b + 5).replace("-", "−")}°C</b>`;
    const lead = auxFrom == null ? "The heat pump handled every temperature on its own; backup heat barely ran."
      : flat != null && flat >= auxFrom ? `Down to about ${deg(auxFrom)} the heat pump copes on its own. Below that, it runs all day and backup heat makes up the rest.`
      : `Down to about ${deg(auxFrom)} the heat pump copes on its own. Below that, backup heat starts${flat != null ? `, and below ${deg(flat)} the heat pump runs all day and backup heat does the rest` : ""}.`;
    // what a degree is worth in the coldest months: kWh per degree-day from the meter, at the average price
    const winter = days.filter((r) => r.grid != null && r.out != null && r.out < 10 && ["12", "01", "02"].includes(r.d.slice(5, 7)));
    let degree = null;
    if (winter.length >= 20) {
      const xs = winter.map((r) => 18 - r.out), ys = winter.map((r) => r.grid), mx = xs.reduce((a, b) => a + b, 0) / xs.length, my = ys.reduce((a, b) => a + b, 0) / ys.length;
      const slope = xs.reduce((a, x, i) => a + (x - mx) * (ys[i] - my), 0) / xs.reduce((a, x) => a + (x - mx) ** 2, 0);
      if (slope > 0) degree = slope * 30 * rate;
    }
    const nonstop = days.filter((r) => r.heat >= 23.9).length;
    const mild = days.filter((r) => r.grid != null && r.heat + r.aux + r.cool < 0.5).map((r) => r.grid).sort((a, b) => a - b);
    return `<div class="top"><div><button type="button" class="sback" data-cold-back><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg>Climate</button><h1 class="h1-sm">How the house handles cold</h1></div></div>
      <section class="first"><p class="lead">${lead}</p>
        <div class="legend" style="margin-top: 14px"><span><i class="lg-gridk"></i>Grid</span><span><i class="lg-aux"></i>Of that, backup heat</span><span class="u">⌀ kWh a day</span></div>
        <svg class="chart" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="Average daily grid use at each outdoor temperature">${g}</svg>
        <p class="sub">An average day at each outdoor temperature over the last year. Backup heat's share is estimated at ${fmt(auxKw, 1)} kW.</p></section>
      <section>${rows([
        degree && ["One degree cooler in winter", `about ${dollars(Math.round(degree / 5) * 5)} a month`],
        ["Days the heat pump ran nonstop", fmt(nonstop)],
        mild.length >= 5 && ["A mild day, no heating or cooling", `${fmt(mild[Math.floor(mild.length / 2)])} kWh`],
      ])}</section>`;
  }

  function historyScreen() {
    if (state.histView === "climate" && hasClimate()) {
      if (state.coldView) return coldView();
      return `<div class="top"><div><div class="eyebrow">From your ecobee thermostat</div><h1>History</h1></div></div>${histSwitch()}${climateView()}`;
    }
    if (state.histView === "energy" && solar()) {
      return `<div class="top"><div><div class="eyebrow">Since ${esc(monthName(solar().installed ? solar().installed.slice(0, 7) : Object.keys(solar().daily).sort()[0].slice(0, 7)))}</div><h1>History</h1></div></div>${histSwitch()}${energyView()}`;
    }
    const ms = Object.entries(M()).filter(([, m]) => !m.preSolar);   // totals are for the solar years
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
      ${solar() ? histSwitch() : ""}
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
        <table class="ledger years num"><thead><tr><th></th><th>Paid</th><th>Saved</th><th>Generated, kWh</th></tr></thead><tbody>${trs}</tbody></table>
        <button type="button" class="linkline" data-sheet="method">Months with a bill use the bill. The rest are estimated${typ != null ? `, usually within ${fmt(Math.max(1, Math.ceil(typ * 100)))}% of the real bill` : ""}.${chev}</button>
      </section>
      ${co2Line() ? `<section>${co2Line()}</section>` : ""}`;
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

  // ---------- adding a bill or a meter export from the phone ----------
  // The file is encrypted with this session's key and committed to data/inbox; the next
  // build reads it (a bill into the bill list, a meter export into data/hydro) and drops it.
  const repo = () => {
    const owner = location.hostname.split(".")[0], name = location.pathname.split("/").filter(Boolean)[0];
    return owner && name ? `${owner}/${name}` : null;
  };
  function uploadLog() {
    const u = (state.data.uploads || []).slice(-4).reverse();
    if (!u.length) return "";
    const line = (x) => {
      const what = x.kind === "bill" ? (x.to ? `${monthName(x.to.slice(0, 7))} bill` : "A bill") : x.kind === "meter" ? "Meter file"
        : x.kind === "thermostat" ? `Thermostat, ${x.from ? monthName(x.from.slice(0, 7), "short") : ""}${x.to && x.to.slice(0, 7) !== (x.from || "").slice(0, 7) ? ` to ${monthName(x.to.slice(0, 7), "short")}` : ""}` : x.file ? esc(x.file) : "A file";
      const res = x.result === "added" ? "added" : x.result === "duplicate" ? "already in the app" : `not added${x.note ? `: ${x.note}` : ""}`;
      return [esc(what), `<span class="${x.result === "refused" ? "bad" : "sub"}">${esc(res)}</span>`];
    };
    return rows(u.map(line));
  }
  function uploadBlock() {
    if (!state.encrypted) return `<p class="sub">Adding files from the app needs the data to be encrypted first.</p>`;
    if (!state.data.uploadToken) return `<p class="sub">To add bills and meter files from here, add an UPLOAD_TOKEN secret in GitHub: a fine-grained token with read and write access to this repository's contents only.</p>`;
    return `<label class="btn secondary filebtn"><input type="file" id="addfile" accept=".pdf,.xlsx,.csv,application/pdf" hidden>Add a bill or data file</label>
      <p class="sub" id="upstatus" role="status">A Toronto Hydro bill PDF, a usage spreadsheet from MyTorontoHydro, or your ecobee thermostat's history (the CSV from ecobee.com, Home IQ or Download data). It's encrypted before it leaves your phone.</p>
      ${uploadLog()}`;
  }
  // commits one encrypted file (JSON text) to data/inbox
  async function toInbox(text, kind, message) {
    const stamp = new Date().toISOString().slice(0, 19).replace(/[:]/g, "");
    return commitFile(`data/inbox/${stamp}-${Math.random().toString(36).slice(2, 6)}-${kind}.json`, text, message);
  }
  async function commitFile(path, text, message) {
    // through the Git data API, which takes files of several MB (bill PDFs often are)
    const gh = async (path, method = "GET", data) => {
      const r = await fetch(`https://api.github.com/repos/${repo()}/${path}`, {
        method, cache: "no-store", headers: { Authorization: `Bearer ${state.data.uploadToken}`, Accept: "application/vnd.github+json", ...(data ? { "Content-Type": "application/json" } : {}) },
        body: data ? JSON.stringify(data) : undefined,
      });
      if (!r.ok) throw new Error(r.status === 401 || r.status === 403 || r.status === 404 ? "GitHub refused the upload token." : `GitHub said ${r.status}.`);
      return r.json();
    };
    const blob = await gh("git/blobs", "POST", { content: b64OfText(text), encoding: "base64" });
    for (let attempt = 0; ; attempt++) {
      // GitHub can hand back the old tip for a few seconds after a commit, so wait a little longer each time
      if (attempt) await new Promise((r) => setTimeout(r, 1500 * attempt));
      const head = await gh("git/ref/heads/main");
      const parent = await gh(`git/commits/${head.object.sha}`);
      const tree = await gh("git/trees", "POST", { base_tree: parent.tree.sha, tree: [{ path, mode: "100644", type: "blob", sha: blob.sha }] });
      const commit = await gh("git/commits", "POST", { message, tree: tree.sha, parents: [head.object.sha] });
      try { await gh("git/refs/heads/main", "PATCH", { sha: commit.sha }); break; }
      catch (err) { if (attempt >= 5) throw err; }  // someone else pushed in between: try on top of theirs
    }
  }
  // GitHub often skips its scheduled runs for hours. When the numbers are over 25 minutes old, the app
  // asks for a fresh build itself by touching data/ping.txt (any push rebuilds). At most every 15 minutes per device.
  let nudging = false;
  async function maybeNudge() {
    const s = state.data && state.data.solar, tok = state.data && state.data.uploadToken;
    if (!s || !s.updated || !tok || nudging || document.hidden) return;
    const hr = Number(new Date().toLocaleString("en-US", { timeZone: "America/Toronto", hour: "numeric", hour12: false }));
    if (hr < 6 || hr >= 22 || Date.now() - Date.parse(s.updated) < 25 * 60000) return;
    if (Date.now() - (lsGet("nudgeAt") || 0) < 15 * 60000) return;
    nudging = true; lsSet("nudgeAt", Date.now());
    try { await commitFile("data/ping.txt", new Date().toISOString() + "\n", "Ask for fresh numbers (the hourly run is late)"); } catch (e) { logErr(e); }
    nudging = false;
  }
  const b64OfText = (t) => { const bytes = new TextEncoder().encode(t); let b = ""; for (let i = 0; i < bytes.length; i += 0x8000) b += String.fromCharCode(...bytes.subarray(i, i + 0x8000)); return btoa(b); };
  // ---------- phone alerts ----------
  const ALERT_KINDS = [
    ["production", "Production or inverter problems", "No output on a sunny day, a fault, a SolarEdge alert"],
    ["connection", "No live data", "SolarEdge stops sending numbers for a couple of hours"],
    ["files", "Bills and meter files", "When a file you added is in, or couldn't be read"],
    ["summary", "Monthly summary", "On the 1st: what solar made, what you paid and saved. In winter, how use compared with last year"],
    ["winter", "Winter use", "A day when the house used far more than usual, and how cold it was"],
  ];
  const lsGet = (k) => { try { return JSON.parse(localStorage.getItem(k) || "null"); } catch { return null; } };
  const lsSet = (k, v) => { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, JSON.stringify(v)); } catch {} };
  const pushCapable = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  async function deviceIdOf(endpoint) {
    const h = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(endpoint)));
    return [...h].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 12);
  }
  function alertsBlock() {
    const p = state.data.push, mine = lsGet("alertsDevice");
    const server = p && mine ? (p.devices || []).find((d) => d.id === mine.id) : null;
    let body;
    if (!state.data.uploadToken) body = `<p class="sub">Alerts use the same UPLOAD_TOKEN as adding files. Add it in GitHub to turn them on.</p>`;
    else if (!p || !p.publicKey) body = `<p class="sub">Alerts will be ready after the next update.</p>`;
    else if (!pushCapable()) body = `<p class="sub">On iPhone, alerts work when Solar runs from your Home Screen. In Safari tap Share, then Add to Home Screen, and open Solar from there.</p>`;
    else {
      const prefs = (server && server.prefs) || (mine && mine.prefs) || { production: true, connection: true, files: true, summary: true, winter: true };
      const pending = mine && !server;
      body = ALERT_KINDS.map(([k, t, d]) => `<label class="switchrow"><span><span class="t">${esc(t)}</span><span class="sub">${esc(d)}</span></span><input type="checkbox" class="switch" data-alert="${k}" ${prefs[k] ? "checked" : ""}></label>`).join("")
        + `<button type="button" class="btn${mine ? " secondary" : ""}" id="alertsave">${mine ? "Save" : "Turn on alerts"}</button>
        <p class="sub" id="alertstatus" role="status">${server ? "Alerts are on for this phone." : pending ? "Turning on. You'll get a confirmation alert within the hour." : "Solar checks in about once an hour, so an alert can take that long to arrive."}</p>
        ${mine ? `<button type="button" class="linkline danger" id="alertoff">Turn off alerts on this phone</button>` : ""}`;
    }
    return `<section><div class="group-label">Alerts</div>${body}</section>`;
  }
  async function saveAlerts(off) {
    const st = document.getElementById("alertstatus"), say = (t, bad) => { if (st) { st.textContent = t; st.classList.toggle("bad", !!bad); } };
    try {
      const prefs = {};
      document.querySelectorAll("[data-alert]").forEach((c) => (prefs[c.dataset.alert] = !off && c.checked));
      if (!off && !Object.values(prefs).some(Boolean)) return say("Pick at least one kind of alert.", true);
      if (!off && Notification.permission !== "granted" && (await Notification.requestPermission()) !== "granted")
        return say("Notifications are off for Solar. Turn them on in your phone's Settings, then try again.", true);
      const reg = await navigator.serviceWorker.register("sw.js");
      await navigator.serviceWorker.ready;
      let sub = await reg.pushManager.getSubscription();
      if (!sub && off) { lsSet("alertsDevice", null); render(); return; }
      if (!sub) {
        const k = Uint8Array.from(atob(state.data.push.publicKey.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
        sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: k });
      }
      say("Saving…");
      const box = await HomeSolarLock.seal(new TextEncoder().encode(JSON.stringify({ subscription: sub.toJSON(), prefs })));
      box.kind = "alerts";
      await toInbox(JSON.stringify(box), "alerts", off ? "Turn off alerts on a phone" : "Update alert settings from the app");
      if (off) { await sub.unsubscribe().catch(() => {}); lsSet("alertsDevice", null); }
      else lsSet("alertsDevice", { id: await deviceIdOf(sub.endpoint), prefs });
      render();
      const st2 = document.getElementById("alertstatus");
      if (st2) st2.textContent = off ? "Alerts are off for this phone." : "Saved. You'll get a confirmation alert within the hour.";
    } catch (err) {
      say(err && err.message === "unlock-again" ? "Lock the app and unlock it with your passphrase once, then try again." : (err && err.message) || "That didn't work.", true);
    }
  }

  async function sendFile(file, quiet) {
    const st = document.getElementById("upstatus"), say = (t, bad) => { if (st) { st.textContent = t; st.classList.toggle("bad", !!bad); } };
    const ext = (file.name.split(".").pop() || "").toLowerCase();
    let kind = ext === "pdf" ? "bill" : ext === "xlsx" || ext === "csv" ? "meter" : ext === "zip" ? "zip" : null;
    if (ext === "csv" && (await file.slice(0, 64).text()).replace(/^\uFEFF/, "").startsWith("#,Thermostat")) kind = "ecobee";
    if (!kind) { say(`${file.name} isn't a bill, spreadsheet or zip.`, true); return false; }
    if (file.size > (kind === "zip" ? 40 : 20) * 1024 * 1024) { say(`${file.name} is too big.`, true); return false; }
    try {
      say("Encrypting…");
      const box = await HomeSolarLock.seal(new Uint8Array(await file.arrayBuffer()));
      Object.assign(box, { kind, ext });
      say("Sending…");
      await toInbox(JSON.stringify(box), kind, `Add a ${kind === "bill" ? "bill" : kind === "ecobee" ? "thermostat file" : kind === "zip" ? "zip of files" : "meter file"} from the app`);
      if (!quiet) say(kind === "zip" ? "Sent. Everything in the zip will be in the app in a few minutes." : kind === "bill" ? "Sent. The bill will be in the app in a few minutes." : kind === "ecobee" ? "Sent. The heating history will be in the app in a few minutes." : "Sent. The new readings will be in the app in a few minutes.");
      return true;
    } catch (err) {
      say(err && err.message === "unlock-again" ? "Lock the app and unlock it with your passphrase once, then try again."
        : err && err.message === "locked" ? "Unlock the app first." : (err && err.message) || "That didn't work.", true);
      return false;
    }
  }

  // the equipment as installed: what you'd need for a warranty claim, a service call or a sale
  function systemSection() {
    const y = state.data.system;
    if (!y) return "";
    const pv = y.private || {}, p = y.panels || {}, inv = y.inverter || {};
    const strings = (p.strings || []).length > 1 ? `${p.strings.length} strings, ${p.strings.slice(0, -1).join(", ")} and ${p.strings.at(-1)} panels` : "";
    const r = [
      p.count && ["Panels", `${p.count} × ${esc(p.model)}, ${p.watts} W`],
      strings && ["Wiring", strings],
      inv.dcKw && ["Size", `${fmt(inv.dcKw, 2)} kW of panels, ${fmt(inv.acKw, 0)} kW inverter`],
      y.optimizers && ["Optimizers", `${y.optimizers.count} × ${esc(y.optimizers.model)}, one per panel`],
      ["Inverter", esc(inv.model || "–")],
      pv.inverterSerial && ["Inverter serial", `<span class="num">${esc(pv.inverterSerial)}</span>`],
      y.shutdown && ["Shutdown", esc(y.shutdown.model)],
      pv.switchSerial && ["Switch serial", `<span class="num">${esc(pv.switchSerial)}</span>`],
      y.meter && ["Meter", `${esc(y.meter.model)}${pv.meter ? ` · <span class="num">${esc(pv.meter)}</span>` : ""}`],
      y.installer && ["Installed by", esc(y.installer)],
    ];
    return `<section><div class="group-label">Your system</div>${rows(r)}
      <p class="sub">In an emergency, turn ${esc(y.shutdown ? y.shutdown.where : "the rapid shutdown switch")} to Off. That shuts the panels down to a safe voltage.</p>
      ${inv.dcKw && inv.acKw && inv.dcKw > inv.acKw ? `<p class="sub">The panels can make ${fmt(inv.dcKw, 1)} kW but the inverter tops out at ${fmt(inv.acKw, 0)} kW, so on the brightest days output levels off at about ${fmt(inv.acKw, 0)} kW. That's by design, not a fault.</p>` : ""}</section>`;
  }

  // the heat pump: indoor air handler, outdoor unit (once added), backup heat, thermostat
  function heatingSection() {
    const y = state.data.system, h = y && y.heating;
    if (!h) return "";
    const pv = y.private || {}, ah = h.airHandler || {}, bk = h.backupHeat || {}, ou = h.outdoorUnit;
    const r = [
      ["Type", esc(h.kind)],
      h.size && ["Size", esc(h.size)],
      ["Outdoor unit", ou && ou.model ? esc(ou.model) : `<span class="sub">Not added yet</span>`],
      ou && ou.part && ["Outdoor part number", `<span class="num">${esc(ou.part)}</span>`],
      ou && pv.outdoorUnitSerial && ["Outdoor serial", `<span class="num">${esc(pv.outdoorUnitSerial)}</span>`],
      ou && ou.compressor && ["Compressor", esc(ou.compressor)],
      ou && ou.seer2 && ["Cooling rating", `SEER2 ${esc(ou.seer2)}`],
      ou && ou.hspf2 && ["Heating rating", `HSPF2 ${esc(ou.hspf2)}`],
      ah.model && ["Air handler", esc(ah.model)],
      ah.part && ["Part number", `<span class="num">${esc(ah.part)}</span>`],
      pv.airHandlerSerial && ["Air handler serial", `<span class="num">${esc(pv.airHandlerSerial)}</span>`],
      bk.kw && ["Backup heat", `Electric, ${bk.estimated ? "about " : ""}${fmt(bk.kw, 1)} kW${bk.kit ? ` · ${esc(bk.kit)}` : ""}`],
      ah.refrigerant && ["Refrigerant", esc(ah.refrigerant)],
      ah.power && ["Power", esc(ah.power)],
      h.thermostat && ["Thermostat", esc(h.thermostat)],
    ];
    return `<section><div class="group-label">Heating and cooling</div>${rows(r)}${ou && ou.heatingCapacity ? `<p class="sub">Heat output: ${esc(ou.heatingCapacity)}.</p>` : ""}${bk.note ? `<p class="sub">${esc(bk.note)}</p>` : ""}</section>`;
  }

  // Settings: one short page of rows, each showing its status; tap a row for its details.
  const SET_ICONS = {
    rotate: '<rect x="3" y="7" width="18" height="10" rx="2.5"/><path d="M17.5 7V5.5a2 2 0 0 0-2-2H13M14.5 2l-1.5 1.5L14.5 5"/>',
    solaredge: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6l1.4 1.4M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4L6 18M18 6l1.4-1.4"/>',
    hydro: '<path d="M13 2.5L5 13.5h6l-1 8 8-11h-6z"/>',
    thermostat: '<path d="M14 14.6V5a2 2 0 0 0-4 0v9.6a4 4 0 1 0 4 0z"/><path d="M12 9v7"/>',
    add: '<path d="M12 5v14M5 12h14"/>',
    system: '<rect x="3" y="5" width="18" height="11" rx="1"/><path d="M3 10.5h18M9 5v11M15 5v11M12 16v4M8.5 20h7"/>',
    heating: '<path d="M3 11l9-7 9 7"/><path d="M5 9.5V20h14V9.5"/><path d="M12 17c-1.7 0-2.6-1.2-2.6-2.5 0-1.6 1.6-2.2 2.6-4 1 1.8 2.6 2.4 2.6 4 0 1.3-.9 2.5-2.6 2.5z"/>',
    alerts: '<path d="M6 16v-5a6 6 0 0 1 12 0v5l2 2H4z"/><path d="M10 20a2 2 0 0 0 4 0"/>',
    ask: '<path d="M4 5h16v11H10l-5 4v-4H4z"/>',
    security: '<rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/>',
  };
  const SET_TITLES = { solaredge: "SolarEdge", hydro: "Toronto Hydro", thermostat: "ecobee thermostat", system: "Solar system", heating: "Heating and cooling", alerts: "Alerts", ask: "Sunny", security: "Security" };
  const setIcon = (k) => `<svg class="sicon" viewBox="0 0 24 24" aria-hidden="true">${SET_ICONS[k]}</svg>`;
  const setChev = '<svg class="schev" viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5l7 7-7 7"/></svg>';
  const setRow = (k, value) => `<button type="button" class="srow" data-setpage="${k}">${setIcon(k)}<span class="st">${SET_TITLES[k]}</span><span class="sv">${value}</span>${setChev}</button>`;
  const setGroup = (label, inner, foot) => `<div class="sgroup">${label ? `<div class="slabel">${label}</div>` : ""}<div class="scard">${inner}</div>${foot ? `<p class="sfoot">${foot}</p>` : ""}</div>`;

  function solarRows() {
    const d = state.data, s = d.solar, e = s && s.equipment;
    const ok = s && s.connected && !s.needsConnect && !s.authTroubleSince;
    const sol = [
      ["Status", ok ? `<span class="okc">Connected</span>` : s && s.authTroubleSince ? `<span class="bad">No data since ${esc(timeOf(s.updated))}</span>` : s && s.needsConnect && s.daily ? "Sign-in expired" : "Not connected"],
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
    return { ok, sol };
  }

  // Heating and cooling, in short groups with an icon each; part and serial numbers fold away
  const HEAT_ICONS = {
    pump: '<path d="M3 11l9-7 9 7"/><path d="M5 9.5V20h14V9.5"/><path d="M12 17c-1.7 0-2.6-1.2-2.6-2.5 0-1.6 1.6-2.2 2.6-4 1 1.8 2.6 2.4 2.6 4 0 1.3-.9 2.5-2.6 2.5z"/>',
    outdoor: '<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="10" cy="12" r="4"/><path d="M10 8v8M6 12h8M17 9h1.5M17 12h1.5M17 15h1.5"/>',
    indoor: '<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 7h8M8 10h8M8 17h8"/>',
    backup: '<path d="M7 20c-1-3 1-4.5 1-7.5 0-1.5-1-2.5-1-2.5 3 0 5 3 5 6 1-1 1.5-2.5 1.2-4 2.3 1.5 3.8 4 3.8 6.5 0 .5 0 1-.2 1.5"/><path d="M4 20h16"/>',
    tag: '<path d="M3 12V4h8l10 10-8 8z"/><circle cx="7.5" cy="8.5" r="1.4"/>',
  };
  const heatLabel = (k, t) => `<span class="ilabel"><svg viewBox="0 0 24 24" aria-hidden="true">${HEAT_ICONS[k]}</svg>${t}</span>`;
  function heatingPage() {
    const y = state.data.system || {}, h = y.heating;
    if (!h) return `<p class="sfoot">No heating details yet.</p>`;
    const pv = y.private || {}, ah = h.airHandler || {}, bk = h.backupHeat || {}, ou = h.outdoorUnit || {};
    const card = (inner) => `<div class="scard pad">${inner}</div>`;
    const grp = (k, t, r, foot) => `<div class="sgroup"><div class="slabel">${heatLabel(k, t)}</div>${card(rows(r))}${foot ? `<p class="sfoot">${foot}</p>` : ""}</div>`;
    const short = (m) => esc(String(m || "").replace(/^Bosch\s+/, ""));
    return grp("pump", "Heat pump", [
        ["Make", "Bosch"], h.size && ["Size", esc(h.size)], h.thermostat && ["Thermostat", `ecobee`],
        ah.refrigerant && ["Refrigerant", esc(ah.refrigerant)]])
      + grp("outdoor", "Outdoor unit", [
        ["Make", "Bosch"], ["Model", ou.model ? short(ou.model) : `<span class="sub">Not added yet</span>`],
        ou.part && ["Part number", `<span class="num">${esc(ou.part)}</span>`],
        pv.outdoorUnitSerial && ["Serial", `<span class="num serial">${esc(pv.outdoorUnitSerial)}</span>`],
        ou.compressor && ["Compressor", esc(ou.compressor.replace(/ rotary, /, ", ").replace(/ to /, "–").replace(/ capacity$/, ""))],
        (ou.seer2 || ou.hspf2) && ["Rated", [ou.seer2 && `SEER2 ${esc(ou.seer2.replace(/ to /, "–"))}`, ou.hspf2 && `HSPF2 ${esc(ou.hspf2.replace(/ to /, "–"))}`].filter(Boolean).join(" · ")]],
        ou.heatingCapacity ? esc(ou.heatingCapacity) : "")
      + grp("indoor", "Air handler", [["Make", "Bosch"], ah.model && ["Model", short(ah.model)],
        ah.part && ["Part number", `<span class="num">${esc(ah.part)}</span>`],
        pv.airHandlerSerial && ["Serial", `<span class="num serial">${esc(pv.airHandlerSerial)}</span>`], ah.power && ["Blower", esc(String(ah.power).replace(/^.*?,\s*/, "").replace(/ blower$/, ""))]])
      + grp("backup", "Backup heat", [["Make", "Bosch"], ["Kind", "Electric"], bk.kw && ["Size", `${bk.estimated ? "About " : ""}${fmt(bk.kw, 1)} kW`]],
        bk.note ? esc(bk.note) : "")
      ;
  }

  function settingsPage(k) {
    const d = state.data, s = d.solar, h = Object.keys(hydro()).sort();
    const bills = (d.bills || []).filter((b) => !b.preSolar);
    const span = (a, z) => `${esc(shortDay(a))}, ${a.slice(0, 4)} to ${esc(shortDay(z))}, ${z.slice(0, 4)}`;
    const card = (inner) => `<div class="scard pad">${inner}</div>`;
    let body = "";
    if (k === "solaredge") {
      const { ok, sol } = solarRows();
      body = card(rows(sol) + (ok ? `<p class="sub">Refreshes every hour during the day.${s.error ? " The last refresh failed, so these are the previous numbers." : ""}</p>`
        : connectBtn() + `<p class="sub">${d.connectUrl ? "You'll sign in with SolarEdge, then paste a one-time code into GitHub." : "Add SOLAREDGE_CLIENT_ID, SOLAREDGE_CLIENT_SECRET, SOLAREDGE_SITE_ID and GH_PAT under Settings, Secrets and variables, Actions in your GitHub repository."}</p>`)) + (inverterRows() ? card(inverterRows()) : "");
    } else if (k === "hydro") {
      body = card(rows([
        ["Meter data", h.length ? span(h[0], h.at(-1)) : "None yet"],
        ["Bills", bills.length ? `${bills.length} · ${esc(monthName(bills[0].to.slice(0, 7), "short"))} to ${esc(monthName(bills.at(-1).to.slice(0, 7), "short"))}` : "None yet"],
      ])) + `<p class="sfoot">Meter readings come from the spreadsheets you download from MyTorontoHydro. Add them, and bill PDFs, from Settings.</p>`
        + (uploadLog() ? `<div class="sgroup"><div class="slabel">Files added lately</div>${card(uploadLog())}</div>` : "");
    } else if (k === "thermostat") {
      const t = d.thermostat;
      body = card(rows([["History", t ? span(t.from, t.to) : "None yet"], t && ["Days", fmt(Object.keys(t.daily || {}).length)]]))
        + `<p class="sfoot">From ecobee.com, open Home IQ or your thermostat's Download data and save a month as CSV, then add it from Settings. The heating section in Month uses it.</p>`;
    } else if (k === "system") {
      body = systemSection().replace(/^<section>/, '<div class="scard pad">').replace(/<\/section>$/, "</div>").replace('<div class="group-label">Your system</div>', "");
    } else if (k === "heating") {
      body = heatingPage();
    } else if (k === "alerts") {
      body = alertsBlock().replace(/^\s*<section[^>]*>/, '<div class="scard pad">').replace(/<\/section>\s*$/, "</div>").replace(/<div class="group-label">Alerts<\/div>/, "");
    } else if (k === "ask") {
      const n = loadChats().length;
      body = card(rows([["Powered by", d.askKey ? "Claude Haiku" : "Not set up"], ["Saved conversations", n ? `${fmt(n)} on this phone` : "None"], ["Voice", "Turned into text on this phone"]]))
        + `<p class="sfoot">${d.askKey ? "Each question to Sunny sends Claude a summary of the app's data and the forecast. Conversations stay on this phone." : "Add an ANTHROPIC_API_KEY secret in GitHub to turn Sunny on."}</p>`
        + (n ? card(`<button type="button" class="linkline danger" data-chatclear>Delete all conversations</button>`) : "");
    } else if (k === "security") {
      body = card(rows([["Data", state.encrypted ? "Encrypted" : "Not encrypted"], state.encrypted && ["Unlock", esc(HomeSolarLock.status())]]))
        + (state.encrypted ? card(`<button type="button" class="linkline danger" id="lockapp">Lock and forget this device</button>`) + `<p class="sfoot">You'll need your passphrase to open the app here again.</p>`
          : `<p class="sfoot">Add a SITE_PASSPHRASE secret in GitHub to encrypt everything the site publishes.</p>`);
    }
    return `<div class="top stop"><button type="button" class="sback" data-setback><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg>Settings</button></div>
      <h1 class="sh1">${SET_TITLES[k]}</h1><div class="sbody">${body}</div>`;
  }

  function settingsScreen() {
    if (state.setPage && SET_TITLES[state.setPage]) return settingsPage(state.setPage);
    const d = state.data, s = d.solar, y = d.system || {};
    const ok = s && s.connected && !s.needsConnect && !s.authTroubleSince;
    const bills = (d.bills || []).filter((b) => !b.preSolar);
    const solarV = ok ? `<span class="sdot ok"></span>Connected` : s && s.authTroubleSince ? `<span class="sdot bad"></span>No data` : s && s.needsConnect && s.daily ? `<span class="sdot bad"></span>Sign in again` : "Not connected";
    const t = d.thermostat, mine = lsGet("alertsDevice");
    const alertsOn = mine && mine.prefs ? Object.values(mine.prefs).filter(Boolean).length : 0;
    const panels = y.panels && y.inverter ? `${y.panels.count} panels · ${fmt(y.inverter.dcKw, 1)} kW` : "";
    const addFile = !state.encrypted || !d.uploadToken ? "" : setGroup("", `<label class="srow add">${setIcon("add")}<span class="st">Add a bill or data file</span><input type="file" id="addfile" accept=".pdf,.xlsx,.csv,.zip,application/pdf,application/zip" multiple hidden></label>`,
      `<span id="upstatus" role="status">A Toronto Hydro bill PDF, a MyTorontoHydro spreadsheet or your ecobee thermostat's history, or a zip of any of them. Encrypted before it leaves your phone.</span>`)
      ;
    return `<div class="top"><div><h1>Settings</h1></div></div>
      <div class="sbody">
        ${setGroup("Data sources", setRow("solaredge", solarV) + setRow("hydro", bills.length ? `${bills.length} bills` : "No bills") + setRow("thermostat", t ? `to ${esc(shortDay(t.to))}` : "Not added"))}
        ${addFile}
        ${setGroup("Your home", (y.panels ? setRow("system", panels) : "") + (y.heating ? setRow("heating", "Heat pump") : ""))}
        ${setGroup("Display", `<label class="srow">${setIcon("rotate")}<span class="st">Landscape layout</span><input type="checkbox" class="switch" id="landpref" ${lsGet("landscape") !== false ? "checked" : ""}></label>`,
          "On an iPhone turned sideways, Now and Month split into two columns so everything fits without scrolling. Off keeps the upright layout.")}
        ${setGroup("App", setRow("alerts", alertsOn ? `${alertsOn} on` : "Off") + setRow("ask", d.askKey ? "Claude" : "Not set up") + setRow("security", state.encrypted ? esc(HomeSolarLock.status() === "Passphrase each time" ? "Passphrase" : HomeSolarLock.status() === "Kept unlocked on this device" ? "This device" : HomeSolarLock.status()) : "Not encrypted"))}
        <p class="sfoot center">${state.version ? `Solar ${esc(state.version)} · ` : ""}Built ${esc(timeOf(d.generated))}<br>Weather data by <a href="https://open-meteo.com/">Open-Meteo.com</a>. Sunrise and sunset are calculated for Parkdale.</p>
        ${(() => { const e = recentErr(); return e ? `<p class="sfoot center errnote">Last problem, ${esc(timeOf(e.t))}: ${esc(e.m.split("\n")[0])}</p>` : ""; })()}
      </div>`;
  }

  // ---------- Ask: questions about the house's energy, answered by Claude ----------
  // The API key arrives inside the encrypted data, so only an unlocked app can use it.
  // Each question sends Claude a compact summary of the app's own data; nothing else.
  const ASK_MODEL = "claude-haiku-5-5";
  const ask = { msgs: [], busy: false, draft: "", listening: false, interim: "", speaking: false, fromVoice: false };
  // Conversations are kept on this phone (never in the repository), newest first, up to 60.
  // The one you were in reopens when you come back; New starts another and keeps the old one.
  const CHATS_KEY = "askChats", CHATS_MAX = 60;
  const loadChats = () => { try { const c = JSON.parse(localStorage.getItem(CHATS_KEY) || "[]"); return Array.isArray(c) ? c : []; } catch (_) { return []; } };
  const storeChats = (c) => { try { localStorage.setItem(CHATS_KEY, JSON.stringify(c.slice(0, CHATS_MAX))); } catch (_) {} };
  ask.id = null;
  (function resume() {
    const cur = lsGet("askCurrent"), c = loadChats();
    const hit = cur && c.find((x) => x.id === cur);
    if (hit) { ask.id = hit.id; ask.msgs = hit.msgs; }
    try { sessionStorage.removeItem("askMsgs"); } catch (_) {}
  })();
  function saveAsk() {
    const msgs = ask.msgs.filter((m) => !m.error);
    if (!msgs.length) return;
    const c = loadChats(), now = new Date().toISOString();
    if (!ask.id) { ask.id = now.replace(/\D/g, "").slice(0, 14) + Math.random().toString(36).slice(2, 6); lsSet("askCurrent", ask.id); }
    const i = c.findIndex((x) => x.id === ask.id), prev = i >= 0 ? c.splice(i, 1)[0] : null;
    c.unshift({ id: ask.id, started: prev ? prev.started : now, updated: now, msgs: msgs.slice(-40).map(({ role, text }) => ({ role, text })) });
    storeChats(c);
  }
  function newChat() { ask.msgs = []; ask.id = null; lsSet("askCurrent", ""); if ("speechSynthesis" in window) speechSynthesis.cancel(); ask.speaking = false; }
  function openChat(id) {
    const hit = loadChats().find((x) => x.id === id);
    if (!hit) return;
    newChat(); ask.id = hit.id; ask.msgs = hit.msgs; lsSet("askCurrent", hit.id);
  }
  function deleteChat(id) {
    storeChats(loadChats().filter((x) => x.id !== id));
    if (ask.id === id) newChat();
  }
  const chatTitle = (c) => { const q = (c.msgs.find((m) => m.role === "user") || {}).text || "Conversation"; return q.length > 70 ? q.slice(0, 68).trim() + "…" : q; };
  function chatWhen(iso) {
    const d = new Date(iso), day = d.toLocaleDateString("en-CA", { timeZone: TZNAME }), today = torontoToday();
    const yest = new Date(Date.parse(today + "T12:00:00Z") - 864e5).toISOString().slice(0, 10);
    if (day === today) return `Today, ${clock(d)}`;
    if (day === yest) return `Yesterday, ${clock(d)}`;
    return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: day.slice(0, 4) === today.slice(0, 4) ? undefined : "numeric", timeZone: TZNAME });
  }
  const chatRow = (c) => { const n = c.msgs.filter((m) => m.role === "user").length;
    return `<div class="chatrow"><button type="button" class="chatopen" data-chat="${esc(c.id)}"><span class="t">${esc(chatTitle(c))}</span><span class="w">${esc(chatWhen(c.updated))}${n > 1 ? ` · ${n} questions` : ""}</span></button>
      <button type="button" class="chatdel" data-chatdel="${esc(c.id)}" aria-label="Delete “${esc(chatTitle(c))}”"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 7h14M10 7V5h4v2M7 7l1 13h8l1-13"/></svg></button></div>`; };
  function chatsSheet() {
    const c = loadChats();
    if (!c.length) return `<p class="sub">No saved conversations yet.</p>`;
    return `<div class="chatlist">${c.map(chatRow).join("")}</div>
      <p class="sub">Kept on this phone only, up to ${CHATS_MAX}. Claude also sees your last few questions, so you can pick up where you left off.</p>
      <button type="button" class="linkline danger" data-chatclear>Delete all conversations</button>`;
  }
  // a short memory of earlier conversations, so "like I asked yesterday" makes sense
  function pastChatsNote() {
    const c = loadChats().filter((x) => x.id !== ask.id).slice(0, 6);
    if (!c.length) return "";
    return "Earlier conversations (most recent first):\n" + c.map((x) => {
      const a = (x.msgs.find((m) => m.role === "assistant") || {}).text || "";
      const first = a.replace(/```[\s\S]*?```/g, "").replace(/\*\*/g, "").split(/(?<=[.!?])\s/)[0].slice(0, 220);
      return `- ${chatWhen(x.updated)}: asked "${chatTitle(x)}"; answer began: ${first}`;
    }).join("\n");
  }
  const canRecord = !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.MediaRecorder && (window.AudioContext || window.webkitAudioContext));

  function askContext() {
    const r2 = (x) => (x == null ? null : Math.round(x * 100) / 100);
    const months = {};
    for (const [ym, m] of Object.entries(M())) {
      months[ym] = { paid: r2(m.grid), paidFrom: m.gridSource, savedBySolar: r2(m.saved), costWithoutSolar: r2(m.without),
        gridKwh: r2(m.imp), sentBackKwh: r2(m.exp), solarKwh: r2(m.prod), solarUsedInHouseKwh: r2(m.selfUsed), monthComplete: m.complete };
    }
    const bills = (state.data.bills || []).map((b) => ({ ...(b.preSolar ? { beforeSolar: true } : {}), from: b.from, to: b.to, issued: b.statement,
      usedKwh: b.used, sentBackKwh: b.generated, electricity: b.electricity, hst: b.hst, rebate: b.rebate, amountDue: b.due }));
    const today = torontoToday(), days = [];
    for (let i = 120; i >= 0; i--) {
      const d = new Date(Date.parse(today + "T12:00:00Z") - i * 864e5).toISOString().slice(0, 10);
      const h = state.data.hydro && state.data.hydro[d], w = weatherDay(d), p = solar() && solar().daily[d];
      const th = state.data.thermostat && state.data.thermostat.daily[d];
      if (h || p != null || w || th) days.push([d, h ? r2(h[0]) : null, h ? r2(h[1]) : null, p != null ? r2(p) : null, w ? w[0] : null, w ? w[1] : null,
        ...(th ? [th[0], th[1], th[3], th[4], th[5], th[7]] : [null, null, null, null, null, null])]);
    }
    const s = solar() || {}, y = state.data.system || {};
    return JSON.stringify({
      today, place: "Toronto, Ontario", currency: "CAD",
      system: { panels: y.panels, inverter: y.inverter && y.inverter.model, inverterLimitKw: y.inverter && y.inverter.acKw, installer: y.installer, firstProduction: s.installed,
        heating: y.heating ? { kind: y.heating.kind, size: y.heating.size, airHandler: y.heating.airHandler && y.heating.airHandler.model, outdoorUnit: y.heating.outdoorUnit && y.heating.outdoorUnit.model,
          outdoorUnitDetails: y.heating.outdoorUnit || undefined, backupHeatKw: y.heating.backupHeat && y.heating.backupHeat.kw, backupHeatKwEstimated: y.heating.backupHeat && y.heating.backupHeat.estimated, thermostat: y.heating.thermostat } : undefined },
      live: { generatingNowKw: s.nowKw, todaySoFarKwh: s.today, updated: s.updated, solarThisMonthKwh: s.month, solarThisYearKwh: s.year, solarLifetimeKwh: s.lifetime },
      notes: "Net metered on Toronto Hydro time-of-use. paid is what the household paid for electricity that month (from the bill when paidFrom is 'bill', otherwise estimated from meter readings). savedBySolar is costWithoutSolar minus paid. Meter data arrives in batches, so recent days may be missing. Bills marked beforeSolar are from before the panels were switched on, useful for before and after comparisons. The heating columns come from the ecobee thermostat (a heat pump with electric backup heat) for days where its history was added.",
      months, bills, dailyColumns: ["date", "gridKwh", "sentBackKwh", "solarKwh", "highC", "lowC", "heatPumpHours", "backupHeatHours", "fanHours", "heatSetC", "indoorC", "indoorHumidityPct"], daily: days,
    });
  }
  // Live weather for Ask: conditions now, the next 24 hours, and seven days ahead, with the
  // solar each day should make, from the forecast sunlight and what the roof makes per unit
  // of sunlight on recent days. Fetched when a question is asked, kept for ten minutes.
  let askWx = null, askWxAt = 0;
  const WX_WORDS = { sun: "clear", moon: "clear", partly: "partly cloudy", cloud: "cloudy", fog: "fog", drizzle: "drizzle", rain: "rain", snow: "snow", storm: "thunderstorms" };
  async function askWeather() {
    if (askWx && Date.now() - askWxAt < 10 * 60000) return askWx;
    const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), 5000);
    try {
      const q = new URLSearchParams({ latitude: LAT(), longitude: LON(), timezone: TZNAME, forecast_days: 7,
        current: "temperature_2m,apparent_temperature,weather_code,is_day,cloud_cover,wind_speed_10m,precipitation,snowfall",
        hourly: "temperature_2m,weather_code,cloud_cover,shortwave_radiation,precipitation_probability",
        daily: "temperature_2m_max,temperature_2m_min,weather_code,sunshine_duration,shortwave_radiation_sum,precipitation_probability_max,precipitation_sum,snowfall_sum,sunrise,sunset" });
      const b = await (await fetch(`https://api.open-meteo.com/v1/forecast?${q}`, { signal: ctl.signal })).json();
      const r1 = (x) => (x == null ? null : Math.round(x * 10) / 10), words = (c, day = 1) => WX_WORDS[wxKind(c, day)];
      const c = b.current, h = b.hourly, d = b.daily, k = factorAround(torontoToday());
      const nowIdx = Math.max(0, h.time.findIndex((x) => x >= (c.time || "").slice(0, 13)));
      askWx = {
        source: "Open-Meteo forecast for the house, fetched just now",
        now: { at: c.time, conditions: words(c.weather_code, c.is_day), tempC: c.temperature_2m, feelsLikeC: c.apparent_temperature, cloudPct: c.cloud_cover, windKmh: c.wind_speed_10m, precipMm: c.precipitation, snowCm: c.snowfall },
        next24h: { columns: ["hour", "conditions", "tempC", "cloudPct", "sunlightWm2", "chanceOfPrecipPct"],
          rows: h.time.slice(nowIdx, nowIdx + 24).map((tm, i) => { const j = nowIdx + i; return [tm.slice(11, 16), words(h.weather_code[j]), r1(h.temperature_2m[j]), h.cloud_cover[j], Math.round(h.shortwave_radiation[j]), h.precipitation_probability[j]]; }) },
        days: { columns: ["date", "conditions", "highC", "lowC", "sunshineHours", "chanceOfPrecipPct", "rainMm", "snowCm", "expectedSolarKwh", "sunrise", "sunset"],
          rows: d.time.map((dd, i) => [dd, words(d.weather_code[i]), d.temperature_2m_max[i], d.temperature_2m_min[i], r1(d.sunshine_duration[i] / 3600), d.precipitation_probability_max[i],
            d.precipitation_sum[i], d.snowfall_sum[i], k && d.shortwave_radiation_sum[i] != null ? r1(k * d.shortwave_radiation_sum[i]) : null, d.sunrise[i].slice(11), d.sunset[i].slice(11)]) },
        expectedSolarNote: "expectedSolarKwh is an estimate from forecast sunlight and what the panels made on recent days with similar light. Snow on the panels would lower it.",
      };
      askWxAt = Date.now();
      fc = d.time.map((dd, i) => ({ d: dd, code: d.weather_code[i], hi: d.temperature_2m_max[i], lo: d.temperature_2m_min[i],
        kwh: k && d.shortwave_radiation_sum[i] != null ? k * d.shortwave_radiation_sum[i] : null }));
    } catch (_) { /* answer without it; the context says so */ }
    clearTimeout(t);
    return askWx;
  }

  const ASK_SYSTEM = `You are Sunny, the assistant inside Solar, a private app for one home in Toronto with rooftop solar. Answer the owner's questions using only the data provided. Lead with the answer, with the key figure in bold using **double asterisks**. Write two to four short, plain sentences; no headings, no bullet lists, no em dashes. Money in dollars, energy in kWh, temperatures in °C. The data includes live weather and a seven day forecast with expected solar per day; when you use it, say it's a forecast. If live weather is missing, say you couldn't get it right now. If something is estimated or missing, say so in a few words. If the data can't answer the question, say what's missing. Show, don't just tell: almost every answer with numbers should include a small chart, placed right after the sentence it supports. Use up to two chart blocks, each written exactly like this:
\`\`\`chart
{"type":"bars","unit":"kWh","series":["Grid","Solar"],"rows":[["Sep",1150,540],["Oct",1420,410]]}
\`\`\`
Types: "bars" compares two to eight things (months, years, bills), stacked when there are two series; "columns" shows a run of days, hours or months in order (up to 31); "line" shows a trend over time (up to 31 points); "split" shows how one total divides up, with one row per part (for example where the power came from). Give "unit" as "kWh", "$", "°C", "h" or "%". Use one or two series with plain names (Solar, Grid, Heating, Backup heat, Cooling, Outdoor, Indoor, Cost, Saved), short row labels like "Oct", "Mon", "12th" or "2025", and numbers rounded sensibly. Only chart figures that are in the data. Skip the chart for yes or no answers that have no figures. End with a final line that begins "From " and names the data used, like "From your October bill and meter data".`;

  // Sunny's little charts: bars, columns, a line or a split, drawn in the app's own colours
  function seriesClass(name, i) {
    const n = String(name).toLowerCase();
    if (/backup|aux/.test(n)) return "c-aux";
    if (/heat/.test(n)) return "c-heat";
    if (/cool|ac\b/.test(n)) return "c-cool";
    if (/solar|sun|panel|generat|saved|credit/.test(n)) return "c-sun";
    if (/grid|bill|cost|paid|used|use/.test(n)) return "c-grid";
    if (/indoor|inside/.test(n)) return "c-sun";
    if (/outdoor|outside|temp/.test(n)) return "c-cool";
    return i ? "c-sun" : "c-grid";
  }
  function askChart(c) {
    const type = ["bars", "columns", "line", "split"].includes(c.type) ? c.type : "bars";
    const ser = (c.series || []).slice(0, 2).map(String), cls = ser.map(seriesClass);
    if (cls.length > 1 && cls[0] === cls[1]) cls[1] = cls[0] === "c-sun" ? "c-grid" : "c-sun";
    const unit = String(c.unit || "").slice(0, 4);
    const fmtV = (v) => v == null || isNaN(v) ? "" : unit === "$" ? dollars(v) : `${fmt(v, Math.abs(v) < 10 && v % 1 ? 1 : 0)}${unit === "%" ? "%" : unit === "°C" ? "°" : unit ? " " + unit : ""}`;
    let rows = (c.rows || []).filter((r) => Array.isArray(r) && r.length > 1).map((r) => [String(r[0]).slice(0, 12), Number(r[1]), r[2] == null ? null : Number(r[2])]);
    const key = ser.length > 1 || type === "split" ? `<div class="k">${(type === "split" ? rows.map((r) => r[0]) : ser).map((n, i) => `<span><i class="${type === "split" ? seriesClass(n, i) : cls[i]}"></i>${esc(n)}</span>`).join("")}</div>` : "";
    const label = `${esc(ser.join(" and ") || "Chart")}: ${esc(rows.map((r) => `${r[0]} ${fmtV(r[1])}${r[2] != null ? ", " + fmtV(r[2]) : ""}`).join("; "))}`;
    if (!rows.length) return "";
    if (type === "split") {
      rows = rows.slice(0, 4); const tot = rows.reduce((a, r) => a + Math.max(0, r[1] || 0), 0) || 1;
      return `<div class="askchart share" role="img" aria-label="${label}"><div class="sbar">${rows.map((r, i) => `<span class="${seriesClass(r[0], i)}" style="flex:${Math.max(0, r[1] || 0)} 1 0"></span>`).join("")}</div>
        <div class="svals">${rows.map((r) => `<span><b class="num">${fmtV(r[1])}</b> ${esc(r[0])} <span class="sub">${Math.round(100 * Math.max(0, r[1] || 0) / tot)}%</span></span>`).join("")}</div></div>`;
    }
    if (type === "bars") {
      rows = rows.slice(0, 8);
      const stacked = ser.length > 1, max = Math.max(1e-9, ...rows.map((r) => Math.max(0, r[1] || 0) + (stacked ? Math.max(0, r[2] || 0) : 0)));
      return `<div class="askchart" role="img" aria-label="${label}">${rows.map((r) => {
        const a = Math.max(0, r[1] || 0), b = stacked ? Math.max(0, r[2] || 0) : 0;
        return `<div class="r"><span class="l">${esc(r[0])}</span><span class="bars"><span class="${cls[0]}" style="flex:${a} 1 0"></span>${stacked ? `<span class="${cls[1]}" style="flex:${b} 1 0"></span>` : ""}<span style="flex:${max - a - b} 1 0"></span></span><span class="v num">${fmtV(stacked ? a + b : a)}</span></div>`; }).join("")}${key}</div>`;
    }
    // columns and line: a small SVG
    rows = rows.slice(0, 31);
    const W = Math.min(contentWidth(), 520) - 28, H = 120, top = 16, bot = 20, n = rows.length;
    const vals = rows.flatMap((r) => [r[1], ser.length > 1 ? r[2] : null]).filter((v) => v != null && !isNaN(v));
    let lo = Math.min(0, ...vals), hi = Math.max(...vals); if (hi === lo) hi = lo + 1;
    if (type === "line" && lo < 0 === false && Math.min(...vals) > 0 && unit !== "$" && unit !== "kWh") lo = Math.floor(Math.min(...vals) - (hi - Math.min(...vals)) * .15);
    const Y = (v) => top + (H - top - bot) * (1 - (v - lo) / (hi - lo));
    const fmtN = (v) => unit === "$" ? dollars(v) : fmt(v, Math.abs(v) < 10 && v % 1 ? 1 : 0) + (unit === "%" ? "%" : unit === "°C" ? "°" : "");
    const unitTag = unit && unit !== "$" && unit !== "%" && unit !== "°C" ? `<div class="cu">${esc(unit)}</div>` : "";
    const step = Math.max(1, Math.ceil(n / 7));
    let g = `<line x1="0" x2="${W}" y1="${Y(lo).toFixed(1)}" y2="${Y(lo).toFixed(1)}" class="axis"/>`;
    if (lo < 0) g += `<line x1="0" x2="${W}" y1="${Y(0).toFixed(1)}" y2="${Y(0).toFixed(1)}" class="axis"/>`;
    if (type === "columns") {
      const bw = W / n, w = Math.max(2, Math.min(28, bw * (ser.length > 1 ? .4 : .7)));
      rows.forEach((r, i) => {
        [r[1], ser.length > 1 ? r[2] : null].forEach((v, j) => {
          if (v == null || isNaN(v)) return;
          const x = i * bw + bw / 2 + (ser.length > 1 ? (j ? 1 : -w - 1) : -w / 2), y0 = Y(Math.max(0, lo)), y1 = Y(v);
          g += `<rect x="${x.toFixed(1)}" y="${Math.min(y0, y1).toFixed(1)}" width="${w.toFixed(1)}" height="${Math.max(1.5, Math.abs(y0 - y1)).toFixed(1)}" rx="2" class="${cls[j]}"/>`;
          if (n <= 8 && ser.length < 2) g += svgText(x + w / 2, Math.min(y0, y1) - 4, fmtN(v), "val");
        });
        if ((i % step === 0 && n - 1 - i >= step) || i === n - 1) g += svgText(i * bw + bw / 2, H - 5, r[0], "", "middle");
      });
    } else {
      const X = (i) => n > 1 ? 6 + (W - 12) * i / (n - 1) : W / 2;
      [0, 1].slice(0, Math.max(1, ser.length)).forEach((j) => {
        const pts = rows.map((r, i) => [X(i), r[j + 1]]).filter((p) => p[1] != null && !isNaN(p[1]));
        if (!pts.length) return;
        g += `<path d="M${pts.map((p) => `${p[0].toFixed(1)},${Y(p[1]).toFixed(1)}`).join("L")}" class="ln ${cls[j]}"/>`;
        const last = pts[pts.length - 1];
        g += `<circle cx="${last[0].toFixed(1)}" cy="${Y(last[1]).toFixed(1)}" r="3.5" class="${cls[j]}"/>`;
        if (ser.length < 2) g += svgText(last[0], Y(last[1]) - 8, fmtV(last[1]), "val", "end");
      });
      rows.forEach((r, i) => { if ((i % step === 0 && n - 1 - i >= step) || i === n - 1) g += svgText(X(i), H - 5, r[0], "", i === 0 ? "start" : i === n - 1 ? "end" : "middle"); });
      g += svgText(W, top - 4, fmtV(hi), "", "end");
    }
    return `<div class="askchart svgc" role="img" aria-label="${label}">${type === "columns" ? unitTag : ""}<svg class="chart" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">${g}</svg>${key}</div>`;
  }
  function mdLite(t) { return esc(t).replace(/\*\*(.+?)\*\*/g, "<b>$1</b>"); }
  function askAnswer(text) {
    let source = "";
    const charts = [];
    text = text.replace(/```chart(?![\s\S]*?```)[\s\S]*$/, "");  // a chart cut off mid-way: leave it out
    text = text.replace(/```chart\s*([\s\S]*?)```/g, (_, j) => {
      let h = "";
      try { h = askChart(JSON.parse(j)); } catch (_) {}
      charts.push(h);
      return `\n\n[[chart${charts.length - 1}]]\n\n`;
    });
    const lines = text.trim().split("\n");
    if (/^from /i.test(lines[lines.length - 1].trim())) source = lines.pop().trim();
    const paras = lines.join("\n").split(/\n\s*\n/).map((x) => x.trim()).filter(Boolean)
      .map((x) => { const m = x.match(/^\[\[chart(\d+)\]\]$/); return m ? charts[+m[1]] : `<p>${mdLite(x)}</p>`; }).join("");
    return paras + (source ? `<div class="asksrc">${esc(source)}</div>` : "");
  }

  function askSuggestions() {
    const all = Object.keys(M()).filter((k) => M()[k].complete !== false).sort();
    const out = [];
    const [a, b] = all.slice(-2);
    if (a && b && M()[a].grid != null && M()[b].grid != null) out.push(`Why was ${monthName(b).split(" ")[0]} ${M()[b].grid > M()[a].grid ? "more" : "less"} expensive than ${monthName(a).split(" ")[0]}?`);
    out.push("How much has solar saved this year?");
    out.push(`Is this ${new Date().toLocaleDateString("en-US", { month: "long", timeZone: TZNAME })} colder than last year?`);
    out.push("Will tomorrow be a good day for solar?");
    return out;
  }

  function askScreen() {
    const key = state.data.askKey;
    const mic = canRecord ? `<button type="button" class="askmic${ask.listening ? " on" : ""}" id="askmic" aria-label="${ask.listening ? "Stop and ask" : "Ask out loud"}">${ask.listening ? '<span class="stop"></span>' : '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>'}</button>` : "";
    const bar = key ? `<div class="askdock"><form class="askbar" id="askform">
        <label class="askfield"><span class="vh">Your question</span><input id="askin" type="text" autocomplete="off" enterkeyhint="send" placeholder="${ask.msgs.length ? "Ask Sunny a follow-up" : "Ask Sunny about your energy"}" value="${esc(ask.draft)}"${ask.listening ? " disabled" : ""}></label>
        ${mic}<button type="submit" class="vh">Ask</button>
      </form>${ask.listening ? `<div class="asklisten" role="status"><span class="wave" aria-hidden="true">${"<i></i>".repeat(9)}</span>Listening. Pause or tap to send.</div>` : `<p class="askby">Sunny answers from your app's data, using Claude</p>`}</div><div class="askspacer"></div>` : "";
    const head = `<div class="top"><div><div class="eyebrow">About your home's energy</div><h1>Ask Sunny</h1></div><div class="askhead">${loadChats().length ? `<button type="button" class="textbtn" id="askpast">Past</button>` : ""}${ask.msgs.length ? `<button type="button" class="textbtn" id="asknew">New</button>` : ""}</div></div>`;
    if (!key) return head + `<section class="first"><p>Ask needs a Claude API key. Create one in the Anthropic Console and add it to the repository as a GitHub secret named ANTHROPIC_API_KEY. It's kept inside the encrypted data, so only your unlocked app can use it.</p></section>`;
    if (!ask.msgs.length && !ask.listening) {
      return head + `<section class="first"><p class="asklede">Sunny is Solar's assistant. Ask about what the panels make, what you pay, and why. Sunny answers from the app's own data: every day of production, your meter readings and your bills.</p></section>
        <section><div class="label">Try asking</div>${askSuggestions().map((q) => `<button type="button" class="asksug" data-askq="${esc(q)}"><span>${esc(q)}</span>${chev}</button>`).join("")}</section>
        ${loadChats().length ? `<section><div class="label">Recent</div><div class="chatlist">${loadChats().slice(0, 3).map(chatRow).join("")}</div></section>` : ""}${bar}`;
    }
    const msgs = ask.msgs.map((m, i) => m.role === "user" ? `<div class="askq">${esc(m.text)}</div>`
      : `<div class="aska${m.error ? " err" : ""}">${m.error ? `<p>${esc(m.text)}</p>` : askAnswer(m.text)}${m.spoken && ask.speaking ? `<button type="button" class="askspeak" id="askstop"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M16 9a4 4 0 0 1 0 6"/></svg>Reading aloud</button>` : m.spoken && i === ask.msgs.length - 1 ? `<button type="button" class="askspeak" data-askplay="${i}"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9h4l5-4v14l-5-4H4z"/><path d="M16 9a4 4 0 0 1 0 6"/></svg>Read again</button>` : ""}</div>`).join("");
    const last = ask.msgs[ask.msgs.length - 1];
    const lost = !ask.busy && last && last.role === "user"
      ? `<div class="aska err"><p>No answer came back, probably because Solar was closed while Claude was answering.</p><button type="button" class="askspeak" data-askretry>Ask again</button></div>` : "";
    const pending = lost || (ask.transcribing ? `<div class="askq live" role="status">${esc(ask.voiceStatus || "Listening back")}…</div>` : ask.busy ? `<div class="aska thinking" role="status"><span></span><span></span><span></span></div>` : "");
    return head + `<div class="askmsgs" id="askmsgs">${msgs}${pending}</div>${bar}`;
  }
  function askAfterRender() {
    const box = document.getElementById("askmsgs");
    if (box) view.scrollTop = view.scrollHeight;
    const inp = document.getElementById("askin");
    if (inp) inp.addEventListener("input", () => { ask.draft = inp.value; });
  }

  async function askSend(q, voice) {
    q = (q || "").trim();
    if (!q || ask.busy) return;
    const ae = document.activeElement; if (ae && ae.id === "askin") { ae.value = ""; ae.blur(); }
    ask.msgs.push({ role: "user", text: q }); ask.draft = ""; ask.busy = true; ask.fromVoice = !!voice; saveAsk();
    render();
    try {
      const wx = await askWeather();
      const clean = ask.msgs.filter((m) => !m.error && m.text && m.text.trim())
        .filter((m, i, a) => !(m.role === "user" && a[i + 1] && a[i + 1].role === "user"));   // drop questions that never got an answer
      while (clean.length && clean[0].role !== "user") clean.shift();
      const history = clean.slice(-12).map((m) => ({ role: m.role, content: m.text }));
      const r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "content-type": "application/json", "x-api-key": state.data.askKey, "anthropic-version": "2023-06-01", "anthropic-dangerous-direct-browser-access": "true" },
        body: JSON.stringify({ model: ASK_MODEL, max_tokens: 1400,
          system: [{ type: "text", text: ASK_SYSTEM }, { type: "text", text: "The app's data:\n" + askContext(), cache_control: { type: "ephemeral" } },
            { type: "text", text: "Live weather:\n" + (wx ? JSON.stringify(wx) : "not available right now") + (pastChatsNote() ? "\n\n" + pastChatsNote() : "") }],
          messages: history }),
      });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(r.status === 401 ? "The Claude API key was refused. Check the ANTHROPIC_API_KEY secret." : r.status === 400 && /credit/i.test(JSON.stringify(j)) ? "The Anthropic account is out of credit." : (j.error && j.error.message) || `Claude said ${r.status}.`);
      const text = (j.content || []).filter((c) => c.type === "text").map((c) => c.text).join("\n").trim();
      if (!text) throw new Error("Claude sent back an empty answer. Try asking again.");
      ask.msgs.push({ role: "assistant", text, spoken: !!voice });
      if (voice) askSpeak(text);
    } catch (err) {
      // leaving Solar mid-answer kills the request; say nothing and ask again on return
      if (ask.leftWhileBusy) { ask.cutVoice = !!voice; }
      else ask.msgs.push({ role: "assistant", text: (err && err.message) || "That didn't work. Try again in a moment.", error: true });
    }
    ask.leftWhileBusy = false;
    ask.busy = false; ask.draft = ""; saveAsk(); render();
  }
  // Nathan if he's on the phone (Settings, Accessibility, Spoken Content, Voices), otherwise
  // the best-sounding English voice there is.
  let askVoice = null;
  function pickVoice() {
    if (!("speechSynthesis" in window)) return null;
    const vs = speechSynthesis.getVoices().filter((v) => /^en[-_]/i.test(v.lang));
    if (!vs.length) return null;
    const q = (v) => (/premium/i.test(v.name + v.voiceURI) ? 3 : /enhanced/i.test(v.name + v.voiceURI) ? 2 : 0);
    const score = (v) => (/nathan/i.test(v.name) ? 100 : 0) + q(v) * 10 + (/^(ava|zoe|evan|samantha|joelle|noelle)\b/i.test(v.name) ? 4 : 0)
      + (/en[-_](US|CA)/i.test(v.lang) ? 2 : 0) + (v.localService ? 1 : 0) - (/compact|eloquence|novelty|bad news|bells|bubbles|cellos|whisper|zarvox|organ|trinoids|jester|superstar|wobble|boing|albert|fred|junior|ralph|kathy|grandma|grandpa|rocko|shelley|sandy|flo|reed/i.test(v.name) ? 50 : 0);
    askVoice = vs.sort((a, b) => score(b) - score(a))[0];
    return askVoice;
  }
  if ("speechSynthesis" in window) { pickVoice(); speechSynthesis.addEventListener && speechSynthesis.addEventListener("voiceschanged", pickVoice); }

  function askSpeak(text) {
    if (!("speechSynthesis" in window)) return;
    const plain = text.replace(/```chart[\s\S]*?```/g, "").replace(/\*\*/g, "").split("\n").filter((l) => !/^from /i.test(l.trim())).join(" ");
    const u = new SpeechSynthesisUtterance(plain);
    const v = askVoice || pickVoice();
    if (v) { u.voice = v; u.lang = v.lang; } else u.lang = "en-CA";
    u.rate = 1.0;
    u.onend = u.onerror = () => { ask.speaking = false; if (route() === "ask") render(); };
    setAudioSession("playback");   // after the mic, iPhone can leave sound on the quiet earpiece
    ask.speaking = true;
    if (speechSynthesis.speaking || speechSynthesis.pending) { speechSynthesis.cancel(); setTimeout(() => speechSynthesis.speak(u), 60); }   // iPhone drops a speak() right after cancel()
    else speechSynthesis.speak(u);
  }
  // Voice. iPhone blocks the browser's own speech recognizer in Home Screen apps, so Solar
  // records the question itself and turns it into text on the phone with Whisper (whisper.js).
  // Recording stops after a short pause once you've spoken, or when you tap again.
  let worker = null, workerReady = false, voice = null, jobN = 0;
  const jobs = {};
  function whisper() {
    if (worker) return worker;
    worker = new Worker("whisper.js", { type: "module" });
    worker.onmessage = (e) => {
      const m = e.data;
      if (m.type === "ready") { workerReady = true; return; }
      if (m.type === "progress") {
        if (ask.transcribing && !workerReady) { const pc = Math.min(99, Math.round(100 * m.loaded / m.total)); ask.voiceStatus = `Getting voice ready, first time only, ${pc}%`; render(); }
        return;
      }
      const j = jobs[m.id]; delete jobs[m.id];
      if (j) m.type === "text" ? j.ok(m.text) : j.fail(new Error(m.message));
      else if (m.type === "error") { worker.terminate(); worker = null; workerReady = false; }
    };
    worker.onerror = () => { for (const k in jobs) { jobs[k].fail(new Error("Voice couldn't start.")); delete jobs[k]; } worker = null; workerReady = false; };
    return worker;
  }
  function transcribe(audio) {
    const id = ++jobN;
    return new Promise((ok, fail) => { jobs[id] = { ok, fail }; whisper().postMessage({ type: "transcribe", id, audio }, [audio.buffer]); });
  }
  async function to16k(blob, ctx) {
    const buf = await new Promise((ok, no) => { const p = ctx.decodeAudioData(blob, ok, no); if (p && p.then) p.then(ok, no); });
    const len = Math.max(1, Math.ceil(buf.duration * 16000));
    const off = new (window.OfflineAudioContext || window.webkitOfflineAudioContext)(1, len, 16000);
    const src = off.createBufferSource(); src.buffer = buf; src.connect(off.destination); src.start();
    return (await off.startRendering()).getChannelData(0).slice();
  }
  function voiceFinish(send) {
    const v = voice;
    if (!v || v.done) return;
    v.done = true; voice = null; v.send = send;
    clearInterval(v.tick);
    try { v.rec.state !== "inactive" ? v.rec.stop() : v.after(); } catch (_) { v.after(); }
  }
  function voiceNote(t) { ask.listening = false; ask.transcribing = false; render(); if (t) alertLine(t); }
  function setAudioSession(type) { try { if (navigator.audioSession) navigator.audioSession.type = type; } catch (_) {} }
  // iPhone only lets a page start speaking from a tap. The answer arrives seconds after the
  // tap, so speak a silent word during the tap itself; after that, speech is allowed.
  function unlockSpeech() {
    if (!("speechSynthesis" in window)) return;
    try { const u = new SpeechSynthesisUtterance(" "); u.volume = 0; u.rate = 2; speechSynthesis.speak(u); } catch (_) {}
  }
  async function askListen() {
    if (ask.listening) { voiceFinish(true); return; }   // tapping again sends now
    if (!canRecord || ask.busy || ask.transcribing) return;
    if ("speechSynthesis" in window) speechSynthesis.cancel();
    unlockSpeech();
    setAudioSession("play-and-record");
    ask.speaking = false;
    const ctx = new (window.AudioContext || window.webkitAudioContext)();   // made inside the tap so iPhone allows it
    whisper().postMessage({ type: "load" });                               // fetch the model while you talk
    let stream;
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } }); }
    catch (err) { ctx.close(); return voiceNote(err && err.name === "NotAllowedError" ? "Solar can't use the microphone. Allow it in Settings, Safari, Microphone." : "The microphone isn't available right now."); }
    const rec = new MediaRecorder(stream), chunks = [];
    const v = (voice = { rec, done: false, heard: false, started: Date.now(), quietSince: 0, floor: null });
    rec.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
    v.after = async () => {
      if (v.finished) return; v.finished = true;
      stream.getTracks().forEach((t) => t.stop());
      setAudioSession("playback");
      if (!v.send || !v.heard) { ctx.close(); return voiceNote(v.send && !v.heard ? "Didn't hear anything. Tap the mic and try again." : ""); }
      ask.listening = false; ask.transcribing = true; ask.voiceStatus = workerReady ? "Listening back" : "Getting voice ready, first time only"; render();
      try {
        const blob = await new Blob(chunks, { type: rec.mimeType || "audio/mp4" }).arrayBuffer();
        const pcm = await to16k(blob, ctx); ctx.close();
        const text = await transcribe(pcm);
        ask.transcribing = false;
        if (!text || text.length < 2) return voiceNote("Didn't catch that. Tap the mic and try again.");
        askSend(text, true);
      } catch (err) { try { ctx.close(); } catch (_) {} voiceNote("Voice didn't work that time. Try again, or type the question."); }
    };
    rec.onstop = () => v.after();
    // listen for the end of the question: quiet for 1.4 s after speaking, or 8 s of nothing
    try { if (ctx.state === "suspended") ctx.resume(); } catch (_) {}
    const an = ctx.createAnalyser(); an.fftSize = 1024; ctx.createMediaStreamSource(stream).connect(an);
    const data = new Float32Array(an.fftSize);
    v.tick = setInterval(() => {
      an.getFloatTimeDomainData(data);
      let sum = 0; for (let i = 0; i < data.length; i++) sum += data[i] * data[i];
      const rms = Math.sqrt(sum / data.length), t = Date.now() - v.started;
      if (t < 400) { v.floor = v.floor == null ? rms : Math.min(v.floor, rms); return; }
      const loud = rms > Math.max(0.012, (v.floor || 0) * 3);
      if (loud) { v.heard = true; v.quietSince = 0; } else if (!v.quietSince) v.quietSince = Date.now();
      const bars = document.querySelectorAll(".wave i");
      bars.forEach((b, i) => { b.style.height = `${Math.max(4, Math.min(18, 4 + rms * 300 * (0.6 + ((i * 7) % 5) / 6)))}px`; });
      if (v.heard && v.quietSince && Date.now() - v.quietSince > 1400) voiceFinish(true);
      else if (!v.heard && t > 8000) voiceFinish(true);
      else if (t > 30000) voiceFinish(true);
    }, 80);
    rec.start(250);
    ask.listening = true; render();
  }
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) { if (voice) voiceFinish(false); if (ask.busy) ask.leftWhileBusy = true; }
    else setTimeout(resumeCutOff, 400);
  });
  // a question without an answer (Solar was closed or put away mid-answer): ask it again
  // by itself when you come back, if it was asked in the last 15 minutes
  function resumeCutOff() {
    const last = ask.msgs[ask.msgs.length - 1];
    if (ask.busy || !state.data || !state.data.askKey || !last || last.role !== "user" || document.hidden) return;
    const cur = loadChats().find((c) => c.id === ask.id);
    if (!cur || Date.now() - Date.parse(cur.updated) > 15 * 60000) return;
    ask.msgs.pop();
    askSend(last.text, ask.cutVoice);
    ask.cutVoice = false;
  }
  // start fetching the voice model in the background the first time Ask is opened on Wi-Fi-ish connections
  function warmVoice() { if (canRecord && !worker && !(navigator.connection && navigator.connection.saveData)) setTimeout(() => { if (route() === "ask" && !worker) whisper().postMessage({ type: "load" }); }, 1500); }
  window.addEventListener("hashchange", () => { if (voice && route() !== "ask") voiceFinish(false); });
  document.addEventListener("click", (e) => {
    const o = e.target.closest("[data-chat]"), d = e.target.closest("[data-chatdel]"), all = e.target.closest("[data-chatclear]");
    if (!o && !d && !all) return;
    e.stopPropagation();
    if (o) { openChat(o.dataset.chat); closeSheet(); if (route() !== "ask") location.hash = "#ask"; render(); return; }
    if (d) { const row = d.closest(".chatrow"); deleteChat(d.dataset.chatdel); if (row) row.remove(); }
    if (all) { if (all.dataset.armed) { storeChats([]); newChat(); closeSheet(); } else { all.dataset.armed = "1"; all.textContent = "Tap again to delete all"; return; } }
    if (document.querySelector(".sheet-wrap") && !loadChats().length) closeSheet();
    render();
  }, true);
  function alertLine(t) { const p = document.querySelector(".askby, .asklisten"); if (p) { p.textContent = t; p.classList.add("bad"); } }

  // ---------- routing ----------
  const screens = { now: nowScreen, month: monthScreen, history: historyScreen, ask: askScreen, settings: settingsScreen };
  const OLD = { overview: "month", days: "month", solar: "now", sources: "settings" };
  function route() { const r = location.hash.slice(1) || "now"; return screens[r] ? r : OLD[r] || "now"; }

  let fitting = false;
  // a screen that fails to draw shouldn't leave the app stuck: say so, keep the tabs working, and note it for Settings
  function logErr(err) {
    const m = String((err && (err.stack || err.message)) || err).slice(0, 600);
    try { const l = JSON.parse(localStorage.getItem("errlog") || "[]"); l.push({ t: new Date().toISOString(), m: m.slice(0, 300) }); localStorage.setItem("errlog", JSON.stringify(l.slice(-10))); } catch (e) { /* storage off */ }
    diag("error", m);
  }

  // ---------- diagnostics Claude can read ----------
  // Problems (errors, a tab tap that went nowhere, a tap on the tab bar that something else caught) are
  // kept with the last few things that happened before them, and sent to data/diag/ in the repository
  // at most every 10 minutes. Only app details go in: version, screen, size, what was tapped. No energy
  // numbers, bills or personal data, since the repository is public.
  const crumbs = [];
  function crumb(ev) { crumbs.push(`${new Date().toISOString().slice(11, 19)} ${ev}`); if (crumbs.length > 25) crumbs.shift(); }
  function diagState() {
    const v = window.visualViewport, b = document.body.classList;
    return { v: state.version || "", r: (location.hash || "#").slice(1, 20), w: innerWidth, h: innerHeight,
      vv: v ? [Math.round(v.width), Math.round(v.height), Math.round(v.offsetTop), Math.round(v.scale * 100) / 100] : null,
      sy: Math.round(window.scrollY), body: [...b].filter((c) => !c.startsWith("r-")).join(" "), sheets: document.querySelectorAll(".sheet-wrap").length,
      ios: (navigator.userAgent.match(/OS (\d+_\d+)/) || [])[1] || "", standalone: !!navigator.standalone };
  }
  function diag(kind, msg, extra) {
    try {
      const l = JSON.parse(localStorage.getItem("diag") || "[]");
      l.push({ t: new Date().toISOString(), kind, msg: String(msg || "").slice(0, 600), ...diagState(), ...(extra || {}), crumbs: crumbs.slice(-12) });
      localStorage.setItem("diag", JSON.stringify(l.slice(-30)));
    } catch (e) { /* storage off */ }
    setTimeout(sendDiag, 1500);
  }
  let diagSending = false;
  async function sendDiag() {
    if (diagSending || !(state.data && state.data.uploadToken)) return;
    let l; try { l = JSON.parse(localStorage.getItem("diag") || "[]"); } catch (e) { return; }
    if (!l.length || Date.now() - (lsGet("diagAt") || 0) < 10 * 60000) return;
    diagSending = true; lsSet("diagAt", Date.now());
    try {
      await commitFile(`data/diag/${new Date().toISOString().slice(0, 19).replace(/:/g, "")}-${Math.random().toString(36).slice(2, 6)}.json`, JSON.stringify(l, null, 1) + "\n", "App diagnostics");
      localStorage.setItem("diag", "[]");
    } catch (e) { /* try again later; never log this failure as a new problem */ }
    diagSending = false;
  }
  window.addEventListener("error", (e) => logErr(e.error || e.message));
  window.addEventListener("unhandledrejection", (e) => logErr(e.reason));
  function render() {
    try { renderScreen(); }
    catch (err) {
      logErr(err);
      view.classList.remove("fits");
      view.innerHTML = `<section class="first"><h1>Something went wrong</h1><p class="lead">This screen couldn't be drawn. The other tabs still work, and reopening Solar usually clears it.</p><button type="button" class="btn secondary" onclick="location.reload()">Reload</button></section>`;
    }
  }
  function renderScreen() {
    const r = route();
    crumb(`render ${r} ${innerWidth}x${innerHeight}${land() ? " land" : ""}${wide() ? " wide" : ""}`);
    if (OLD[location.hash.slice(1)]) { history.replaceState(null, "", "#" + r); }
    if (r !== "settings") { state.lastTab = r; state.setPage = null; }
    if (r !== "history") state.coldView = false;
    document.body.classList.toggle("grouped", r === "settings");
    document.body.classList.toggle("wide", wide());
    document.body.classList.toggle("land", land());
    for (const k of Object.keys(screens)) document.body.classList.toggle("r-" + k, k === r);
    view.innerHTML = screens[r]();
    sideFoot();
    document.querySelectorAll(".tabs a").forEach((a) => { if (a.dataset.tab === r) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current"); });
    if (r === "now" && !fitting && land()) {
      const lr = view.querySelector(".landr");
      if (lr) {
        const next = Math.max(120, Math.min(420, view.getBoundingClientRect().bottom - lr.getBoundingClientRect().top - 10));
        if (Math.abs(next - (state.nowH || 200)) > 4) { state.nowH = next; fitting = true; view.innerHTML = screens.now(); fitting = false; }
        // anything still spilling past the bottom (the moon at night, a tall left column) comes off the chart
        const over = view.scrollHeight - view.clientHeight;
        if (over > 1 && state.nowH > 120) { state.nowH = Math.max(120, state.nowH - over - 2); fitting = true; view.innerHTML = screens.now(); fitting = false; }
      }
    } else if (r === "now" && !fitting) {
      const nm = wide() && view.querySelector(".nowmain");
      const used = nm ? nm.getBoundingClientRect().bottom - view.getBoundingClientRect().top + view.scrollTop + parseFloat(getComputedStyle(view).paddingBottom)
        : view.scrollHeight - parseFloat(getComputedStyle(view).paddingBottom) + 8;
      const next = Math.max(130, Math.min(wide() ? 460 : 340, (state.nowH || 200) + view.clientHeight - used));
      if (Math.abs(next - (state.nowH || 200)) > 4) { state.nowH = next; fitting = true; view.innerHTML = screens.now(); fitting = false; }
    }
    document.title = { now: "Now", month: mName(state.month || "2000-01"), history: "History", ask: "Ask Sunny", settings: "Settings" }[r] + " · Solar";
    fitCheck();
    maybeNudge();
    if (r === "ask") { askAfterRender(); warmVoice(); if (!ask.resumed) { ask.resumed = true; setTimeout(resumeCutOff, 300); } }
  }

  // a page that fits on the screen shouldn't scroll or show a scroll bar
  function fitCheck() {
    const last = view.lastElementChild;
    if (!last) return;
    const bottom = last.getBoundingClientRect().bottom - view.getBoundingClientRect().top + view.scrollTop;
    const fits = bottom <= view.clientHeight + 1 && view.scrollHeight <= view.clientHeight + 1;
    view.classList.toggle("fits", fits);
    if (fits) view.scrollTop = 0;
  }
  // typing in Ask: the keyboard covers the tab bar, so the question field sits right on top of the keyboard
  const vv = window.visualViewport;
  const kbFit = () => { const kb = vv ? Math.max(0, innerHeight - vv.height - vv.offsetTop) : 0; document.documentElement.style.setProperty("--kb", kb + "px"); };
  document.addEventListener("focusin", (e) => { if (e.target.id === "askin") { document.body.classList.add("typing"); kbFit(); } });
  document.addEventListener("focusout", (e) => { if (e.target.id === "askin") { document.body.classList.remove("typing"); document.documentElement.style.setProperty("--kb", "0px"); setTimeout(() => window.scrollTo(0, 0), 60); } });
  // iOS can leave the page nudged up after the keyboard or a trip to the background, so taps on the
  // tab bar land in the wrong place; and a half-closed sheet or a stuck "typing" state can sit over it
  function unstick() {
    if (window.scrollY || document.documentElement.scrollTop) window.scrollTo(0, 0);
    const a = document.activeElement;
    if (!(a && a.id === "askin")) { document.body.classList.remove("typing"); document.documentElement.style.setProperty("--kb", "0px"); }
    document.querySelectorAll(".sheet-wrap:not(.open)").forEach((el) => el.remove());
    if (!document.querySelector(".sheet-wrap")) document.body.classList.remove("noscroll");
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden) { unstick(); maybeNudge(); } });
  window.addEventListener("pageshow", unstick);
  if (vv) { vv.addEventListener("resize", () => { if (document.body.classList.contains("typing")) kbFit(); }); vv.addEventListener("scroll", () => { if (document.body.classList.contains("typing")) kbFit(); }); }

  // the sidebar's foot: whether everything is working, and how fresh the numbers are
  function sideFoot() {
    const f = document.getElementById("sidefoot");
    if (!f) return;
    const sys = wide() && state.data && systemStatus(), s = state.data && solar();
    if (!sys) { f.innerHTML = ""; return; }
    const label = sys.level === "ok" ? "All working" : sys.level === "unknown" ? "Not checked yet" : sys.items.find((x) => x.level === sys.level).title;
    f.innerHTML = `<div class="sfst ${sys.level}"><i></i>${esc(label)}</div>${s && s.updated ? `<div class="sfup">Updated ${esc(ago(s.updated))}</div>` : ""}`;
  }
  const recentErr = () => { try { const l = JSON.parse(localStorage.getItem("errlog") || "[]"), e = l[l.length - 1]; return e && Date.now() - Date.parse(e.t) < 7 * 864e5 ? e : null; } catch (x) { return null; } };
  // a tap that lands where the tab bar is drawn but reaches something else means something is covering it
  document.addEventListener("touchend", (e) => {
    const tabs = document.querySelector(".tabs"), c = e.changedTouches[0];
    if (!tabs || !c || document.body.classList.contains("locked") || document.body.classList.contains("typing")) return;
    const r = tabs.getBoundingClientRect();
    if (c.clientY >= r.top && c.clientY <= r.bottom && c.clientX >= r.left && c.clientX <= r.right && !tabs.contains(e.target)) {
      const el = e.target, what = `${el.tagName.toLowerCase()}${el.id ? "#" + el.id : ""}${el.className && typeof el.className === "string" ? "." + el.className.split(" ").join(".") : ""}`;
      diag("tab bar covered", `tap at ${Math.round(c.clientX)},${Math.round(c.clientY)} hit ${what.slice(0, 80)}`, { tabsRect: [Math.round(r.top), Math.round(r.bottom)] });
    }
  }, { capture: true, passive: true });
  window.addEventListener("orientationchange", () => crumb("orientation change"));
  document.addEventListener("visibilitychange", () => { crumb(document.hidden ? "hidden" : "visible"); if (document.hidden) sendDiag(); });
  WIDE.addEventListener("change", () => { if (state.data) render(); });
  LAND.addEventListener("change", () => { if (state.data) render(); });
  document.getElementById("sidefoot").addEventListener("click", () => {
    const sys = state.data && systemStatus();
    if (!sys) return;
    openSheet("System", `<div class="status-pop sheetstatus">${sys.items.map((x) => `<div class="pi ${x.level}"><i></i><div><b>${esc(x.title)}</b>${x.note ? `<span>${x.note}</span>` : ""}</div></div>`).join("")}${sys.connect ? connectBtn() : ""}</div>`);
  });
  // a tab answers the moment a finger lifts off it, not only on the click iOS makes afterwards:
  // after the phone turns, iOS sometimes stops sending those clicks and the tab bar seemed dead
  let tabTouch = null;
  document.querySelector(".tabs").addEventListener("touchstart", (e) => { const t = e.touches[0]; tabTouch = t ? { x: t.clientX, y: t.clientY } : null; }, { passive: true });
  document.querySelector(".tabs").addEventListener("touchend", (e) => {
    const t = e.target.closest("a[data-tab]"), c = e.changedTouches[0];
    if (!t || !tabTouch || !c || Math.hypot(c.clientX - tabTouch.x, c.clientY - tabTouch.y) > 12) return;
    e.preventDefault();  // no click follows, so it can't fire twice
    crumb(`tab touch ${t.dataset.tab}`);
    if (t.dataset.tab !== route()) {
      const want = t.dataset.tab;
      unstick(); location.hash = want;
      setTimeout(() => { if (route() !== want) diag("tab ignored", `tapped ${want}, still on ${route()}`); }, 900);
    } else t.click();
  });
  document.querySelector(".tabs").addEventListener("click", (e) => {
    const t = e.target.closest("a[data-tab]");
    if (t && t.dataset.tab !== route()) {
      // move ourselves rather than leaning on the link, and clear anything that could be sitting over the page
      e.preventDefault();
      unstick();
      location.hash = t.dataset.tab;
      return;
    }
    if (t && t.dataset.tab === route()) {
      if (route() === "settings" && state.setPage) { state.setPage = null; render(); }
      else if (route() === "history" && state.coldView) { state.coldView = false; render(); }
      view.scrollTo({ top: 0, behavior: "smooth" });
    }
  });
  view.addEventListener("submit", (e) => {
    if (e.target.id === "askform") { e.preventDefault(); const i = document.getElementById("askin"); askSend(i ? i.value : ""); }
  });
  view.addEventListener("change", (e) => {
    if (e.target.id === "landpref") { lsSet("landscape", e.target.checked ? null : false); document.body.classList.toggle("land", land()); return; }
    if (e.target.id === "addfile" && e.target.files && e.target.files.length) {
      const files = [...e.target.files]; e.target.value = "";
      (async () => {
        const st = () => document.getElementById("upstatus");
        let sent = 0;
        for (const f of files) {
          if (files.length > 1 && st()) st().textContent = `Sending ${sent + 1} of ${files.length}…`;
          if (await sendFile(f, files.length > 1)) sent++;
        }
        if (files.length > 1 && st()) st().textContent = sent === files.length ? `Sent all ${sent}. They'll be in the app in a few minutes.` : `Sent ${sent} of ${files.length}. The others didn't go; try them again.`;
      })();
    }
  });
  view.addEventListener("click", (e) => {
    const pop = e.target.closest("[data-pop]");
    if (pop) {
      const box = pop.nextElementSibling, open = box.hidden;
      box.hidden = !open; pop.setAttribute("aria-expanded", String(open));
      return;
    }
    const cp = e.target.closest("[data-copy]");
    if (cp) {
      const done = () => { cp.textContent = "Copied. Paste it into Safari's address bar."; };
      if (navigator.clipboard) navigator.clipboard.writeText(cp.dataset.copy).then(done, () => prompt("Copy this link", cp.dataset.copy));
      else prompt("Copy this link", cp.dataset.copy);
      return;
    }
    if (e.target.closest("[data-moon]")) { state.moonOpen = !state.moonOpen; render(); return; }
    const aq = e.target.closest("[data-askq]");
    if (aq) { askSend(aq.dataset.askq); return; }
    if (e.target.closest("[data-askretry]")) { const q = ask.msgs.pop().text; askSend(q); return; }
    if (e.target.closest("#askmic")) { askListen(); return; }
    if (e.target.closest("#asknew")) { newChat(); render(); return; }
    if (e.target.closest("#askpast")) { openSheet("Past conversations", chatsSheet()); return; }
    const pl = e.target.closest("[data-askplay]");
    if (pl) { const m = ask.msgs[+pl.dataset.askplay]; if (m) { askSpeak(m.text); render(); } return; }
    if (e.target.closest("#askstop")) { if ("speechSynthesis" in window) speechSynthesis.cancel(); ask.speaking = false; render(); return; }
    if (e.target.closest("#alertsave")) { saveAlerts(false); return; }
    if (e.target.closest("#alertoff")) { saveAlerts(true); return; }
    const cy = e.target.closest("[data-climyear]");
    if (cy) { state.climYear = cy.dataset.climyear; render(); return; }
    if (e.target.closest("[data-cold]")) { state.coldView = true; render(); view.scrollTop = 0; return; }
    if (e.target.closest("[data-cold-back]")) { state.coldView = false; render(); view.scrollTop = 0; return; }
    const hv = e.target.closest("[data-hview]");
    if (hv) { state.histView = hv.dataset.hview; try { localStorage.setItem("histView", state.histView); } catch (_) {} render(); return; }
    const ps = e.target.closest("[data-presolar]");
    if (ps) { openSheet(`${monthName(ps.dataset.presolar)} bill`, preSolarSheet(ps.dataset.presolar)); return; }
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
    if (e.target.closest("[data-back]")) { state.setPage = null; location.hash = "#" + (state.lastTab || "now"); return; }
    const sp = e.target.closest("[data-setpage]");
    if (sp) { state.setPage = sp.dataset.setpage; render(); view.scrollTop = 0; return; }
    if (e.target.closest("[data-setback]")) { state.setPage = null; render(); view.scrollTop = 0; return; }
    if (e.target.closest("#lockapp")) { HomeSolarLock.forget(); location.reload(); return; }
    const d = e.target.closest("[data-day]");
    if (d) { state.day = d.dataset.day; render(); openSheet(dayName(state.day), daySheet(state.day)); }
  });
  view.addEventListener("toggle", (e) => { if (e.target.matches("details.acc")) { state.ledgerOpen = e.target.open; fitCheck(); } }, true);
  view.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && e.target.matches("[role=button]")) { e.preventDefault(); e.target.dispatchEvent(new MouseEvent("click", { bubbles: true })); }
  });
  window.addEventListener("hashchange", () => { closeSheet(true); render(); view.scrollTo(0, 0); });
  let lastW = innerWidth;
  window.addEventListener("resize", () => { if (state.data && Math.abs(innerWidth - lastW) > 20) { lastW = innerWidth; render(); } });
  // iOS reports the new size during the rotation, before the layout has settled, so the chart was
  // sized (and "fits, no scrolling" decided) for the old shape. Measure again once <main> has its final size.
  let settleT = 0, lastBox = "";
  if (window.ResizeObserver) new ResizeObserver(() => {
    const box = `${view.clientWidth}x${view.clientHeight}`;
    if (box === lastBox) return;
    lastBox = box;
    clearTimeout(settleT);
    settleT = setTimeout(() => { if (!state.data || document.body.classList.contains("locked")) return; if (route() === "now") render(); else fitCheck(); }, 180);
  }).observe(view);
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
    fetch(`data.json?t=${Date.now()}`, { cache: "no-store" })
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
  fetch(`data.json?t=${Date.now()}`, { cache: "no-store" })
    .then((r) => { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then((data) => { state.encrypted = HomeSolarLock.isEncrypted(data); return state.encrypted ? HomeSolarLock.unlock(view, data) : data; })
    .then((data) => {
      state.data = data; state.month = defaultMonth(); render(); refreshLive();
    })
    .catch(() => { view.innerHTML = '<h1>Home Solar</h1><p class="sub">Couldn\'t load data.json. If you opened index.html straight from your computer, run the build and serve the _site folder instead.</p>'; });
})();
