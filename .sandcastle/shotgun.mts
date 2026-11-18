// shotgun.mts — the one number in the standards lens the host checks for itself.
//
// A reviewer that names a symbol and a file count can be wrong without lying on purpose; a count the
// host recomputes cannot be wrong at all. So the reviewer names the symbols the diff carries through
// several files, and the host counts the files they appear in.

import { execFileSync } from "node:child_process";

/** How many files a symbol would have to appear in before it is plumbing worth naming. */
export const PLUMBING_FILES = 3;

/** What a reviewer claims about one symbol the diff carries through several files. */
export type ShotgunClaim = {
  /** The symbol or argument carried through the layers; the host searches for this text. */
  symbol: string;
  /** How many source files the reviewer says name it; the host replaces this with its own count. */
  files: number;
};

/** A verified claim: the count is the host's, not the reviewer's. */
export type ShotgunCount = { symbol: string; files: number; verdict: "plumbing" | "carried" };

/** Find the source files that name `symbol`. Injected in tests so nothing shells out there. */
export type SymbolSearch = (symbol: string) => string[];

/**
 * The host's search: the files of the branch at `root` that name the symbol.
 *
 * It asks git, not a filesystem walk, so the count is the branch's tracked files: a reviewer's own
 * verdict (an untracked artefact in the worktree) names every symbol it reports and would otherwise
 * count itself, and dot directories such as `.sandcastle/` are tracked source, not hidden noise.
 */
export function branchSearch(root: string): SymbolSearch {
  return (symbol) => {
    try {
      const out = execFileSync("git", ["grep", "-l", "--fixed-strings", "--", symbol], { cwd: root, encoding: "utf8" });
      return out.split("\n").filter((line) => line.trim().length > 0);
    } catch (err) {
      // Exit 1 is git's "nothing matched", a legitimate answer. Anything else is a real failure and
      // must not read as "the reviewer invented this symbol".
      if ((err as { status?: number }).status === 1) return [];
      throw err;
    }
  };
}

const TRAILING_PARENTHETICAL = /\s*\([^()]*\)$/u;

/**
 * The text the host searches for: the symbol with a trailing parenthetical note dropped.
 *
 * Reviewers explain a symbol inside the same string (`refusal (the sentence carried to the status
 * line)`). Searching that whole text finds no file and would stop the run over a readable note, so the
 * note is dropped for the search while the report keeps the reviewer's wording.
 */
export function searchable(symbol: string): string {
  return symbol.replace(TRAILING_PARENTHETICAL, "").trim();
}

/**
 * Recount every symbol a report names.
 *
 * The reviewer's own `files` figure is discarded rather than trusted, so the number that reaches the
 * run's log is always the number of files that actually name the symbol. A symbol the host cannot
 * find anywhere means the reviewer named something that is not on the branch, and that stops the run.
 */
export function countShotgun(
  claims: readonly ShotgunClaim[],
  search: SymbolSearch,
): { counts: ShotgunCount[] } | { problem: string } {
  const counts: ShotgunCount[] = [];

  for (const claim of claims) {
    const symbol = claim.symbol.trim();
    if (symbol.length === 0) return { problem: "the standards report names an empty shotgun symbol" };

    const found = search(searchable(symbol));
    if (found.length === 0) return { problem: `the standards report names a shotgun symbol the branch does not have: ${symbol}` };

    counts.push({
      symbol,
      files: found.length,
      verdict: found.length >= PLUMBING_FILES ? "plumbing" : "carried",
    });
  }

  return { counts };
}
