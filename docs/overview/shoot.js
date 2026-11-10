// Screenshots for the overview document.
//   node docs/overview/shoot.js <site folder with data.json> [iso time]
// The site folder is a built copy of web/ with an unencrypted sample data.json, so no
// passphrase is needed and nothing private ends up in the pictures by accident.
const { chromium } = require("playwright");
const http = require("http"), fs = require("fs"), path = require("path");
const site = path.resolve(process.argv[2] || "_site"), when = process.argv[3] || "2026-11-06T10:35:00-05:00";
const out = path.join(__dirname, "shots");
const types = { ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".html": "text/html", ".svg": "image/svg+xml", ".png": "image/png" };
const server = http.createServer((q, r) => {
  let f = path.join(site, decodeURIComponent(q.url.split("?")[0]));
  if (f.endsWith("/")) f += "index.html";
  fs.readFile(f, (e, b) => { if (e) { r.writeHead(404); return r.end(); } r.writeHead(200, { "Content-Type": types[path.extname(f)] || "application/octet-stream" }); r.end(b); });
}).listen(0, async () => {
  const url = `http://127.0.0.1:${server.address().port}/`;
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  await p.clock.install({ time: new Date(when) });
  // a sample Ask conversation (made-up figures), kept where the app keeps conversations
  await p.addInitScript(() => {
    const msgs = [
      { role: "user", text: "Why was October more expensive than September?" },
      { role: "assistant", text: "**October cost $186, $41 more than September.** The house drew 23% more from the grid once the first cold week arrived, and the panels made less, 410 kWh against 540.\n\n```chart\n{\"series\":[\"Grid\",\"Solar\"],\"rows\":[[\"Sep\",1150,540],[\"Oct\",1420,410]]}\n```\n\nThe 17th was the heaviest day, at 64 kWh, with a low of −4°C.\nFrom your September and October bills and meter data" },
      { role: "user", text: "Will tomorrow be a good day for solar?" },
      { role: "assistant", text: "**Fairly good, about 9 kWh.** Mostly sunny until mid-afternoon, when cloud moves in, with a high of 7°C. That's a forecast, so it could shift.\nFrom the forecast for tomorrow" },
    ];
    try { localStorage.setItem("askCurrent", JSON.stringify("sample")); localStorage.setItem("askChats", JSON.stringify([{ id: "sample", started: "2026-11-06T15:20:00Z", updated: "2026-11-06T15:30:00Z", msgs }])); } catch (_) {}
  });
  // a sample data.json may be encrypted with the passphrase "sample", to show the parts that need it
  await p.goto(url); await p.waitForTimeout(700);
  if (await p.locator("#pass").count()) {
    await p.fill("#pass", "sample"); await p.click("button[type=submit]"); await p.waitForTimeout(2500);
    for (let i = 0; i < 2; i++) { const s = p.locator("#skip"); if (await s.count()) { await s.click(); await p.waitForTimeout(300); } }
  }
  const shot = async (name, hash, before) => {
    await p.evaluate((h) => { location.hash = h; }, hash); await p.waitForTimeout(700);
    if (before) { await before(); await p.waitForTimeout(400); }
    await p.screenshot({ path: path.join(out, name + ".png") });
  };
  await shot("now", "now");
  const ym = new Date(new Date(when).getTime() - 32 * 864e5).toISOString().slice(0, 7);  // a finished month
  const lastMonth = async () => { const c = p.locator(`[data-ym="${ym}"]`).first(); if (await c.count()) await c.click({ force: true }); };
  await shot("month", "month", lastMonth);
  await shot("history", "history");
  await shot("energy", "history", async () => p.click('[data-hview="energy"]'));
  await shot("bill", "month", async () => { await lastMonth(); await p.waitForTimeout(300); const l = p.locator('[data-sheet="bill"]'); if (await l.count()) await l.first().click(); });
  await shot("settings", "settings", async () => p.evaluate(() => { const s = [...document.querySelectorAll(".group-label")].find((x) => x.textContent === "Toronto Hydro"); if (s) s.scrollIntoView(); }));
  await shot("ask", "ask");
  await b.close(); server.close();
  console.log("shots saved in", out);
});
