# ADR-0013 — Android entry options (APK host, WebView + wasm, EGL)

Status: accepted
Date: 2026-09-24

## Context

The portable core (`GameEngine`, board, SUD0 codec, wasm `exec` + JSON wire — ADR-0010) is intentionally UI-agnostic. Deployments today:

- **Native terminal** — `Sudoku` + blocking AsciiRenderer + `FileTransport` (ADR-0011).
- **Desktop web** — embedded `artifact.wasm` + JS shell; loopback static host (`src/web_host/`, `-r web`).

Android is a plausible **third thin entry**, not a fork of game logic. Community patterns fall into three buckets:

1. **Gradle + Kotlin/JNI** — JVM owns Activity and UI; Zig builds to `.so` with `Java_*` exports (e.g. [ZigOnAndroid](https://github.com/davthecodercom/ZigOnAndroid)).
2. **Zig-driven APK, minimal or no app Java** — cross-compile for Android ABIs; package/sign/install from `build.zig` (Android SDK + NDK + `jarsigner`; see [ZigAndroidTemplate](https://github.com/ikskuh/ZigAndroidTemplate), [Ziggit discussion](https://ziggit.dev/t/zig-android/4997), lineage [rawdrawandroid](https://github.com/cnlohr/rawdrawandroid)). Examples include pure **EGL/GLES** UI, or **TextView/Button via JNI** when needed.
3. **Reuse the web shell on device** — a native **host** serves the same `page.html` / JS / wasm over **loopback HTTP** and displays it in **WebView** (Chromium-derived on device, not “Chrome the app”). Desktop already proves the artifact graph via **`web_host`** + embedded bytes.

ADR-0011’s **sibling-entry test** applies: Android must not duplicate engine rules or SUD0 parsing; it adds lifecycle, I/O, and presentation only.

## Decision

**Default Android path:** Zig-driven APK (no Gradle/AGP), **`web_host`** loopback + WebView + existing JS/wasm shell. Shared loopback code lives in **`src/web_host/`** (shipped for desktop `-r web`); **`src/android/`** platform entry and packaging are implemented separately.

### Default (when pursued)

**Zig-driven APK — no Gradle — wasm host + WebView + existing web shell**

The Android **shell** is a thin native **host**: process lifecycle, loopback static server, WebView, permissions, and whatever minimal **JNI + Java bootstrap** the framework requires to create an Activity and WebView. Gameplay UI stays the shipped **JS shell** + wasm inside WebView (ADR-0010). There is **no Gradle/AGP project** and no Kotlin app layer unless a future issue explicitly chooses the alternative below.


| Layer                        | Responsibility                                                                                                                                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `build.zig` (Android target) | Sole packaging orchestrator: SDK/NDK invoke, multi-ABI `.so`, manifest/resources, dex for bootstrap classes if any, sign, `adb` install — pattern from [ZigAndroidTemplate](https://github.com/ikskuh/ZigAndroidTemplate) |
| Host (Zig `.so` + JNI)       | Link **`web_host`** — bind `127.0.0.1:<port>`, same routes/MIME as desktop; lifecycle via JNI `startHost` / `stopHost`                                                                                                      |
| Minimal Java/DEX bootstrap   | Only what WebView/Activity need (small compiled surface, not an app codebase)                                                                                                                                             |
| WebView                      | Load `http://127.0.0.1:<port>/`; no duplicate DOM or menubar in native code                                                                                                                                               |
| `wasm_entry` + JS            | Unchanged contract (ADR-0010); session file I/O on device via shell/JS like web                                                                                                                                           |


Rationale: reuses shipped wasm/JS UI; matches “UI-agnostic engine + thin entry”; keeps build aligned with the rest of the repo; avoids EGL widget work for v1.

### Alternatives (explicit, not default)


| Path                                                                                                              | When                                                                    | Cost                                             |
| ----------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------ |
| **Gradle + Kotlin shell**                                                                                         | Explicit opt-in: Play-store polish, Compose chrome, deep OS integration | Gradle/AGP project; JVM-owned UI; Zig as library |
| **EGL / pure native draw** ([ZigAndroidTemplate](https://github.com/ikskuh/ZigAndroidTemplate) `egl`)             | Mobile UI distinct from web; max control                                | New renderer; no wasm reuse on screen            |
| **JNI widgets only for shell** ([`textview` / `invocationhandler`](https://github.com/ikskuh/ZigAndroidTemplate)) | Tiny native chrome around a canvas/WebView                              | Hybrid JNI surface                               |




### Placement rules (ADR-0011)

- **Engine / wasm module** — no Android SDK types, no `ANativeWindow` in core.
- **Android host** — process lifecycle, HTTP server thread, WebView (or EGL context), cleartext localhost policy, permissions.
- **Session file I/O on device** — shell/JS (same as web FS Access gap today); not new engine APIs without an issue.



### Android packaging facts (non-negotiable)

- An **APK/AAB** still requires SDK, NDK, signing (`jarsigner` or `apksigner`, etc.) — **no Gradle** means no AGP project tree, not zero JDK/SDK tooling.
- **No Gradle ≠ no DEX** — WebView still needs framework entry (minimal Java bootstrap and/or JNI); that is not a second UI stack.
- **Cleartext HTTP** to localhost may require network security config for WebView on recent API levels.



## Consequences

- **`web_host`** is the shared loopback layer for desktop web and Android; do not fork HTTP routes or embed tables per platform.
- Keep ADR-0011’s **N-entry** list current (native terminal, desktop web, Android host) without moving state into `GameEngine`.
- EGL-native Android UI remains valid but is a **separate product bet** — do not block wasm-host path on it.
- Default build/sign reference: [ZigAndroidTemplate](https://github.com/ikskuh/ZigAndroidTemplate). Gradle+JNI reference only if the Kotlin path is opened: [ZigOnAndroid](https://github.com/davthecodercom/ZigOnAndroid).

