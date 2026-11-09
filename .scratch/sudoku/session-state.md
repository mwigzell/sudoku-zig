# Session state — #127

Updated: 2026-11-09. HITL: stopped after one red→green cycle, awaiting direction.

## Issue

GitHub **#127** — `Android: portrait-only play, and an opaque menubar` (`enhancement`, `ready-for-agent`, agent brief posted).
Two changes, two slices. **Both slices done; cycle complete, uncommitted.**

## Slice A — opaque menubar (DONE)

- RED: `src/wasm/menus/menu_bar.test.mjs` — new block asserts the `#menu-bar` rule in `page.html` declares a non-transparent `background` (reads `page.html` as text, the seam the file already uses). Failed with `#menu-bar declares a background`.
- GREEN: `src/wasm/artifacts/page.html` — added `background: var(--page-bg);` plus a one-line comment inside `#menu-bar`.
- Gate: `zig build verify` green — 646 passed, 2 skipped, 0 failed; `menu_bar.test.mjs OK`; coverage 89.84%; timing 11.14s vs 15.0s budget.
- **Uncommitted**: `src/wasm/artifacts/page.html`, `src/wasm/menus/menu_bar.test.mjs`.

## Slice B — portrait lock on Android (DONE, no test by owner's call)

- `src/android/bootstrap/AndroidManifest.xml`: `android:screenOrientation="portrait"` on the main activity. `src/android/test/AndroidManifest.xml` and `configChanges` untouched.
- Owner chose **no automated test** (option C): the manifest line plus manual device proof.
- Proof on device `8aa2f03a`: before the change, `adb shell cmd window user-rotation lock 1` rotated the display (`cur=2400x1080`); after, the same command leaves it at `cur=1080x2400`, portrait.
- `zig build android` + `adb install -r` fine; `zig build verify` still green (646 passed, 2 skipped).

## Context worth keeping

- The reported misalignment was **not reproducible** from any artifact (Nov 8 release bundle embeds a `page.html` byte-identical to main; Debug and ReleaseSmall builds also clean; cold launch through Auto New, resume, rotation, landscape scroll all clean). Recorded as background in the issue.
- Verified latent defects: `#menu-bar` was transparent (fixed here), and `position: sticky` does not pin the menubar in the WebView (Chromium does) — portrait lock removes the landscape scroll path; the sticky difference is unaddressed.
- Device `8aa2f03a` currently runs the release-bundle APK from `zig-out/android-bundle/sudoku.aab`; rotation left on auto.
