# Branding Asset Map

Canonical source artwork:

- `docs/assets/sudoku-gator-icon-master.png` — original 1024x1024 master image.

Derived transparent master:

- `src/wasm/artifacts/branding/sudoku-gator-icon-transparent-1024.png` — white edge-connected background removed; base for platform variants.

Web-hosted branding assets:

- `src/wasm/artifacts/branding/favicon-16x16.png`
- `src/wasm/artifacts/branding/favicon-32x32.png`
- `src/wasm/artifacts/branding/apple-touch-icon.png`
- `src/wasm/artifacts/branding/android-chrome-192x192.png`
- `src/wasm/artifacts/branding/android-chrome-512x512.png`
- `src/wasm/artifacts/branding/splash-mark-256.png` — boot splash mark.
- `src/wasm/artifacts/branding/about-variant-96.png` — About artwork variant.
- `src/wasm/artifacts/site.webmanifest` — web app manifest referencing platform icon sizes.

Android launcher and splash resources:

- `src/android/bootstrap/res/mipmap-*/ic_launcher.png`
- `src/android/bootstrap/res/mipmap-*/ic_launcher_round.png`
- `src/android/bootstrap/res/drawable/splash_logo.png`
- `src/android/bootstrap/res/drawable/splash_background.xml`
- `src/android/bootstrap/res/values/styles.xml`

Integration points:

- Web icon/splash/about links are declared in `src/wasm/artifacts/page.html`.
- Loopback asset routing is in `src/web_host/router.zig` and `src/web_host/embed.zig`.
- Android icon and theme wiring is in `src/android/bootstrap/AndroidManifest.xml`.
