# Android device suite on a headless agent emulator

`develop` `33611bb` + the fix below, `ANDROID_SERIAL=emulator-5556`, 2026-11-15.

## Outcome

Full suite: **OK (23 tests)**, 500.8 s, including #132's
`aRefusedSettingsFileIsReportedWhenTheBootFailsNotAfterTheReadinessTimeout`.

One test, `picksThatTakeOverAMinuteSaveAndOpenThePickedFile`, is **not self-contained** and failed whenever the
device had no save folder. Fixed in the test, verified on a clean device.

## The defect

The test copies its save into the app's default folder and then opens the file picker expecting to see it:

```java
sh("cp '" + chosenPath + "' " + DEFAULT_PATH + "\n");   // /sdcard/Download/Sudoku/sudoku.sud
…
final UiObject2 listed = needPickerItem(DEFAULT_NAME);  // 20 s budget
```

On a clean device `/sdcard/Download/Sudoku` does not exist, so:

1. the `cp` has no destination directory and fails, unchecked;
2. the app's picker `startIn` hint cannot resolve, so DocumentsUI opens at Downloads root — the failure
   hierarchy shows `FILES IN DOWNLOADS` with only `bridge-test.sud` and no `Sudoku` folder at all;
3. the 20 s wait for `sudoku.sud` expires on a file that was never created.

It passes inside a full suite only because an earlier test's save creates the folder. The sibling test at
`FileBridgeTest.java:552` already opens with `sh("mkdir -p " + SAVE_DIR …)`; this one did not.

**Not timing, not order.** Proven both ways: with the folder absent it fails every time (101 s, twice
back-to-back on a warm device, so the "cold documentsui" theory is dead); after `mkdir -p` by hand it passed,
then failed again once the folder was removed. It also killed the MediaStore-scan theory: the picker lists the
filesystem, so a freshly copied file appears without any indexing wait.

Fix: one line of setup in the test (`mkdir -p SAVE_DIR`), then it passed from a genuinely empty `Download`
in 145.8 s.

## Agent's emulator (the developer's own AVD is never touched)

```
./scripts/android-emulator-start.sh     # AVD Agent_API_30, port 5556, headless, waits for boot (18 s)
./scripts/android-emulator-stop.sh      # adb emu kill, waits until adb drops the serial (2 s)
```

`Agent_API_30` is a copy of `Small_Phone` (android-30 `google_apis_playstore`, x86_64); the APK carries
`lib/arm64-v8a` and `lib/x86_64`, so an x86_64 emulator runs it. The start script refuses when a device is
already connected, because `scripts/android-test.sh` requires exactly one.

## Speed, and a caveat about verify

Software rendering costs: the full suite takes 500.8 s where the docs say "about two minutes", and the script
kills a run at 600 s. With the emulator running, `zig build verify` measured 18.09 s against an 18.0 s budget
and failed; with it stopped, 12.30 s and passed. An emulator left up skews the verify gate.

## Leftovers

- The suite leaves `bridge-test.sud` behind: the end-of-run restore only manages `sudoku.sud` / `sudoku (N).sud`.
- A failing run leaves `zig-out/android-test/failure/*.xml|png` — the window hierarchy is what identified this.
