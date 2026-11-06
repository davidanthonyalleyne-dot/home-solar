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
      const p = solar() ? solar().daily[d] : undefined;
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
    const all = months(), i = all.indexOf(state.month);
    return `<div class="head">
      <div><div class="eyebrow">${esc(monthName(state.month))}</div><h1>${title}</h1></div>
      <div class="monthnav">
        <button type="button" data-month="${i - 1}" aria-label="Previous month" ${i <= 0 ? "disabled" : ""}><svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg></button>
        <button type="button" data-month="${i + 1}" aria-label="Next month" ${i >= all.length - 1 ? "disabled" : ""}><svg viewBox="0 0 24 24"><path d="M9 5l7 7-7 7"/></svg></button>
      </div></div>`;
  }

  function connectCard() {
    return `<a class="list row" href="#sources" style="text-decoration:none">
      <span style="display:flex;align-items:center;gap:12px;min-width:0"><span class="icon" style="background:var(--solar)">${sunIcon}</span>
      <span style="display:flex;flex-direction:column;gap:2px;min-width:0"><span>Solar production</span><span class="small">Connect SolarEdge to see what the panels made and what the house used directly.</span></span></span>${chev}</a>`;
  }

  // ---------- screens ----------
  function overview() {
    if (!state.month) return `<h1>Overview</h1><div class="card empty"><h2>No data yet</h2><p class="small">Add a Toronto Hydro export to data/hydro or connect SolarEdge.</p></div>`;
    const days = monthDays(state.month), t = totals(days);
    const name = monthName(state.month, "short").replace(/ \d+$/, "");
    let html = monthHeader("Overview");

    if (t.hDays) {
      const net = t.imp - t.exp;
      let detail;
      if (t.bothDays && t.bothDays === t.hDays) {
        const sp = pct(t.self, t.home);
        detail = `<div class="split" role="img" aria-label="${sp}% of home use came straight from the panels"><i style="width:${sp}%;background:var(--solar)"></i><i style="width:${100 - sp}%;background:var(--grid)"></i></div>
          <div class="legend"><span><i style="background:var(--solar)"></i>Solar, used directly</span><span><i style="background:var(--grid)"></i>From the grid</span></div>
          <span class="small">Your home used <b class="num">${kwh(t.home)} kWh</b>. The panels covered ${sp}% of it directly, and you sent ${kwh(t.exp)} kWh back for credit.</span>`;
      } else {
        const cp = pct(t.exp, t.imp);
        detail = `<div class="split" role="img" aria-label="Exports covered ${cp}% of imports"><i style="width:${Math.min(cp, 100)}%;background:var(--solar)"></i><i style="width:${Math.max(0, 100 - cp)}%;background:var(--grid)"></i></div>
          <span class="small">What you sent back covered ${cp}% of what you drew from the grid.</span>`;
      }
      html += `<section class="card"><span class="label">${net >= 0 ? "Net from the grid" : "Net sent to the grid"}</span>
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

    // a couple of plain facts about the month
    const facts = [];
    const ahead = days.filter((r) => r.imp != null && r.exp > r.imp);
    if (t.hDays) facts.push(ahead.length ? `${ahead.length === 1 ? "One day" : ahead.length + " days"} sent more than you used: ${ahead.map((r) => shortDay(r.d)).join(", ")}.` : "No day this month sent more to the grid than it took.");
    const withProd = days.filter((r) => r.prod != null);
    if (withProd.length) {
      const best = withProd.reduce((a, b) => (b.prod > a.prod ? b : a));
      facts.push(`Best solar day was ${shortDay(best.d)} at ${kwh(best.prod)} kWh.`);
    }
    if (facts.length) html += `<section class="card" style="gap:6px"><span style="font-weight:600;font-size:15px">This month</span><span class="small">${facts.map(esc).join(" ")}</span></section>`;
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
    if (r.self != null) rows += `<div class="row"><span>Solar used in the house</span><span class="val num">${kwh(r.self)} kWh</span></div>`;
    if (r.imp != null) rows += `<div class="row"><span>From grid</span><span class="val num">${kwh(r.imp)} kWh</span></div><div class="row"><span>Sent back</span><span class="val num">${kwh(r.exp)} kWh</span></div><div class="row"><span>Net from grid</span><span class="val ${r.home == null ? "strong" : ""} num">${signed(r.imp - r.exp)} kWh</span></div>`;
    if (!rows) rows = `<div class="row"><span class="val" style="text-align:left">No data for this day</span></div>`;

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
      <div class="list">${rows}</div>`;
  }

  function solarScreen() {
    const s = solar();
    if (!s) return `<h1>Solar</h1>
      <section class="card empty"><span class="big">${sunIcon}</span><h2>SolarEdge isn't connected</h2>
      <p class="small" style="margin:0">${state.data.connectUrl ? "Sign in with your SolarEdge account and approve access to turn this on." : "Add your SolarEdge app's client ID, client secret and site ID as repository secrets in GitHub, then run the workflow again."}</p>
      </section>${connectBtn()}${panelsLink()}`;

    const today = new Date().toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" });
    const pts = (s.todayCurve || []).map(([t, kw]) => { const [h, m] = t.split(":").map(Number); return [h + m / 60, kw]; });
    const peak = Math.max(...pts.map((p) => p[1]), 0.1) * 1.15;
    let curve = "";
    if (pts.some((p) => p[1] > 0)) {
      const X = (h) => ((h - 5) / 16) * 300, Y = (kw) => 110 - (kw / peak) * 100;
      const line = pts.filter((p) => p[0] >= 5 && p[0] <= 21).map((p) => `${X(p[0]).toFixed(1)},${Y(p[1]).toFixed(1)}`);
      curve = `<svg class="curve" viewBox="0 0 300 124" preserveAspectRatio="none" role="img" aria-label="Solar power through the day">
        <line x1="0" y1="110" x2="300" y2="110" stroke="var(--sep)"/>
        <polygon points="0,110 ${line.join(" ")} 300,110" fill="var(--solar)" fill-opacity=".14"/>
        <polyline points="${line.join(" ")}" fill="none" stroke="var(--solar)" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round"/>
      </svg><div class="axis"><span>6 am</span><span>Noon</span><span>6 pm</span></div>`;
    }
    const nowNote = s.nowKw > 0 ? "Producing now" : (new Date().getHours() >= 12 ? "After sunset" : "Before sunrise");
    const updated = s.updated ? new Date(s.updated).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : null;

    const stale = needsConnect() ? `<section class="card" style="gap:6px"><span style="font-weight:600;font-size:15px">SolarEdge needs you to sign in again</span><span class="small">These are the last numbers it sent. Reconnect to start updating again.</span></section>${connectBtn()}` : "";
    return `<div><div class="eyebrow">${esc(today)}</div><h1>Solar</h1></div>${stale}
      <section class="card">
        <div style="display:flex;justify-content:space-between;align-items:flex-end;gap:12px">
          <div style="display:flex;flex-direction:column;gap:6px"><span class="label">Produced today</span><div class="hero num"><b>${fmt(s.today, 1)}</b><span>kWh</span></div></div>
          <div style="display:flex;flex-direction:column;align-items:flex-end;gap:2px;padding-bottom:4px"><span class="small">Right now</span><span class="num" style="font-size:20px;font-weight:600">${fmt(s.nowKw, s.nowKw ? 2 : 0)} kW</span><span class="small">${s.nowKw > 0 ? "of " + fmt(s.peakKw, 2) + " kW peak" : nowNote}</span></div>
        </div>${curve}
      </section>
      <div class="list">
        <div class="row"><span>This month</span><span class="val num">${kwh(s.month)} kWh</span></div>
        <div class="row"><span>This year</span><span class="val num">${fmt(s.year)} kWh</span></div>
        <div class="row"><span>Since ${esc(s.installed ? new Date(s.installed + "T12:00").toLocaleDateString("en-US", { month: "long", year: "numeric" }) : "install")}</span><span class="val num">${fmt(s.lifetime)} kWh</span></div>
      </div>
      ${updated ? `<div class="foot">SolarEdge last reported ${esc(updated)}.</div>` : ""}
      ${panelsLink()}`;
  }

  function panelsLink() {
    const p = state.data.panels;
    if (!p) return "";
    const count = p.strings.reduce((a, s) => a + s.panels.length, 0);
    return `<a class="list row" href="#panels"><span>All ${count} panels</span><span style="display:flex;align-items:center;gap:8px"><span class="val small">${esc(shortDay(p.date))}</span>${chev}</span></a>`;
  }

  function panelsScreen() {
    const p = state.data.panels;
    if (!p) return `<a class="back" href="#solar"><svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg>Solar</a><h1>Panels</h1><p class="small">No panel data.</p>`;
    const all = p.strings.flatMap((s) => s.panels);
    const best = all.reduce((a, b) => (b[1] > a[1] ? b : a)), low = all.reduce((a, b) => (b[1] < a[1] ? b : a));
    const groups = p.strings.map((s) => {
      const sum = s.panels.reduce((a, x) => a + x[1], 0);
      const cells = s.panels.map(([id, wh]) => {
        const ring = id === best[0] ? "outline:2px solid var(--solar)" : id === low[0] ? "outline:2px solid var(--chev)" : "";
        return `<div class="panel" style="${ring}"><span class="id num">${esc(id)}</span><span class="wh num">${fmt(wh)}<small> Wh</small></span><span class="bar"><i style="width:${Math.round((wh / best[1]) * 100)}%"></i></span></div>`;
      }).join("");
      return `<div class="section" style="display:flex;justify-content:space-between"><span>${esc(s.name)}</span><span class="num">${fmt(sum / 1000, 2)} kWh · ${fmt(sum / s.panels.length)} Wh avg</span></div><div class="pgrid">${cells}</div>`;
    }).join("");
    return `<a class="back" href="#solar"><svg viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></svg>Solar</a>
      <div><h1>Panels</h1><span class="label">${esc(dayName(p.date))} · ${all.length} panels</span></div>
      ${groups}
      <div class="list">
        <div class="row"><span>Best</span><span class="val num">${esc(best[0])} · ${fmt(best[1])} Wh</span></div>
        <div class="row"><span>Lowest</span><span class="val num">${esc(low[0])} · ${fmt(low[1])} Wh</span></div>
      </div>
      <div class="foot">${esc(p.note || "")}</div>`;
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
      ${s && s.connected && !s.needsConnect ? "" : connectBtn()}
      <div class="foot">${s && s.connected && !s.needsConnect ? "Refreshes every hour during the day." + (s.error ? " The last refresh failed, so these are the previous numbers." : "") : state.data.connectUrl ? "You'll sign in with SolarEdge, then paste a one-time code into GitHub." : "Add SOLAREDGE_CLIENT_ID, SOLAREDGE_CLIENT_SECRET, SOLAREDGE_SITE_ID and GH_PAT under Settings, Secrets and variables, Actions in your GitHub repository."}</div>
      <div class="section">Grid meter</div>
      <div class="list">
        <div class="row" style="justify-content:flex-start"><span class="icon" style="background:var(--grid)">${boltIcon}</span><span>Toronto Hydro</span></div>
        ${h.length ? `<div class="row"><span>Data</span><span class="val num">${esc(shortDay(h[0]))} to ${esc(shortDay(h.at(-1)))}, ${parseDay(h.at(-1)).getFullYear()}</span></div><div class="row"><span>Days</span><span class="val num">${h.length}</span></div>` : `<div class="row"><span>Data</span><span class="val">None yet</span></div>`}
      </div>
      <div class="foot">To add a month, download it from MyTorontoHydro and upload the file to the data/hydro folder in GitHub. The site rebuilds on its own.</div>
      <div class="foot" style="margin-top:0">Built ${esc(new Date(d.generated).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }))}.</div>`;
  }

  // ---------- routing ----------
  const screens = { overview, days: daysScreen, solar: solarScreen, panels: panelsScreen, sources: sourcesScreen };

  function render() {
    const route = (location.hash.slice(1) || "overview");
    const screen = screens[route] ? route : "overview";
    view.innerHTML = screens[screen]();
    const tab = screen === "panels" ? "solar" : screen;
    document.querySelectorAll(".tabs a").forEach((a) => { if (a.dataset.tab === tab) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current"); });
    document.title = (screen[0].toUpperCase() + screen.slice(1)) + " · Home Solar";
  }

  view.addEventListener("click", (e) => {
    const m = e.target.closest("[data-month]");
    if (m && !m.disabled) { state.month = months()[Number(m.dataset.month)]; state.day = null; render(); return; }
    const v = e.target.closest("[data-view]");
    if (v) { state.view = v.dataset.view; render(); return; }
    const d = e.target.closest("[data-day]");
    if (d) { state.day = d.dataset.day; render(); }
  });
  window.addEventListener("hashchange", () => { render(); window.scrollTo(0, 0); });

  view.innerHTML = '<p class="loading">Loading…</p>';
  fetch("data.json", { cache: "no-store" })
    .then((r) => { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then((data) => { state.data = data; state.month = defaultMonth(); render(); })
    .catch(() => { view.innerHTML = '<h1>Home Solar</h1><p class="small">Couldn\'t load data.json. If you opened index.html straight from your computer, run the build and serve the _site folder instead.</p>'; });
})();
