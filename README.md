# Scata

Safe, sustainable school commutes. A web app where schools invite parents, and parents share the school run.

The whole app is `index.html` (Preact + htm, no build step). `config.js` holds the Google Maps browser key. Without a key, the app shows drawn maps instead of Google Maps.

The site publishes to GitHub Pages on every push to `main` (`.github/workflows/pages.yml`).

Data is still stored in each visitor's browser, and the other parents are simulated. A shared database and real logins are the next step.

## Editing

Edit `src/app.html`, then run `sh build.sh` to regenerate `index.html`.
