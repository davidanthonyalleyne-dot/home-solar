# Home Solar

A small web app for 58 Spencer that puts SolarEdge production next to Toronto Hydro meter data. It runs on GitHub Pages. A GitHub Action rebuilds it every hour, pulls fresh numbers from the SolarEdge Monitoring API (V2), and reads whatever Toronto Hydro exports are in `data/hydro/`.

No SolarEdge credential is ever written to the site. They live in GitHub's encrypted secrets, and only the resulting numbers are published.

## Setup

### 1. Create the repository and turn on Pages

On github.com click New repository, name it `home-solar`, and leave it empty (no README, no .gitignore). Pages is free on public repositories. A private one needs a paid plan.

In the repo go to Settings, then Pages, and under Build and deployment set Source to **GitHub Actions**.

### 2. Register the app with SolarEdge

At developer.solaredge.com create an application with Service **Monitoring API** and access type **Site Access**, with the SITE_DATA and DEVICE_DATA scopes.

- Allowed Origin URL: `https://YOUR-USERNAME.github.io`
- Allowed Redirect URL: label `Home Solar`, URL `https://YOUR-USERNAME.github.io/home-solar/callback.html`, set as Default
- Allowed Returned URL: leave empty

Copy the Client ID and Client Secret when you submit. The secret is only shown once.

### 3. Make a GitHub token so the app can save its SolarEdge sign-in

SolarEdge hands out a new refresh token every time the app uses one, so each build has to save the new one back to your secrets. That needs a token with permission to write secrets on this one repo.

On GitHub open your profile menu, then Settings, Developer settings, Personal access tokens, **Fine-grained tokens**, and Generate new token. Name it `home-solar`, choose the longest expiry you're comfortable with, set Repository access to **Only select repositories** and pick `home-solar`. Under Repository permissions set **Secrets** to **Read and write**. Generate it and copy it.

### 4. Add four secrets

In the repo go to Settings, then Secrets and variables, then Actions, and add each one with New repository secret:

| Name | Value |
|---|---|
| `SOLAREDGE_CLIENT_ID` | from step 2 |
| `SOLAREDGE_CLIENT_SECRET` | from step 2 |
| `SOLAREDGE_SITE_ID` | `3877805` |
| `GH_PAT` | the token from step 3 |

### 5. Upload the files

On the repo's main page click "uploading an existing file", drag in everything inside this folder, and commit. On a Mac, Finder hides the `.github` folder, so press Cmd+Shift+. in that Finder window first. Without it nothing gets built.

The Actions tab shows **Build and deploy** running. When it turns green the site is live at `https://YOUR-USERNAME.github.io/home-solar/`, with Toronto Hydro data only for now. If the first run fails because Pages wasn't on yet, open it and click Re-run all jobs.

### 6. Connect SolarEdge (once)

1. Open the site, go to **Sources** and tap **Connect SolarEdge**.
2. Sign in with your mySolarEdge account and approve access.
3. SolarEdge sends you back to the site's callback page, which shows a one-time code. Tap **Copy code**, then **Open the workflow**.
4. In GitHub tap **Run workflow**, paste the code and run it. Do this within a few minutes, because the code expires.

When it turns green it saves the sign-in as `SOLAREDGE_REFRESH_TOKEN` and rebuilds the site with your solar data.

### 7. Put it on your phone

Open the site in Safari, tap Share, then Add to Home Screen.

## Lock the app

Add a repository secret called `SITE_PASSPHRASE` (Settings, Secrets and variables, Actions). From the next build, everything the site publishes is encrypted (AES-256-GCM, key derived from the passphrase), so data.json is unreadable without it. The app asks for the passphrase once on each device, then offers Face ID through a passkey, or to stay unlocked on that device if it can't use Face ID for this. Use four or more random words, because anyone can download the encrypted file and try guesses offline. Changing the passphrase locks every device until it's entered again, and the next build reloads the full history.

## Adding Toronto Hydro data

Download a month from MyTorontoHydro (the daily "Trending Report" export works; hourly works too). In GitHub open `data/hydro`, click Add file, then Upload files, and drop it in. The site rebuilds on its own within a couple of minutes. Overlapping files are fine because readings are matched by timestamp.

## If SolarEdge stops updating

The Sources screen will say the sign-in expired and show **Connect SolarEdge** again. Repeat step 6. That happens if access goes unused for about 30 days, when the 24-month approval runs out, if your GitHub token from step 3 expires, or if a build couldn't save the new token. In that last case GitHub emails you that the run failed.

## Good to know

- **API credits.** SolarEdge's free tier allows about 2,000 calls a month and 10 a minute. Each daytime build makes one call for today's production. Once a day it makes three more for the daily history, lifetime total and site details. Scheduled builds skip SolarEdge from 10 pm to 5 am. That comes to roughly 600 calls a month. The very first build can use up to a dozen extra while it loads a year of history.
- **History.** Daily production goes back to the first day SolarEdge recorded (August 28, 2023), and weather to July 2023. It was loaded once, a month per call, and only new days are fetched after that.
- **Builds reuse the last data.** Each build reads the previously published `data.json` and only fetches what changed.
- **Public repo.** Anyone with the link can see the dashboard and the files in `data/`, including the meter number inside the Toronto Hydro export. The page is marked noindex, and no credential is exposed.
- **Scheduled runs pause.** GitHub pauses schedules in a repo with no commits for 60 days. Uploading a hydro file each month keeps it running. You can refresh any time from Actions, Build and deploy, Run workflow.

## Preview on your computer

```sh
pip install openpyxl
python3 scripts/build.py
python3 -m http.server -d _site 8000
```

Then open http://localhost:8000. Locally it builds with Toronto Hydro data only, because the SolarEdge sign-in lives in GitHub.
