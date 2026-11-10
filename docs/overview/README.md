# Overview document

`overview.html` is a two-page description of what Solar does, with screenshots, printed to `overview.pdf`.
Update it whenever a feature is added, changed or removed.

1. `python3 docs/overview/fake_data.py <real data.json> <sample.json>`: scales and jitters every energy and money figure, so
   no real numbers appear. Put the result (or a copy encrypted with the passphrase `sample`) in a built copy of `web/`.
2. `node docs/overview/shoot.js <site folder>`: takes the screenshots in `shots/` from that copy

3. Edit `overview.html`: the captions, sections, the at-a-glance figures and the "Updated" date.
4. `node docs/overview/pdf.js`: writes `overview.pdf`. It must stay at two Letter pages.

Published copy (republish to the same link after each update): https://claude.ai/artifact/48ogWu2WLngeqwKcrz2RTA
