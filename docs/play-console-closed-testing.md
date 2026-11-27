# Play Console closed testing — publishing workflow memo

Hard-won notes on how Google Play Console's closed-testing release flow actually works.
The console gives no guided order and no explanation of these rules; this memo is the map.

## The rules (learned the hard way)

1. **Every change to a release is part of that release bundle.** This includes the
   country/region list — countries are not a separate setting, they are baked into the
   release. "Add Mexico/Canada" is not a tweak; it is a new release.

2. **The release bundle must be submitted for review.** No change takes effect until the
   bundle goes through review and is published. Until then, testers in newly-added
   countries see "item not available" even though the track summary lists them as
   "Targeted".

3. **The previous draft release must be discarded first.** A lingering draft blocks the
   new release. You cannot stack a new release on top of an old draft.

4. **There is no predefined order.** The menu system is "walk up and use" — you navigate
   it, it does not navigate you. Nothing tells you the sequence.

5. **"Go to Publishing" is where "submit for review" lives.** After each change the
   console pops a "Go to Publishing" dialog you can opt out of. Opting out is correct
   while you still have more changes to make — but the submit step only happens when you
   finally *accept* it. It is the exit, disguised as an optional dialog.

## The sequence

1. Discard the old draft release.
2. Make all changes (version bump, country list, etc.).
3. When done with changes, accept "Go to Publishing" → submit for review.
4. Wait for review → published → testers in the new countries can install.

## Timing

- After first publishing a test, the test link can take several hours to become available.
- Additional changes can also take several hours to become available.
- The opt-in link only appears when the app status is "Published" (not Draft or Pending).

## The 12-tester requirement (for personal accounts created after 2023-11-13)

- Must run a closed test with **12+ testers opted in continuously for 14 days** before
  applying for production access.
- Testers must remain opted in for the full period — tell them not to uninstall.
- After the 14 days, apply for production access on the Dashboard; review takes ~7 days.

## Tester onboarding (what worked)

- Testers join the Google Group first (the group is the tester source).
- On-device: group join → "Join on Android" link → install. Two steps, no separate opt-in.
- The group URL is `https://groups.google.com/g/sudoku-zig-testing`.

## Version bumping

- Version lives in `src/core/version.zig` (`major`/`minor`/`patch`).
- Version code = `major*10000 + minor*100 + patch`.
- Each release needs a higher version code than the last.
- Build the signed AAB with `zig build android-bundle` (needs `ANDROID_RELEASE_KEYSTORE`
  and the pass env vars), then copy `zig-out/android-bundle/sudoku.aab` into
  `.releases/` with the version in the name (e.g. `sudoku-0.1.1.aab`).
