// drop.mts — the tracker half of dropping a run: take back the ticks the run wrote.
//
// `scripts/sandcastle-drop.sh` calls this before it removes the branch, so a dropped run
// leaves the issue as it found it. The git half stays in the script.

import { join } from "node:path";
import { ledgerPath, readLedger, untickRun } from "./ledger.mts";
import { ghTracker } from "./loop.mts";

/** A run's directory is named after its stamp, which the branch name ends with. */
const runsDir = (stamp: string): string => join(".sandcastle", "logs", stamp);

const at = process.argv.indexOf("--stamp");
const stamp = at === -1 ? "" : (process.argv[at + 1] ?? "");
if (!/^\d+$/u.test(stamp)) {
  console.error("usage: npx tsx .sandcastle/drop.mts --stamp <run stamp>");
  process.exit(1);
}

const file = ledgerPath(runsDir(stamp));
const ledger = readLedger(file);

// A run from before the record existed leaves no way to know what it ticked; say so and let
// the drop continue rather than trapping the branch in the repo.
if (ledger === null) {
  console.log(`[drop] no tick record in ${file}; the issue's steps are left as they are`);
  process.exit(0);
}

const positions = untickRun(ledger, ghTracker());
console.log(
  positions.length === 0
    ? `[drop] the run ticked no step on #${ledger.issue}`
    : `[drop] took back the ticks on #${ledger.issue}: steps ${positions.join(", ")}`,
);
