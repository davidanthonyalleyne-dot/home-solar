# Overview document

`overview.html` describes what Solar does in two pages with screenshots, plus a Technical setup page, printed to `overview.pdf`.
The footer shows the document version (raise it with each update: 2.0, 2.1 …) and the app version (1.N, `git rev-list --count HEAD -- web`).
Update it whenever a feature is added, changed or removed.

1. `python3 docs/overview/fake_data.py <real data.json> <sample.json>`: scales and jitters every energy and money figure, so
   no real numbers appear. Put the result (or a copy encrypted with the passphrase `sample`) in a built copy of `web/`.
2. `node docs/overview/shoot.js <site folder>`: takes the screenshots in `shots/` from that copy, including a sample Ask conversation

3. Edit `overview.html`: the captions, sections, the at-a-glance figures, Technical setup, the versions and the "Updated" date.
4. `node docs/overview/pdf.js`: writes `overview.pdf`. Two feature pages and one Technical setup page.
5. Upload the PDF to the "App overviews" folder in Google Drive, replacing the old copy.

Published copy (republish to the same link after each update): https://claude.ai/artifact/48ogWu2WLngeqwKcrz2RTA
