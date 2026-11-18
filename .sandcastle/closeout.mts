// closeout.mts — the host's last phase: prove an Android-scope branch on a device before accept.
//
// The project's gate cannot reach the device suite, so the proof of an Android change is a recorded
// device run. The required scenarios are a property of the branch — the methods it adds or changes,
// the ones the issue declares, and the pinned smoke when it changes none — so this phase derives the
// set, runs the project's gate command for exactly those methods and leaves the record in the run
// directory accept reads. The runner and the branch diff are handed in, so the decisions are proven
// with a fake gate; a missing device is a stop that names the start script, never a skip.

import type { AndroidConfig } from "./project_config.mts";
import {
  checkAndroidEvidence,
  evidencePath,
  requiredScenarios,
  type BranchDiff,
  type Requirement,
} from "./android_evidence.mts";

/** What one gate command produced: whether it passed, and the lines it reported. */
export interface GateOutcome {
  /** Whether the command exited zero. */
  ok: boolean;
  /** The gate's own report, so a stop names the failure rather than only that it failed. */
  output: string;
}

/** Runs the project's gate command where the caller says; production spawns it, a test answers. */
export type GateRunner = (command: string) => GateOutcome;

/** Everything the closeout needs: the branch, its diff, its issue and the project's device facts. */
export interface CloseoutRequest {
  /** The run's directory, absolute: the gate runs in the worktree, where a relative path would land. */
  runsDir: string;
  /** The issue whose branch this is, so the record names what it proves. */
  issue: number;
  /** The issue's body, where a change declares the existing scenarios it exercises. */
  body: string;
  /** The commit the branch was cut from: the left side of the diff the required set is read from. */
  base: string;
  /** The branch's head: the commit the evidence must prove. */
  head: string;
  /** The project's device facts: what makes a branch Android-scope, and how its gate is spelled. */
  android: AndroidConfig;
  /** The branch as git reports it, so the required set is judged on the branch itself. */
  diff: BranchDiff;
}

/** How a run ends after the loop: ready for a human, or stopped with the reason it could not be. */
export type CloseoutResult =
  | {
      /** The run may be accepted: the branch owes no device run, or one proved it. */
      kind: "ready";
      /** The line the run ends on, so a person sees where it stands. */
      message: string;
      /** The device record accept will read; `null` when the branch needs none. */
      evidence: string | null;
      /** The scenarios the device run proved, empty when none were required. */
      required: readonly Requirement[];
    }
  | {
      /** The run stops here: its branch is left for accept or drop like a stopped step. */
      kind: "stopped";
      /** What stopped it, naming the defect and — for a device — the script that starts one. */
      message: string;
    };

/** The gate's own reason from its output: the line naming the start script when no device was up. */
function gateReason(output: string, startScript: string): string {
  const lines = output
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  const instruction = lines.filter((line) => line.includes(startScript)).at(-1);
  return instruction ?? lines.at(-1) ?? "the gate printed nothing";
}

/**
 * Run the closeout for one finished loop: derive the branch's device requirement, prove it and
 * report how the run ends.
 *
 * Only a green gate that left a record of the branch head is `ready`; everything else stops the run
 * with the reason. The record is read back through the same check accept makes, so a run never ends
 * `ready` on a file accept would refuse.
 */
export function closeoutFor(request: CloseoutRequest, run: GateRunner): CloseoutResult {
  const set = requiredScenarios({ diff: request.diff, body: request.body, android: request.android });
  if (set.kind === "not-android") {
    return {
      kind: "ready",
      message: "ready to accept — the branch changes no Android code, so no device run is required",
      evidence: null,
      required: [],
    };
  }
  if (set.kind === "stop") return { kind: "stopped", message: `stopped: ${set.reason}` };

  const evidence = evidencePath(request.runsDir);
  const methods = set.required.map((entry) => entry.method);
  const outcome = run(request.android.gate.command({ methods, evidenceOut: evidence, issue: request.issue }));
  if (!outcome.ok) {
    const reason = gateReason(outcome.output, request.android.gate.startScript);
    return { kind: "stopped", message: `stopped: device — ${reason}` };
  }

  // The gate writes the file accept reads, so its shape is checked here rather than discovered at
  // accept: a record that does not prove this head stops the run while the branch is still local.
  const problem = checkAndroidEvidence({
    diff: request.diff,
    body: request.body,
    android: request.android,
    runsDir: request.runsDir,
    commit: request.head,
  });
  if (problem !== null) return { kind: "stopped", message: `stopped: device — ${problem}` };

  return {
    kind: "ready",
    message: `ready to accept — the device run proved ${methods.join(", ")}; record in ${evidence}`,
    evidence,
    required: set.required,
  };
}
