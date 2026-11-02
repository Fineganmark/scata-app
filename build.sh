#!/bin/sh
# Wraps the single-file app (src/app.html) into the hosted website (index.html).
# The hosted page also loads config.js, which holds the Google Maps browser key.
D=$(dirname "$0")
{ printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n<link rel="icon" type="image/png" sizes="32x32" href="icons/favicon-32.png">\n<link rel="icon" type="image/png" sizes="192x192" href="icons/icon-192.png">\n<link rel="apple-touch-icon" href="icons/apple-touch-icon.png">\n<link rel="manifest" href="manifest.json">\n<meta name="apple-mobile-web-app-title" content="Scata">\n<meta name="theme-color" content="#ffffff">\n<script src="config.js"></script>\n</head>\n<body>\n'
  cat "$D/src/app.html"
  printf '\n</body>\n</html>\n'; } > "$D/index.html"
