# Ask tab (Gemini solar agent) — plan, not built yet

Agreed with David on Nov 9–10, 2026. Mockup: `ask-tab-mockup.png` (sample numbers), source `ask-tab-mockup.html`.

## What David asked for
- A Gemini-powered solar agent that knows everything in the app: daily production, Toronto Hydro meter readings, bills, costs and savings, weather (Open-Meteo) and equipment.
- Its own fourth tab, **Ask**, next to Now, Month and History. Not a button on every screen.
- **Tap to talk**: a mic button, the question is transcribed, the answer is read aloud. Not a live back-and-forth conversation.
- Suggested questions to start, e.g. "How much did solar save me this year?", "Is this November worse than last year?", "Which month made the most?", "Why was my last bill higher?"
- Gemini **paid tier** (on the free tier Google may keep and review prompts). No monthly fee; roughly 1–3 cents a question, about double after the Jan 1, 2027 price change, so ~$1–3/month at his use.

## How to build it
- David creates a Gemini API key in Google AI Studio, turns on billing, restricts the key to the Gemini API in Google Cloud and sets a ~$5 budget alert.
- The key never goes in the repo (the site is public). He pastes it once in Settings; it is stored on the phone wrapped by the same lock as data.json (passphrase / Face ID passkey, see `web/lock.js`).
- On a question, the phone sends the question plus a compact summary of the decrypted data straight to the Gemini API (Flash). Nothing passes through GitHub.
- Voice uses Safari's built-in speech recognition (`webkitSpeechRecognition`) and `speechSynthesis`: free, no extra service.
- Optional later: a small Cloudflare Worker proxy so the key never sits on the phone.
- When built, update `docs/overview` (screenshots, Technical setup).

## Waiting on
- David's Gemini API key (paid tier).
