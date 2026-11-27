# Two-line text → one line (saved Nov 27, 2026, not implemented)

David asked to keep these suggestions for later. Mockup canvas: "Solar: two-line text to one line"
(https://claude.ai/artifact/MV9TiTKDRXRY1xWHDw4gLF). Each line below is where it shows, what it says now, and the one-line version.
These texts are in both the iPhone app (ios/Solar) and the web app (web/app.js) unless noted.

## Month and History
| Where | Now | One line |
|---|---|---|
| Month › What changed | Home use rose 43% on September, to 36 kWh a day. Heating has started. | Home use up 43%: heating has started. |
| Month › What changed | Solar covered 21% of the house, down from 30%. | Solar covered 21% of use, down from 30%. |
| Month › What changed | Overall your solar output matched the available sunshine. Oct 11 underperformed. | Matched the sunshine, except Oct 11. |
| History › Cost, under the totals | Solar has taken about 22% off what power would have cost. | Solar cut about 22% off power costs. |
| History › Cost, chart label | Cost each month, from the grid and saved by solar. Same scale every year. | Paid to the grid and saved by solar, each month. |
| History › Energy, chart label | kWh generated each month, with the year's total. Same scale every year. | kWh generated each month, with yearly totals. |

The "What changed" lines are written from data (numbers and dates change), so the change is to their templates.

## Settings pages
| Where | Now | One line |
|---|---|---|
| SolarEdge › status line | Everything is working. New numbers come in through the day. | Everything is working. |
| SolarEdge › System alerts, value | None, checked November 6, 10:13 am | None · Nov 6, 10:13 am |
| Solar system › Panels, value | 17 × LONGi LR4-72HPH-455M, 455 W | 17 × LONGi 455 W |
| Solar system › Optimizers, value | 17 × SolarEdge S500B, one per panel | 17 × SolarEdge S500B |
| Export data › column switch | Grid: bought, sent back, used at home | Grid in, out and home use |
| Export data › under the columns | Bills are monthly, so with one row per day they go on a second sheet. | Bills go on a second sheet when rows are days. |
| Alerts › Production or inverter problems | No output on a sunny day, a fault, a SolarEdge alert | No output, faults, SolarEdge alerts |
| Alerts › No live data | SolarEdge stops sending numbers for a couple of hours | SolarEdge quiet for 2+ hours |
| Alerts › Bills and meter files | When a file you added is in, or couldn't be read | When an added file is in or fails |
| Alerts › Monthly summary | On the 1st: what solar made, what you paid and saved | On the 1st: made, paid and saved |
| Alerts › Winter use | A day when the house used far more than usual, and how cold it was | Heavy-use days and how cold it was |
| Security › under Forget the passphrase | Solar will ask for it again the next time it opens. The widgets stay empty until then. | Solar asks again next open; widgets wait till then. |

The full model names (LONGi LR4-72HPH-455M) can stay in the warranty details if the short panel value is used.

## Day sheet (ecobee day view)
| Where | Now | One line |
|---|---|---|
| Inside the house, caption | The dashed line is what the thermostat was set to; the solid line is the actual temperature inside. | Dashed: thermostat setting. Solid: actual. |
| What the panels made, caption | 13.4 kWh between 8 am and 5 pm; 3.8 kWh of it went to heating. | 13.4 kWh, 8 am to 5 pm; 3.8 went to heat. |

Left as they are: text of three or more lines (longer Settings footers, the heating caption, the day's notes).
