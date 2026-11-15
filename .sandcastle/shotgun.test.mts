// shotgun.test.mts — the file count in the standards lens is the host's number, not the reviewer's claim.

import test from "node:test";
import assert from "node:assert/strict";
import { countShotgun, rgSearch, PLUMBING_FILES } from "./shotgun.mts";

/** A search that answers from a fixed map, so these tests never touch the filesystem. */
const searchOver =
  (files: Record<string, string[]>) =>
  (symbol: string): string[] =>
    files[symbol] ?? [];

test("the host's count replaces the reviewer's figure", () => {
  const counts = countShotgun(
    [{ symbol: "dataDir", files: 99 }],
    searchOver({ dataDir: ["src/a.zig", "src/b.zig", "src/c.zig"] }),
  );

  assert.deepEqual(counts, { counts: [{ symbol: "dataDir", files: 3, verdict: "plumbing" }] });
});

test("a symbol carried through fewer files is counted as carried, not plumbing", () => {
  const counts = countShotgun([{ symbol: "theme", files: 2 }], searchOver({ theme: ["src/a.zig", "src/b.zig"] }));

  assert.deepEqual(counts, { counts: [{ symbol: "theme", files: 2, verdict: "carried" }] });
  assert.ok(PLUMBING_FILES > 2, "the plumbing threshold is above a plain two-file carry");
});

test("a symbol the branch does not have is a stop: the report named something invented", () => {
  const counts = countShotgun([{ symbol: "ghost", files: 4 }], searchOver({}));

  assert.ok("problem" in counts);
  assert.match(counts.problem, /names a shotgun symbol the branch does not have: ghost/u);
});

test("an empty symbol is a stop, since it would count every file in the repository", () => {
  const counts = countShotgun([{ symbol: "   ", files: 1 }], searchOver({}));

  assert.ok("problem" in counts);
  assert.match(counts.problem, /names an empty shotgun symbol/u);
});

test("a report naming nothing counts nothing, and says so without failing", () => {
  assert.deepEqual(countShotgun([], searchOver({})), { counts: [] });
});

test("a symbol the reviewer explained in a trailing note is searched as the symbol itself", () => {
  const counts = countShotgun(
    [{ symbol: "refusal (the sentence carried to the status line)", files: 1 }],
    searchOver({ refusal: ["src/a.js", "src/b.js", "src/c.js"] }),
  );

  assert.deepEqual(counts, {
    counts: [{ symbol: "refusal (the sentence carried to the status line)", files: 3, verdict: "plumbing" }],
  });
});

test("a search that finds nothing is no files, not an error", () => {
  assert.deepEqual(rgSearch("src")("a symbol this repository does not contain"), []);
});
