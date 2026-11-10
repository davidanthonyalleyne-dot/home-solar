// Prints overview.html to overview.pdf (two Letter pages) and a PNG of each page.
//   node docs/overview/pdf.js
const { chromium } = require("playwright");
const path = require("path");
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 816, height: 1056 }, deviceScaleFactor: 2 });
  await p.goto("file://" + path.join(__dirname, "overview.html"));
  await p.waitForTimeout(500);
  await p.emulateMedia({ media: "print" });
  await p.pdf({ path: path.join(__dirname, "overview.pdf"), format: "Letter", printBackground: true, margin: { top: 0, right: 0, bottom: 0, left: 0 } });
  await b.close();
  console.log("wrote overview.pdf");
})();
