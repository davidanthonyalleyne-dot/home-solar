(() => {
  "use strict";

  const view = document.getElementById("view");

  // Safari ignores user-scalable=no, so block its pinch gestures directly
  ["gesturestart", "gesturechange", "gestureend"].forEach((t) => document.addEventListener(t, (e) => e.preventDefault(), { passive: false }));
  const state = { data: null, month: null, day: null, view: "home" };

  // ---------- helpers ----------
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const fmt = (n, dp = 0) => (n == null || isNaN(n)) ? "–" : Number(n).toLocaleString("en-CA", { minimumFractionDigits: dp, maximumFractionDigits: dp });
  const kwh = (n) => Math.abs(n) >= 100 ? fmt(n) : fmt(n, 1);
  const signed = (n) => (n < 0 ? "−" : "") + kwh(Math.abs(n));
  const parseDay = (d) => { const [y, m, dd] = d.split("-").map(Number); return new Date(y, m - 1, dd); };
  const monthName = (ym, style = "long") => { const [y, m] = ym.split("-").map(Number); return new Date(y, m - 1, 1).toLocaleDateString("en-US", { month: style, year: "numeric" }); };
  const dayName = (d) => parseDay(d).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
  const shortDay = (d) => parseDay(d).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  const daysIn = (ym) => { const [y, m] = ym.split("-").map(Number); return new Date(y, m, 0).getDate(); };
  const pct = (a, b) => b > 0 ? Math.round((a / b) * 100) : 0;
  const chev = '<svg class="chev" viewBox="0 0 10 16" aria-hidden="true"><path d="M2 2l6 6-6 6"/></svg>';
  const sunIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>';
  const boltIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M13 2L4 14h7l-1 8 9-12h-7z"/></svg>';
  const down = (c) => `<svg viewBox="0 0 24 24" stroke="${c}" aria-hidden="true"><path d="M12 5v14M5 12l7 7 7-7"/></svg>`;
  const up = (c) => `<svg viewBox="0 0 24 24" stroke="${c}" aria-hidden="true"><path d="M12 19V5M5 12l7-7 7 7"/></svg>`;

  // ---------- data ----------
  const hydro = () => state.data.hydro || {};
  const solar = () => (state.data.solar && state.data.solar.daily && Object.keys(state.data.solar.daily).length) ? state.data.solar : null;
  const needsConnect = () => !!(state.data.solar && state.data.solar.needsConnect);
  const connectBtn = () => state.data.connectUrl ? `<a class="list row" href="${esc(state.data.connectUrl)}" style="justify-content:center;color:var(--accent);font-weight:600">Connect SolarEdge</a>` : "";

  let _range = null;
  function solarRange() {
    if (!_range) { const k = Object.keys(solar().daily).sort(); _range = [k[0], k.at(-1)]; }
    return _range;
  }

  function months() {
    const s = new Set(Object.keys(hydro()).map((d) => d.slice(0, 7)));
    if (solar()) Object.keys(solar().daily || {}).forEach((d) => s.add(d.slice(0, 7)));
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
      if (p == null && solar() && h && d >= solarRange()[0] && d <= solarRange()[1]) p = 0;
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

  // ---------- shared pieces ----------
  function monthHeader(title) {
    const all = months(), latestYear = all.length ? all.at(-1).slice(0, 4) : "";
    const chips = all.map((ym) => {
      const [y, m] = ym.split("-").map(Number);
      const label = new Date(y, m - 1, 1).toLocaleDateString("en-US", { month: "short" }) + (String(y) !== latestYear ? ` ’${String(y).slice(2)}` : "");
      return `<button type="button" class="chip" data-ym="${ym}" aria-pressed="${ym === state.month}" aria-label="${esc(monthName(ym))}">${esc(label)}</button>`;
    }).join("");
    return `<div class="head"><div><div class="eyebrow">${esc(title)}</div><h1>${esc(monthName(state.month))}</h1></div></div>
      ${all.length > 1 ? `<div class="chips" role="group" aria-label="Month">${chips}</div>` : ""}`;
  }

  // per-month figures used for comparisons and the year chart
  function monthStats(ym) {
    const t = totals(monthDays(ym));
    return {
      ym, t,
      home: t.bothDays ? t.home / t.bothDays : null,
      imp: t.hDays ? t.imp / t.hDays : null,
      prod: t.pDays ? t.prod / t.pDays : null,
      self: t.bothDays ? t.self / t.bothDays : null,
      cover: t.bothDays ? pct(t.self, t.home) : null,
    };
  }

  const mName = (ym) => monthName(ym).replace(/ \d+$/, "");
  const change = (a, b) => Math.round(((a - b) / b) * 100);

  function highlights(ym) {
    const days = monthDays(ym), cur = monthStats(ym);
    const all = months(), i = all.indexOf(ym), prev = i > 0 ? monthStats(all[i - 1]) : null;
    const name = mName(ym), out = [];
    const item = (color, icon, title, text, extra = "") => out.push(`<div class="hl"><span class="hl-ic" style="color:${color}">${icon}</span><div class="hl-body"><span class="hl-t">${title}</span><span class="small">${text}</span>${extra}</div></div>`);
    const compareBars = (label, a, b, color) => {
      const mx = Math.max(a, b) || 1;
      return `<div class="cmp">
        <div class="cmp-row"><span class="cmp-l">${esc(name)}</span><span class="cmp-bar"><i style="width:${(a / mx) * 100}%;background:${color}"></i></span><span class="cmp-v num">${fmt(a, 1)}</span></div>
        <div class="cmp-row"><span class="cmp-l">${esc(mName(prev.ym))}</span><span class="cmp-bar"><i style="width:${(b / mx) * 100}%;background:var(--chev)"></i></span><span class="cmp-v num">${fmt(b, 1)}</span></div>
        <span class="cmp-u">${label}</span></div>`;
    };
    const homeIc = '<svg viewBox="0 0 24 24"><path d="M3 10.5L12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6h-6v6H4a1 1 0 0 1-1-1z"/></svg>';
    const alertIc = '<svg viewBox="0 0 24 24"><path d="M12 3l10 18H2z"/><path d="M12 10v5M12 18h.01"/></svg>';
    const calIc = '<svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/></svg>';
    const upIc = '<svg viewBox="0 0 24 24"><path d="M12 19V5M5 12l7-7 7 7"/></svg>';

    // home use against last month
    const curUse = cur.home ?? cur.imp, prevUse = prev ? (cur.home != null ? prev.home : prev.imp) : null;
    if (curUse != null && prevUse) {
      const c = change(curUse, prevUse), what = cur.home != null ? "Home use" : "Grid use";
      item("var(--grid)", homeIc, `${what} ${c >= 0 ? "up" : "down"} ${Math.abs(c)}% on ${esc(mName(prev.ym))}`,
        c > 15 && Number(ym.slice(5)) >= 9 ? "Heating season is starting to show." : c < -15 && Number(ym.slice(5)) <= 6 ? "Less heating as the weather warms." : `${fmt(curUse, 1)} kWh a day, against ${fmt(prevUse, 1)}.`,
        compareBars("kWh a day", curUse, prevUse, "var(--grid)"));
    }
    // solar against last month
    if (cur.prod != null && prev && prev.prod) {
      const c = change(cur.prod, prev.prod);
      item("var(--solar)", sunIcon, `Solar ${c >= 0 ? "up" : "down"} ${Math.abs(c)}% on ${esc(mName(prev.ym))}`,
        c < 0 && Number(ym.slice(5)) >= 7 ? "Shorter days and a lower sun." : c > 0 && Number(ym.slice(5)) <= 6 ? "Longer days and a higher sun." : `${fmt(cur.prod, 1)} kWh a day, against ${fmt(prev.prod, 1)}.`,
        compareBars("kWh a day", cur.prod, prev.prod, "var(--solar)"));
    }
    // solar against the same month a year earlier
    const lastYear = `${Number(ym.slice(0, 4)) - 1}${ym.slice(4)}`, ly = monthStats(lastYear);
    if (cur.prod != null && ly.prod && ly.t.pDays >= 20) {
      const c = change(cur.prod, ly.prod);
      item("var(--solar)", sunIcon, `Solar ${c >= 0 ? "up" : "down"} ${Math.abs(c)}% on ${esc(monthName(lastYear))}`,
        `${fmt(cur.prod, 1)} kWh a day, against ${fmt(ly.prod, 1)} a year earlier.${Math.abs(c) >= 15 ? " Mostly down to the weather, unless the system had problems." : ""}`);
    }
    // share of the home covered
    if (cur.cover != null) {
      const p = prev && prev.cover != null ? prev.cover : null;
      item("var(--solar)", sunIcon, `The panels covered ${cur.cover}% of the house`,
        p != null ? `${cur.cover > p ? "Up" : cur.cover < p ? "Down" : "The same as"} ${cur.cover === p ? "" : "from "}${p}% in ${esc(mName(prev.ym))}. The rest came from the grid.` : "The rest came from the grid.");
    }
    // solar missing on days the meter also shows nothing sent back
    const prodDays = days.filter((r) => r.prod != null && r.prod > 0.5);
    const typical = prodDays.length ? prodDays.reduce((a, r) => a + r.prod, 0) / prodDays.length : 0;
    const dead = days.filter((r) => r.imp != null && r.exp < 0.05 && (r.prod == null || r.prod < 0.5) && typical > 8);
    if (dead.length >= 2) {
      const range = dead.length > 2 ? `${shortDay(dead[0].d)} to ${shortDay(dead.at(-1).d)}` : dead.map((r) => shortDay(r.d)).join(" and ");
      item("var(--warn)", alertIc, `No solar on ${dead.length} days`, `${range}. The meter shows nothing sent back either, so the system was likely off. On a normal day it made about ${fmt(typical)} kWh, so roughly ${fmt(typical * dead.length)} kWh was missed.`);
    }
    // busiest day
    const used = days.filter((r) => (r.home ?? r.imp) != null);
    if (used.length >= 5) {
      const top = used.reduce((a, b) => ((b.home ?? b.imp) > (a.home ?? a.imp) ? b : a));
      const avg = used.reduce((a, r) => a + (r.home ?? r.imp), 0) / used.length;
      item("var(--grid)", upIc, `Busiest day was ${esc(dayName(top.d))}`, `${fmt(top.home ?? top.imp, 1)} kWh, ${fmt(((top.home ?? top.imp) / avg - 1) * 100)}% above the month's average.`);
    }
    // weekends against weekdays
    const wk = used.filter((r) => { const d = parseDay(r.d).getDay(); return d > 0 && d < 6; }), we = used.filter((r) => { const d = parseDay(r.d).getDay(); return d === 0 || d === 6; });
    if (wk.length >= 5 && we.length >= 2) {
      const a = we.reduce((x, r) => x + (r.home ?? r.imp), 0) / we.length, b = wk.reduce((x, r) => x + (r.home ?? r.imp), 0) / wk.length, c = change(a, b);
      if (Math.abs(c) >= 5) item("var(--grid)", calIc, `Weekends used ${Math.abs(c)}% ${c > 0 ? "more" : "less"}`, `${fmt(a, 1)} kWh a day on weekends, ${fmt(b, 1)} on weekdays.`);
    }
    // best and dullest solar days
    if (prodDays.length >= 5) {
      const best = prodDays.reduce((a, b) => (b.prod > a.prod ? b : a)), low = prodDays.reduce((a, b) => (b.prod < a.prod ? b : a));
      const ahead = days.filter((r) => r.imp != null && r.exp > r.imp).length;
      item("var(--solar)", sunIcon, `Best solar day was ${esc(shortDay(best.d))}`, `${fmt(best.prod, 1)} kWh. The dullest was ${esc(shortDay(low.d))} at ${fmt(low.prod, 1)}.${days.some((r) => r.imp != null) ? ` ${ahead ? (ahead === 1 ? "One day" : ahead + " days") + " sent back more than the house drew." : "No day sent back more than the house drew."}` : ""}`);
    }
    // production against what the sunlight predicted
    const perf = days.map((r) => [r, r.prod != null ? expectedFor(r.d) : null]).filter(([r, e]) => e != null && e > 1 && parseDay(r.d) < parseDay(torontoToday()));
    if (perf.length >= 7) {
      const act = perf.reduce((a, [r]) => a + r.prod, 0), exp = perf.reduce((a, [, e]) => a + e, 0);
      const weak = perf.filter(([r, e]) => e >= 8 && r.prod < 0.6 * e && !(weatherDay(r.d) && ((weatherDay(r.d)[5] || 0) > 0)));
      const p = pct(act, exp);
      item(p >= 85 ? "var(--good)" : "var(--warn)", p >= 85 ? okIc : warnIc, `Panels made ${p}% of what the sunlight predicted`,
        weak.length ? `${weak.length === 1 ? "One day" : weak.length + " days"} fell well short: ${weak.slice(0, 4).map(([r]) => shortDay(r.d)).join(", ")}${weak.length > 4 ? " and more" : ""}. Outages, snow cover or shade usually explain it.` : "Every day came in close to what the weather allowed.");
    }
    // the month's weather
    const wdays = days.map((r) => [r, weatherDay(r.d)]).filter(([, w]) => w);
    if (wdays.length >= 5) {
      const hi = wdays.reduce((a, [, w]) => a + w[0], 0) / wdays.length, lo = wdays.reduce((a, [, w]) => a + w[1], 0) / wdays.length;
      const sunny = wdays.filter(([, w]) => w[3] != null && w[3] >= 6).length;
      const withBoth = wdays.filter(([r, w]) => r.prod != null && r.prod > 0.5 && w[3] != null);
      let link = "";
      if (withBoth.length >= 6) {
        const srt = [...withBoth].sort((a, b) => b[1][3] - a[1][3]), half = Math.floor(srt.length / 2);
        const avgP = (xs) => xs.reduce((a, [r]) => a + r.prod, 0) / xs.length;
        const top = avgP(srt.slice(0, half)), bot = avgP(srt.slice(-half));
        if (bot > 0) link = ` The sunniest half of the days made ${fmt(top / bot, 1)} times as much solar as the dullest half.`;
      }
      const wc = wx(sunny >= wdays.length / 2 ? 1 : 3);
      item(wxColor(wc.icon), wxIcon(wc.icon, 20), `Average high ${deg(hi)}, low ${deg(lo)}`, `${sunny} of ${wdays.length} days had 6 or more hours of sunshine.${link}`);
    }
    return out.length ? `<div class="section">${esc(name)} highlights</div><div class="list hls">${out.join("")}</div>` : "";
  }

  function yearChart() {
    const ms = months().map(monthStats).filter((m) => m.imp != null);
    if (ms.length < 2) return "";
    const H = 120, max = Math.max(...ms.map((m) => (m.home ?? m.imp))) * 1.05;
    const px = (v) => Math.round((v / max) * H);
    const bars = ms.map((m) => {
      const on = m.ym === state.month, [y, mo] = m.ym.split("-").map(Number);
      const letter = new Date(y, mo - 1, 1).toLocaleDateString("en-US", { month: "narrow" });
      const segs = m.home != null ? `<i style="height:${px(m.self)}px;background:var(--solar);border-radius:3px 3px 0 0"></i><i style="height:${px(m.home - m.self)}px;background:var(--grid)"></i>` : `<i style="height:${px(m.imp)}px;background:var(--grid);border-radius:3px 3px 0 0"></i>`;
      return `<button type="button" class="ybar${on ? " on" : ""}" data-ym="${m.ym}" aria-pressed="${on}" aria-label="${esc(monthName(m.ym))}"><span class="ystack" style="height:${H}px">${segs}</span><span class="ylab">${letter}</span></button>`;
    }).join("");
    const withBoth = ms.filter((m) => m.home != null), tH = withBoth.reduce((a, m) => a + m.t.home, 0), tS = withBoth.reduce((a, m) => a + m.t.self, 0);
    return `<div class="section">Your year</div>
      <section class="card" style="gap:10px">
        <span class="small">Home use per day by month. ${withBoth.length ? `Across these months the panels covered ${pct(tS, tH)}% of what the house used.` : ""} Tap a month to see it.</span>
        <div class="legend"><span><i style="background:var(--solar)"></i>Solar</span><span><i style="background:var(--grid)"></i>From grid</span></div>
        <div class="ychart">${bars}</div>
      </section>`;
  }

  function connectCard() {
    return `<a class="list row" href="#sources" style="text-decoration:none">
      <span style="display:flex;align-items:center;gap:12px;min-width:0"><span class="icon" style="background:var(--solar)">${sunIcon}</span>
      <span style="display:flex;flex-direction:column;gap:2px;min-width:0"><span>Solar production</span><span class="small">Connect SolarEdge to see what the panels made and what the house used directly.</span></span></span>${chev}</a>`;
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
    const M = (357.5291 + 0.98560028 * js) % 360;
    const C = 1.9148 * Math.sin(M * rad) + 0.02 * Math.sin(2 * M * rad) + 0.0003 * Math.sin(3 * M * rad);
    const L = (M + C + 180 + 102.9372) % 360;
    const jt = 2451545 + js + 0.0053 * Math.sin(M * rad) - 0.0069 * Math.sin(2 * L * rad);
    const dec = Math.asin(Math.sin(L * rad) * Math.sin(23.4397 * rad));
    const cosw = (Math.sin(-0.833 * rad) - Math.sin(LAT() * rad) * Math.sin(dec)) / (Math.cos(LAT() * rad) * Math.cos(dec));
    const w = Math.acos(Math.max(-1, Math.min(1, cosw))) / rad;
    const ms = (j) => new Date((j - 2440587.5) * 86400000);
    return { rise: ms(jt - w / 360), set: ms(jt + w / 360), noon: ms(jt) };
  }
  const clock = (t) => t.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone: TZNAME }).replace(" AM", " am").replace(" PM", " pm");
  const hm = (ms) => { const m = Math.round(ms / 60000); return `${Math.floor(m / 60)} h ${m % 60} min`; };
  const torontoToday = () => new Date().toLocaleDateString("en-CA", { timeZone: TZNAME });

  const WX = [
    [[0], "Clear", "sun"], [[1], "Mostly clear", "sun"], [[2], "Partly cloudy", "partly"], [[3], "Cloudy", "cloud"],
    [[45, 48], "Fog", "fog"], [[51, 53, 55, 56, 57], "Drizzle", "rain"], [[61, 63, 65, 66, 67, 80, 81, 82], "Rain", "rain"],
    [[71, 73, 75, 77, 85, 86], "Snow", "snow"], [[95, 96, 99], "Thunderstorms", "storm"],
  ];
  function wx(code, isDay = 1) {
    const hit = WX.find(([codes]) => codes.includes(Number(code))) || [[], "—", "cloud"];
    let label = hit[1], icon = hit[2];
    if (!isDay && icon === "sun") { icon = "moon"; label = code === 0 ? "Clear" : "Mostly clear"; }
    if (!isDay && icon === "partly") icon = "cloud";
    return { label, icon };
  }
  const WXI = {
    sun: '<circle cx="12" cy="12" r="4.5"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    moon: '<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>',
    partly: '<path d="M8 3v1.5M3.4 6.4l1 1M2 11h1.5M12.6 6.4l-1 1"/><path d="M5.6 12.6A3.5 3.5 0 1 1 11.8 9"/><path d="M8 20h9.5a3.5 3.5 0 0 0 0-7h-.4A5 5 0 0 0 8 14a3 3 0 0 0 0 6z"/>',
    cloud: '<path d="M7 19h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 12.1 3.5 3.5 0 0 0 7 19z"/>',
    rain: '<path d="M7 15h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 8.1 3.5 3.5 0 0 0 7 15z"/><path d="M8 18l-1 3M12 18l-1 3M16 18l-1 3"/>',
    snow: '<path d="M7 14h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 7.1 3.5 3.5 0 0 0 7 14z"/><path d="M8 18h.01M12 20h.01M16 18h.01M10 22h.01M14 22h.01"/>',
    fog: '<path d="M4 9h16M3 13h18M5 17h14"/>',
    storm: '<path d="M7 14h10.5a4 4 0 0 0 .4-8A6 6 0 0 0 6.4 7.1 3.5 3.5 0 0 0 7 14z"/><path d="M12 15l-2 4h3l-2 4"/>',
  };
  const wxIcon = (icon, size = 22, color = "currentColor") => `<svg class="wxi" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${color}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${WXI[icon] || WXI.cloud}</svg>`;
  const wxColor = (icon) => icon === "sun" ? "var(--solar)" : icon === "moon" ? "var(--muted)" : icon === "partly" ? "var(--solar)" : "var(--grid)";
  const deg = (t) => `${Math.round(t)}°`;
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
        live = { temp: b.current.temperature_2m, code: b.current.weather_code, isDay: b.current.is_day, time: b.current.time,
                 hi: b.daily && b.daily.temperature_2m_max[0], lo: b.daily && b.daily.temperature_2m_min[0] };
        if (["solar", "days", "overview"].includes(location.hash.slice(1) || "overview")) render();
      })
      .catch(() => {});
  }
  function currentWeather() {
    if (live) return live;
    const c = state.data.weather && state.data.weather.current, t = weatherDay(torontoToday());
    return c ? { ...c, hi: t && t[0], lo: t && t[1] } : null;
  }

  function sunCard() {
    const d = torontoToday(), { rise, set } = sunTimes(d), now = new Date();
    const before = now < rise, after = now > set;
    const status = before ? `Before sunrise · rises at ${clock(rise)}` : after ? `After sunset · set at ${clock(set)}` : `Daylight · sets at ${clock(set)}`;
    // position along the arc
    const f = Math.max(0, Math.min(1, (now - rise) / (set - rise)));
    const W = 300, Hh = 70, x = 20 + f * (W - 40), yArc = (t) => 80 - Math.sin(t * Math.PI) * Hh;
    let path = ""; for (let i = 0; i <= 40; i++) { const t = i / 40; path += `${i ? "L" : "M"}${(20 + t * (W - 40)).toFixed(1)},${yArc(t).toFixed(1)}`; }
    const up = !before && !after;
    const w = currentWeather(), cond = w ? wx(w.code, w.isDay) : null;
    const weather = w ? `<div class="wx">
        <span style="color:${wxColor(cond.icon)}">${wxIcon(cond.icon, 40)}</span>
        <div style="display:flex;flex-direction:column;gap:1px;flex:1;min-width:0"><span class="num" style="font-size:34px;font-weight:600;line-height:1">${deg(w.temp)}</span><span class="small">${esc(cond.label)}</span></div>
        ${w.hi != null ? `<div class="num" style="text-align:right;font-size:15px"><div>H ${deg(w.hi)}</div><div class="small">L ${deg(w.lo)}</div></div>` : ""}
      </div>` : "";
    return `<section class="card" style="gap:10px">${weather}
      <svg viewBox="0 0 ${W} 96" class="sunarc" role="img" aria-label="${esc(status)}">
        <line x1="0" y1="80" x2="${W}" y2="80" stroke="var(--sep)"/>
        <path d="${path}" fill="none" stroke="var(--sep)" stroke-width="2" stroke-dasharray="3 4"/>
        ${up ? `<circle cx="${x.toFixed(1)}" cy="${yArc(f).toFixed(1)}" r="8" fill="var(--solar)"/>` : `<circle cx="${before ? 20 : W - 20}" cy="80" r="6" fill="var(--muted)"/>`}
      </svg>
      <div class="axis" style="font-size:13px"><span>↑ ${clock(rise)}</span><span>${hm(set - rise)} of daylight</span><span>↓ ${clock(set)}</span></div>
      <span class="small" style="font-weight:600;color:var(--text)">${esc(status)}</span>
    </section>`;
  }


  // ---------- system health, expected production, extras ----------
  const alerts = () => (solar() && solar().alerts) || [];
  const warnIc = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l10 18H2z"/><path d="M12 10v5M12 18h.01"/></svg>';
  const okIc = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.7 2.7L16 9.5"/></svg>';
  const timeOf = (iso) => iso ? new Date(iso).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: TZNAME }) : "";

  function alertBanner() {
    const a = alerts();
    if (!a.length) return "";
    const first = a[0];
    return `<a class="banner" href="#solar"><span class="banner-ic">${warnIc}</span><span style="display:flex;flex-direction:column;gap:2px;min-width:0;flex:1">
      <span style="font-weight:600">${a.length === 1 ? "SolarEdge reports an alert" : `SolarEdge reports ${a.length} alerts`}</span>
      <span class="small">${esc(first.type || "Alert")}${first.component ? " · " + esc(first.component) : ""}</span></span>${chev}</a>`;
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

  const pretty = (name) => name.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, (c) => c.toUpperCase()).replace(/\bAc\b/, "AC").replace(/\bDc\b/, "DC");
  function inverterRows() {
    const inv = solar() && solar().inverter;
    if (!inv || !inv.metrics) return "";
    const m = inv.metrics, names = Object.keys(m);
    // skip readings that are all zero (e.g. consumption on a site without a consumption meter)
    const live = names.filter((n) => !(typeof m[n].max === "number" && m[n].max === 0 && m[n].min === 0));
    const pick = (re) => live.find((n) => re.test(n));
    const order = [pick(/^power$|^ac.*power|activepower/i), pick(/mode|status|state/i), pick(/temp/i), pick(/^voltage$|^ac.*volt/i), pick(/^current$|^ac.*curr/i), pick(/freq/i), pick(/dc.*power/i), pick(/dc.*volt/i), pick(/^energy$/i)];
    const shown = [...new Set(order.filter(Boolean)), ...live.filter((n) => !order.includes(n))].slice(0, 8);
    const LABELS = { power: "Output", energy: "Energy in the last hour", voltage: "Grid voltage", current: "Current", frequency: "Grid frequency", temperature: "Temperature" };
    const pretty = (n) => LABELS[n] || n.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, (c) => c.toUpperCase()).replace(/\bAc\b/, "AC").replace(/\bDc\b/, "DC");
    const UNITS = { C: "°C", CELSIUS: "°C", W: " W", WATT: " W", V: " V", VOLT: " V", HZ: " Hz", HERTZ: " Hz", A: " A", AMPERE: " A", WH: " Wh", KWH: " kWh" };
    const unitOf = (x) => { const u = String(x.unit || "").toUpperCase(); return UNITS[u] ?? (x.unit ? " " + x.unit.toLowerCase() : ""); };
    const MODES = { MPPT: "Producing", SLEEPING: "Sleeping", NIGHT: "Night", NIGHT_MODE: "Night", THROTTLED: "Limited", FAULT: "Fault", STARTING: "Starting up", OFF: "Off", SHUTTING_DOWN: "Shutting down", STANDBY: "Standby", LOCKED: "Locked" };
    const val = (x) => typeof x.latest === "number" ? fmt(x.latest, Math.abs(x.latest) < 100 ? 1 : 0) + unitOf(x) : esc(MODES[String(x.latest).toUpperCase()] || String(x.latest ?? "–").replace(/_/g, " ").toLowerCase().replace(/^./, (c) => c.toUpperCase()));
    const rows = shown.map((n) => {
      const x = m[n], extra = /temp|^power$/i.test(n) && typeof x.max === "number" && x.max !== x.latest ? ` <span class="small">· high ${fmt(x.max, 0)}${unitOf(x)}</span>` : "";
      return `<div class="row"><span>${esc(pretty(n))}</span><span class="val num">${val(x)}${extra}</span></div>`;
    }).join("");
    return `<div class="section">Inverter</div><div class="list">${rows}</div><div class="foot">Hourly readings from SolarEdge, last at ${esc(timeOf(inv.at))}.</div>`;
  }

  function healthBlock() {
    const s = solar();
    if (!s) return "";
    const a = alerts();
    const rows = a.length
      ? a.map((x) => `<div class="row" style="align-items:flex-start"><span class="hl-ic" style="color:var(--warn)">${warnIc}</span><span style="display:flex;flex-direction:column;gap:2px;flex:1;min-width:0">
          <span style="font-weight:600">${esc(x.type || "Alert")}</span>
          <span class="small">${[x.component, x.category && pretty(String(x.category).toLowerCase()), x.impact != null && `impact ${x.impact} of 9`, x.first && `since ${timeOf(x.first)}`].filter(Boolean).map(esc).join(" · ")}</span></span></div>`).join("")
      : `<div class="row" style="justify-content:flex-start;gap:10px"><span class="hl-ic" style="color:var(--good)">${okIc}</span><span>${s.alertsChecked ? "No open alerts" : "Alerts not checked yet"}</span></div>`;
    return `<div class="section" id="alerts">System health</div><div class="list hl-list">${rows}</div>
      ${s.alertsChecked ? `<div class="foot">SolarEdge checked ${esc(timeOf(s.alertsChecked))}. New alerts also open an issue in your GitHub repo, which emails you.</div>` : ""}`;
  }

  function benefitsCard() {
    const b = solar() && solar().benefits;
    if (!b) return "";
    const keys = Object.keys(b), num = (re) => { const k = keys.find((x) => re.test(x) && typeof b[x] === "number"); return k ? [k, b[k]] : null; };
    const co2 = num(/co2/i), trees = num(/tree/i), bulbs = num(/bulb/i), ev = num(/ev(miles|km)?/i);
    const unitK = keys.find((k) => /unit/i.test(k)), unit = unitK ? String(b[unitK]).toLowerCase() : "kg";
    const parts = [];
    if (co2) { const kg = /lb/.test(unit) ? co2[1] * 0.4536 : /^t|ton/.test(unit) ? co2[1] * 1000 : co2[1]; parts.push(`<div class="tile"><span class="k">CO₂ avoided</span><span class="v num">${kg >= 1000 ? fmt(kg / 1000, 1) + " <small>tonnes</small>" : fmt(kg) + " <small>kg</small>"}</span></div>`); }
    if (trees) parts.push(`<div class="tile"><span class="k">Like planting</span><span class="v num">${fmt(trees[1])} <small>trees</small></span></div>`);
    if (!trees && bulbs) parts.push(`<div class="tile"><span class="k">Light bulbs for a day</span><span class="v num">${fmt(bulbs[1])}</span></div>`);
    if (!trees && !bulbs && ev) parts.push(`<div class="tile"><span class="k">Enough to drive an EV</span><span class="v num">${fmt(/km/i.test(ev[0]) ? ev[1] : ev[1] * 1.609)} <small>km</small></span></div>`);
    if (!parts.length) return "";
    return `<div class="section">Since ${esc(solar().installed ? new Date(solar().installed + "T12:00").toLocaleDateString("en-US", { month: "long", year: "numeric" }) : "install")}</div><div class="tiles">${parts.join("")}</div><div class="foot">SolarEdge's estimates. Its CO₂ figure uses a general grid average, and Ontario's grid is mostly nuclear and hydro, so the real saving here is smaller.</div>`;
  }

  function yearsBlock() {
    const s = solar();
    if (!s) return "";
    const by = {};
    for (const [d, v] of Object.entries(s.daily)) by[d.slice(0, 4)] = (by[d.slice(0, 4)] || 0) + (v || 0);
    const years = Object.keys(by).sort().reverse();
    if (years.length < 2) return "";
    const first = Object.keys(s.daily).sort()[0], thisYear = torontoToday().slice(0, 4);
    const max = Math.max(...years.map((y) => by[y]));
    const rows = years.map((y) => {
      const note = y === thisYear ? " so far" : y === first.slice(0, 4) && first.slice(5) > "01-15" ? ` from ${shortDay(first)}` : "";
      return `<div class="row" style="gap:12px"><span style="width:110px;flex-shrink:0">${y}<span class="small">${note}</span></span><span class="bar thick" style="flex:1"><i style="width:${(by[y] / max) * 100}%"></i></span><span class="val num" style="min-width:84px">${fmt(by[y])} kWh</span></div>`;
    }).join("");
    return `<div class="section">By year</div><div class="list">${rows}</div>`;
  }

  function tomorrowRow() {
    const t = state.data.weather && state.data.weather.tomorrow, k = state.data.weather && state.data.weather.factor;
    if (!t) return "";
    const [d, hi, lo, code, , ghi] = t, c = wx(code), exp = k && ghi != null ? k * ghi : null;
    return `<div class="list"><div class="row"><span style="display:flex;align-items:center;gap:8px"><span style="color:${wxColor(c.icon)}">${wxIcon(c.icon, 20)}</span>Tomorrow · ${esc(c.label)}</span><span class="val num">${exp != null ? `about ${fmt(exp)} kWh` : `H ${deg(hi)} · L ${deg(lo)}`}</span></div></div>`;
  }

  // ---------- screens ----------
  function overview() {
    if (!state.month) return `<h1>Overview</h1><div class="card empty"><h2>No data yet</h2><p class="small">Add a Toronto Hydro export to data/hydro or connect SolarEdge.</p></div>`;
    const days = monthDays(state.month), t = totals(days);
    const name = mName(state.month);
    let html = monthHeader("Overview") + alertBanner();

    if (t.hDays) {
      const net = t.imp - t.exp;
      let detail;
      if (t.bothDays && t.bothDays === t.hDays) {
        const sp = pct(t.self, t.home);
        detail = `<div class="split" role="img" aria-label="${sp}% of home use came straight from the panels"><i style="width:${sp}%;background:var(--solar)"></i><i style="width:${100 - sp}%;background:var(--grid)"></i></div>
          <div class="legend"><span><i style="background:var(--solar)"></i>Solar, used directly</span><span><i style="background:var(--grid)"></i>From the grid</span></div>
          <span class="small">In ${esc(name)} your home used <b class="num">${kwh(t.home)} kWh</b>. The panels covered ${sp}% of it directly, and you sent ${kwh(t.exp)} kWh back for credit.</span>`;
      } else {
        const cp = pct(t.exp, t.imp);
        detail = `<div class="split" role="img" aria-label="Exports covered ${cp}% of imports"><i style="width:${Math.min(cp, 100)}%;background:var(--solar)"></i><i style="width:${Math.max(0, 100 - cp)}%;background:var(--grid)"></i></div>
          <span class="small">What you sent back covered ${cp}% of what you drew from the grid.</span>`;
      }
      html += `<section class="card"><span class="label">${net >= 0 ? "Net from the grid" : "Net sent to the grid"} in ${esc(name)}</span>
        <div class="hero num"><b>${kwh(Math.abs(net))}</b><span>kWh</span></div>${detail}</section>`;
      html += `<div class="tiles">
        <div class="tile"><span class="k">${down("var(--grid)")}From grid</span><span class="v num">${kwh(t.imp)} <small>kWh</small></span><span class="small num">${fmt(t.imp / t.hDays, 1)} a day</span></div>
        <div class="tile"><span class="k">${up("var(--solar)")}To grid</span><span class="v num">${kwh(t.exp)} <small>kWh</small></span><span class="small num">${fmt(t.exp / t.hDays, 1)} a day</span></div>
        ${t.pDays ? `<div class="tile"><span class="k">${sunIcon.replace("<svg", '<svg stroke="var(--solar)"')}Produced</span><span class="v num">${kwh(t.prod)} <small>kWh</small></span><span class="small num">${fmt(t.prod / t.pDays, 1)} a day</span></div>` : ""}
        ${t.bothDays ? `<div class="tile"><span class="k">${sunIcon.replace("<svg", '<svg stroke="var(--solar)"')}Used directly</span><span class="v num">${kwh(t.self)} <small>kWh</small></span><span class="small num">${pct(t.self, t.prod)}% of production</span></div>` : ""}
      </div>`;
    } else if (t.pDays) {
      html += `<section class="card"><span class="label">Solar produced</span><div class="hero num"><b>${kwh(t.prod)}</b><span>kWh</span></div>
        <span class="small">No Toronto Hydro data for ${esc(name)} yet. Upload the export to see what you drew from and sent to the grid.</span></section>`;
    }

    if (!solar()) html += connectCard();

    html += highlights(state.month);
    html += yearChart();
    return html;
  }

  function daysScreen() {
    if (!state.month) return `<h1>Days</h1>`;
    const days = monthDays(state.month);
    const hasH = days.some((r) => r.imp != null), hasP = days.some((r) => r.prod != null);
    const avail = [hasH && "home", hasP && "solar", hasH && "net"].filter(Boolean);
    if (!avail.includes(state.view)) state.view = avail[0] || "home";
    const V = state.view;
    if (!state.day || !state.day.startsWith(state.month)) {
      const last = [...days].reverse().find((r) => r.imp != null || r.prod != null);
      state.day = last ? last.d : days[0].d;
    }

    // what each view plots: stacked segments [value, colour] from the bottom up, or one signed value for net
    const anyHome = days.some((r) => r.home != null), anySelf = days.some((r) => r.self != null);
    const segs = (r) => {
      if (V === "home") return r.home != null ? [[r.imp, "var(--grid)"], [r.self, "var(--solar)"]] : r.imp != null ? [[r.imp, "var(--grid)"]] : null;
      if (V === "solar") return r.prod == null ? null : r.self != null ? [[r.self, "var(--solar)"], [r.exp, "var(--back)"]] : [[r.prod, "var(--solar)"]];
      return r.imp != null ? r.imp - r.exp : null;
    };
    const value = (r) => { const x = segs(r); return x == null ? null : Array.isArray(x) ? x.reduce((a, b) => a + b[0], 0) : x; };
    const vals = days.map(value).filter((v) => v != null);
    const avg = vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : 0;
    const t = totals(days);

    let label, sub, legend;
    if (V === "home") {
      label = anyHome ? "Home use" : "From the grid";
      sub = anyHome ? `The panels covered ${pct(t.self, t.self + t.imp)}% of what the house used.` : (solar() ? "No solar data for these days." : "Connect SolarEdge to see how much of this the panels covered.");
      legend = anyHome ? [["Solar", "var(--solar)"], ["From grid", "var(--grid)"]] : [["From grid", "var(--grid)"]];
    } else if (V === "solar") {
      label = "Solar produced";
      sub = anySelf ? `${pct(t.self, t.self + t.exp)}% was used in the house and ${pct(t.exp, t.self + t.exp)}% sent back for credit.` : "Add this month's Toronto Hydro file to see how much was used in the house.";
      legend = anySelf ? [["Used in the house", "var(--solar)"], ["Sent back", "var(--back)"]] : [["Produced", "var(--solar)"]];
    } else {
      const ahead = days.filter((r) => r.imp != null && r.exp > r.imp).length;
      label = "Net from the grid";
      sub = ahead ? `${ahead === 1 ? "One day" : ahead + " days"} sent back more than the house drew.` : "Every day drew more from the grid than it sent back.";
      legend = [["Drew more", "var(--grid)"], ["Sent back more", "var(--back)"]];
    }

    // geometry
    const H = 200;
    let bars, avgBottom;
    if (V !== "net") {
      const max = Math.max(1, ...vals) * 1.05, px = (v) => Math.max(0, Math.round((v / max) * H));
      bars = days.map((r) => {
        const x = segs(r);
        const inner = x ? x.map(([v, c], i) => `<i style="height:${px(v)}px;background:${c}${i === x.length - 1 ? ";border-radius:3px 3px 0 0" : ""}"></i>`).reverse().join("") : "";
        return `<button type="button" data-day="${r.d}" aria-pressed="${r.d === state.day}" aria-label="${esc(dayName(r.d))}" class="${x ? "" : "gap"}"><span class="up" style="height:${H}px">${inner}</span></button>`;
      }).join("");
      avgBottom = px(avg);
    } else {
      const pos = Math.max(0, ...vals), neg = Math.max(0, ...vals.map((v) => -v));
      const span = Math.max(1, pos + neg) * 1.05, upH = Math.round((pos / Math.max(1e-9, pos + neg || 1)) * H) || (neg ? 0 : H);
      const px = (v) => Math.round((Math.abs(v) / span) * H);
      bars = days.map((r) => {
        const v = segs(r);
        const up = v != null && v >= 0 ? `<i style="height:${px(v)}px;background:var(--grid);border-radius:3px 3px 0 0"></i>` : "";
        const dn = v != null && v < 0 ? `<i style="height:${px(v)}px;background:var(--back);border-radius:0 0 3px 3px"></i>` : "";
        return `<button type="button" data-day="${r.d}" aria-pressed="${r.d === state.day}" aria-label="${esc(dayName(r.d))}" class="${v == null ? "gap" : ""}"><span class="up" style="height:${upH}px">${up}</span><span class="dn" style="height:${H - upH}px">${dn}</span></button>`;
      }).join("");
      avgBottom = (H - upH) + (avg >= 0 ? px(avg) : -px(avg));
    }

    const n = days.length, r = days.find((x) => x.d === state.day);
    const names = { home: "Home use", solar: "Solar", net: "Net grid" };
    const seg = avail.length > 1 ? `<div class="seg" role="group" aria-label="Chart">${avail.map((v) => `<button type="button" data-view="${v}" aria-pressed="${v === V}">${names[v]}</button>`).join("")}</div>` : "";

    let rows = "";
    if (r.home != null) rows += `<div class="row"><span>Home used</span><span class="val strong num">${kwh(r.home)} kWh</span></div>`;
    if (r.prod != null) rows += `<div class="row"><span>Solar produced</span><span class="val num">${kwh(r.prod)} kWh</span></div>`;
    const ex = r.prod != null ? expectedFor(r.d) : null;
    if (ex != null && ex > 0.5) rows += `<div class="row"><span>Expected</span><span class="val num">${kwh(ex)} kWh <span class="small">· made ${pct(r.prod, ex)}%</span></span></div>`;
    if (r.self != null) rows += `<div class="row"><span>Solar used in the house</span><span class="val num">${kwh(r.self)} kWh</span></div>`;
    if (r.imp != null) rows += `<div class="row"><span>From grid</span><span class="val num">${kwh(r.imp)} kWh</span></div><div class="row"><span>Sent back</span><span class="val num">${kwh(r.exp)} kWh</span></div><div class="row"><span>Net from grid</span><span class="val ${r.home == null ? "strong" : ""} num">${signed(r.imp - r.exp)} kWh</span></div>`;
    if (!rows) rows = `<div class="row"><span class="val" style="text-align:left">No data for this day</span></div>`;
    const wd = weatherDay(r.d), sun = sunTimes(r.d);
    let wrows = "";
    if (wd) {
      const c = wx(wd[2]);
      wrows += `<div class="row"><span style="display:flex;align-items:center;gap:8px"><span style="color:${wxColor(c.icon)}">${wxIcon(c.icon, 20)}</span>${esc(c.label)}</span><span class="val num">H ${deg(wd[0])} · L ${deg(wd[1])}</span></div>`;
      if (wd[3] != null) wrows += `<div class="row"><span>Sunshine</span><span class="val num">${fmt(wd[3], 1)} h</span></div>`;
    }
    wrows += `<div class="row"><span>Sunrise · sunset</span><span class="val num">${clock(sun.rise)} · ${clock(sun.set)}</span></div><div class="row"><span>Daylight</span><span class="val num">${hm(sun.set - sun.rise)}</span></div>`;

    return `${monthHeader("Days")}
      ${seg}
      <section class="card" style="padding:16px 10px 10px">
        <div style="display:flex;flex-direction:column;gap:2px;padding:0 6px">
          <span class="label">${label}, average a day</span>
          <div class="hero num" style="gap:5px"><b style="font-size:40px">${signed(avg)}</b><span style="font-size:17px">kWh</span></div>
          <span class="small">${esc(sub)}</span>
        </div>
        <div class="legend" style="padding:0 6px">${legend.map(([l, c]) => `<span><i style="background:${c}"></i>${l}</span>`).join("")}<span><i class="dash"></i>Average</span></div>
        <div class="chartwrap"><div class="chart" style="height:${H}px">${bars}</div><div class="avg" style="bottom:${avgBottom}px" aria-hidden="true"></div></div>
        <div class="axis"><span>1</span><span>${Math.round(n / 4)}</span><span>${Math.round(n / 2)}</span><span>${Math.round((3 * n) / 4)}</span><span>${n}</span></div>
      </section>
      <div class="section">${esc(dayName(r.d))}</div>
      <div class="list">${rows}</div>
      <div class="list">${wrows}</div>`;
  }

  function solarScreen() {
    const s = solar();
    if (!s) return `<h1>Solar</h1>
      <section class="card empty"><span class="big">${sunIcon}</span><h2>SolarEdge isn't connected</h2>
      <p class="small" style="margin:0">${state.data.connectUrl ? "Sign in with your SolarEdge account and approve access to turn this on." : "Add your SolarEdge app's client ID, client secret and site ID as repository secrets in GitHub, then run the workflow again."}</p>
      </section>${connectBtn()}${sunCard()}`;

    const today = new Date().toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", timeZone: TZNAME });
    // overnight the last numbers belong to yesterday; don't show them as today's
    const fresh = !s.todayDate || s.todayDate === torontoToday();
    const todayKwh = fresh ? s.today : 0, nowKw = fresh ? s.nowKw : 0;
    const pts = (fresh ? s.todayCurve || [] : []).map(([t, kw]) => { const [h, m] = t.split(":").map(Number); return [h + m / 60, kw]; });
    const peak = Math.max(...pts.map((p) => p[1]), 0.1) * 1.15;
    let curve = "";
    if (pts.some((p) => p[1] > 0)) {
      const X = (h) => ((h - 5) / 16) * 300, Y = (kw) => 110 - (kw / peak) * 100;
      const line = pts.filter((p) => p[0] >= 5 && p[0] <= 21).map((p) => `${X(p[0]).toFixed(1)},${Y(p[1]).toFixed(1)}`);
      curve = `<svg class="curve" viewBox="0 0 300 124" preserveAspectRatio="none" role="img" aria-label="Solar power through the day">
        <line x1="0" y1="110" x2="300" y2="110" stroke="var(--sep)"/>
        <polygon points="${line[0].split(",")[0]},110 ${line.join(" ")} ${line.at(-1).split(",")[0]},110" fill="var(--solar)" fill-opacity=".14"/>
        <polyline points="${line.join(" ")}" fill="none" stroke="var(--solar)" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round"/>
      </svg><div class="axis"><span>6 am</span><span>Noon</span><span>6 pm</span></div>`;
    }
    const st = sunTimes(torontoToday()), nowD = new Date();
    const nowNote = nowKw > 0 ? "Producing now" : nowD < st.rise ? `Sunrise ${clock(st.rise)}` : nowD > st.set ? `Sunset was ${clock(st.set)}` : "Not producing";
    const updated = s.updated ? new Date(s.updated).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : null;

    const stale = needsConnect() ? `<section class="card" style="gap:6px"><span style="font-weight:600;font-size:15px">SolarEdge needs you to sign in again</span><span class="small">These are the last numbers it sent. Reconnect to start updating again.</span></section>${connectBtn()}` : "";
    const expT = expectedFor(torontoToday());
    return `<div><div class="eyebrow">${esc(today)}</div><h1>Solar</h1></div>${stale}${alertBanner()}
      <section class="card">
        <div style="display:flex;justify-content:space-between;align-items:flex-end;gap:12px">
          <div style="display:flex;flex-direction:column;gap:6px"><span class="label">Produced today</span><div class="hero num"><b>${fmt(todayKwh, 1)}</b><span>kWh</span></div>${expT ? `<span class="small">Sunlight today suggests about ${fmt(expT)} kWh</span>` : ""}</div>
          <div style="display:flex;flex-direction:column;align-items:flex-end;gap:2px;padding-bottom:4px"><span class="small">Right now</span><span class="num" style="font-size:20px;font-weight:600">${fmt(nowKw, nowKw ? 2 : 0)} kW</span><span class="small">${nowKw > 0 ? "of " + fmt(s.peakKw, 2) + " kW peak" : nowNote}</span></div>
        </div>${curve}
      </section>
      ${sunCard()}
      ${tomorrowRow()}
      ${healthBlock()}
      <div class="list">
        <div class="row"><span>This month</span><span class="val num">${kwh(s.month)} kWh</span></div>
        <div class="row"><span>This year</span><span class="val num">${fmt(s.year)} kWh</span></div>
        <div class="row"><span>Since ${esc(s.installed ? new Date(s.installed + "T12:00").toLocaleDateString("en-US", { month: "long", year: "numeric" }) : "install")}</span><span class="val num">${fmt(s.lifetime)} kWh</span></div>
      </div>
      ${updated ? `<div class="foot">SolarEdge last reported ${esc(updated)}.</div>` : ""}
      ${yearsBlock()}
      ${inverterRows()}
      ${benefitsCard()}`;
  }



  function equipmentBlock() {
    const e = solar() && solar().equipment;
    if (!e) return "";
    const inv = (e.inverters || []).map((i) => `
      <div class="row"><span>Inverter</span><span class="val">${esc([i.manufacturer, i.model].filter(Boolean).join(" ") || i.name || "–")}</span></div>
      ${i.firmware ? `<div class="row"><span>Firmware</span><span class="val num">${esc(i.firmware)}</span></div>` : ""}
      ${i.communication ? `<div class="row"><span>Connection</span><span class="val">${esc(({ WIFI: "Wi-Fi", ETHERNET: "Ethernet", LAN: "Ethernet", CELLULAR: "Cellular", ZIGBEE: "ZigBee", RS485: "RS485" })[String(i.communication).toUpperCase()] || pretty(String(i.communication).toLowerCase()))}</span></div>` : ""}`).join("");
    // the inverter's own count is what's actually wired in; SolarEdge's inventory can still list a replaced optimizer
    const connected = (e.inverters || []).reduce((a, i) => a + (Number(i.optimizers) || 0), 0) || e.optimizers;
    const models = [...new Set((e.optimizerModels || []).map((m) => m.split("-")[0]))];
    const opt = connected != null ? `<div class="row"><span>Optimizers</span><span class="val num">${connected} connected${models.length ? " · " + esc(models.join(", ")) : ""}</span></div>` : "";
    return inv || opt ? `<div class="section">Equipment</div><div class="list">${inv}${opt}</div>` : "";
  }

  function sourcesScreen() {
    const d = state.data, s = d.solar, h = Object.keys(hydro()).sort();
    const sol = s && s.connected && !s.needsConnect
      ? `<div class="row"><span>Status</span><span class="ok">Connected</span></div>
         ${s.peakKw ? `<div class="row"><span>System size</span><span class="val num">${fmt(s.peakKw, 2)} kW</span></div>` : ""}
         ${s.installed ? `<div class="row"><span>Installed</span><span class="val">${esc(new Date(s.installed + "T12:00").toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric" }))}</span></div>` : ""}
         <div class="row"><span>Daily history</span><span class="val num">${Object.keys(s.daily || {}).length} days</span></div>`
      : `<div class="row"><span>Status</span><span class="val">${s && s.needsConnect && s.daily ? "Sign-in expired" : "Not connected"}</span></div>`;
    return `<h1>Sources</h1>
      <div class="section">Solar inverter</div>
      <div class="list">
        <div class="row" style="justify-content:flex-start"><span class="icon" style="background:var(--solar)">${sunIcon}</span><span>SolarEdge</span></div>
        ${sol}
      </div>
      ${equipmentBlock()}
      ${s && s.connected && !s.needsConnect ? "" : connectBtn()}
      <div class="foot">${s && s.connected && !s.needsConnect ? "Refreshes every hour during the day." + (s.error ? " The last refresh failed, so these are the previous numbers." : "") : state.data.connectUrl ? "You'll sign in with SolarEdge, then paste a one-time code into GitHub." : "Add SOLAREDGE_CLIENT_ID, SOLAREDGE_CLIENT_SECRET, SOLAREDGE_SITE_ID and GH_PAT under Settings, Secrets and variables, Actions in your GitHub repository."}</div>
      <div class="section">Grid meter</div>
      <div class="list">
        <div class="row" style="justify-content:flex-start"><span class="icon" style="background:var(--grid)">${boltIcon}</span><span>Toronto Hydro</span></div>
        ${h.length ? `<div class="row"><span>Data</span><span class="val num">${esc(shortDay(h[0]))} to ${esc(shortDay(h.at(-1)))}, ${parseDay(h.at(-1)).getFullYear()}</span></div><div class="row"><span>Days</span><span class="val num">${h.length}</span></div>` : `<div class="row"><span>Data</span><span class="val">None yet</span></div>`}
      </div>
      <div class="foot">To add a month, download it from MyTorontoHydro and upload the file to the data/hydro folder in GitHub. The site rebuilds on its own.</div>
      <div class="foot" style="margin-top:0">Weather data by <a href="https://open-meteo.com/">Open-Meteo.com</a>. Sunrise and sunset are calculated for Parkdale.</div>
      <div class="foot" style="margin-top:0">Built ${esc(new Date(d.generated).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }))}.</div>`;
  }

  // ---------- routing ----------
  const screens = { overview, days: daysScreen, solar: solarScreen, sources: sourcesScreen };

  function render() {
    const route = (location.hash.slice(1) || "overview");
    const screen = screens[route] ? route : "overview";
    view.innerHTML = screens[screen]();
    const tab = screen;
    document.querySelectorAll(".tabs a").forEach((a) => { if (a.dataset.tab === tab) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current"); });
    document.title = (screen[0].toUpperCase() + screen.slice(1)) + " · Home Solar";
    const strip = view.querySelector(".chips"), chip = strip && strip.querySelector('[aria-pressed="true"]');
    if (chip) strip.scrollLeft = chip.offsetLeft - strip.clientWidth / 2 + chip.offsetWidth / 2;
  }

  view.addEventListener("click", (e) => {
    const m = e.target.closest("[data-ym]");
    if (m) { state.month = m.dataset.ym; state.day = null; render(); return; }
    const v = e.target.closest("[data-view]");
    if (v) { state.view = v.dataset.view; render(); return; }
    const d = e.target.closest("[data-day]");
    if (d) { state.day = d.dataset.day; render(); }
  });
  window.addEventListener("hashchange", () => { render(); window.scrollTo(0, 0); });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && state.data) { refreshLive(); render(); } });

  view.innerHTML = '<p class="loading">Loading…</p>';
  fetch("data.json", { cache: "no-store" })
    .then((r) => { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then((data) => { state.data = data; state.month = defaultMonth(); render(); refreshLive(); })
    .catch(() => { view.innerHTML = '<h1>Home Solar</h1><p class="small">Couldn\'t load data.json. If you opened index.html straight from your computer, run the build and serve the _site folder instead.</p>'; });
})();
