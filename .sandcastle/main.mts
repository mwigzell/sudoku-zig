// Sequential reviewer: one issue per run, one agent per step.
//
// The issue's `## Steps` are the loop's iterations. Each iteration starts two fresh agent
// sessions on the same run branch: an implementer performs one step and commits once, a
// reviewer falsifies that step and writes `.sandcastle/verdict.json`. The host reads the
// verdict, decides whether the step stands, and — the only actor allowed to do so — ticks
// the step on the issue. A step that fails, proves nothing, drifts or endangers an
// acceptance criterion stops the loop with the branch left for accept or drop.
//
// Usage:
//   npx tsx .sandcastle/main.mts --issue <number> [--plan]
//   npm run sandcastle -- --issue <number>
//   npm run sandcastle:plan -- --issue <number>
//

import * as sandcastle from "@ai-hero/sandcastle";
import { bwrap } from "@ai-hero/sandcastle/sandboxes/bwrap";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { formatPlan, makePlan } from "./plan.mts";
import { ghTracker, runSteps } from "./loop.mts";

// ---------------------------------------------------------------------------
// Preflight
//
// A run starts from HEAD and leaves a worktree and a branch behind, so the
// repo has to be in a state where that is safe. Each check throws: a run that
// would misbehave should not start at all.
// ---------------------------------------------------------------------------

const git = (args: string[]): string => execFileSync("git", args, { encoding: "utf8" }).trim();

/** Every run leaves a worktree, so more than one line means an earlier run was never settled. */
function checkNoLeftoverWorktrees(): void {
  const worktrees = git(["worktree", "list", "--porcelain"])
    .split("\n\n")
    .filter((block) => block.trim().length > 0);
  if (worktrees.length > 1) {
    throw new Error(`a previous run's worktree is still here (${worktrees.length} worktrees): accept or drop it first`);
  }
}

/** Commits on a sandcastle/* branch are work from an earlier run that was never accepted. */
function checkNoUnsettledBranches(): void {
  const branches = git(["branch", "--list", "sandcastle/*", "--format=%(refname:short)"]);
  if (branches.length > 0) {
    throw new Error(`unaccepted runs remain: ${branches.split("\n").join(", ")}`);
  }
}

/** The implementer commits into a worktree cut from HEAD, so uncommitted work would not travel with it. */
function checkCleanTree(): void {
  const dirty = git(["status", "--porcelain"]);
  if (dirty.length > 0) {
    throw new Error(`working tree is not clean:\n${dirty}`);
  }
}

/** The run branch is cut from the target branch, and the accept step merges into the current one. */
function checkOnTargetBranch(): void {
  const current = git(["rev-parse", "--abbrev-ref", "HEAD"]);
  if (current !== plan.targetBranch) {
    throw new Error(`a run is cut from and accepted into ${plan.targetBranch}, but HEAD is on ${current}`);
  }
}

/** bwrap hides the host's gh login, so the agent's first gh call needs a token in .env. */
function checkGitHubToken(): void {
  const envPath = new URL(".env", import.meta.url);
  if (!existsSync(envPath) || !/^GH_TOKEN=\S+/mu.test(readFileSync(envPath, "utf8"))) {
    throw new Error(".sandcastle/.env has no GH_TOKEN; the agent cannot read issues without one");
  }
}

// ---------------------------------------------------------------------------
// The run's aim
//
// A run is aimed at one issue: its `## Steps` are the loop's iterations, so there is
// nothing to pick from a label list. `--plan` reads that issue and prints the run's
// shape without starting one, so a run can be inspected before it costs an agent.
// ---------------------------------------------------------------------------

/** The only branch a run is cut from and merged into; `main` is never written by the harness. */
const TARGET_BRANCH = "develop";

/** The value following a flag, or `undefined` when the flag is absent. */
function argumentValue(flag: string, argv: string[]): string | undefined {
  const at = argv.indexOf(flag);
  return at === -1 ? undefined : argv[at + 1];
}

/** The issue as the tracker holds it: the plan reads it once, and the loop re-reads it as the host ticks steps. */
function readIssue(number: number): { title: string; body: string; labels: string[] } {
  const raw = execFileSync("gh", ["issue", "view", String(number), "--json", "title,body,labels"], { encoding: "utf8" });
  const parsed = JSON.parse(raw) as { title: string; body: string; labels: { name: string }[] };
  return { title: parsed.title, body: parsed.body, labels: parsed.labels.map((label) => label.name) };
}

const argv = process.argv.slice(2);
const issue = Number(argumentValue("--issue", argv) ?? "");
if (!Number.isInteger(issue) || issue <= 0) {
  console.error("usage: npm run sandcastle -- --issue <number> [--plan]");
  process.exit(1);
}

const viewed = readIssue(issue);
const stamp = Date.now();
const plan = makePlan(issue, viewed.title, viewed.body, { stamp, targetBranch: TARGET_BRANCH, labels: viewed.labels });

if (argv.includes("--plan")) {
  for (const line of formatPlan(plan)) console.log(line);
  // A refused issue cannot be run, so the plan's exit code says so; a reader that scripts
  // the harness sees the refusal instead of a plan it would otherwise act on.
  process.exit(plan.refusal === null ? 0 : 1);
}

if (plan.refusal !== null) {
  for (const line of formatPlan(plan)) console.error(line);
  process.exit(1);
}

// Preflight belongs to a run that will leave a worktree and a branch behind, so a plan
// read above pays for none of it.
checkNoLeftoverWorktrees();
checkNoUnsettledBranches();
checkCleanTree();
checkOnTargetBranch();
checkGitHubToken();

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// Hooks run inside the sandbox before the agent starts each iteration.
// npm install ensures the sandbox always has fresh dependencies.
const hooks = {
  sandbox: { onSandboxReady: [{ command: "npm install" }] },
};

// Copy node_modules from the host into the worktree before the sandbox starts. Avoids a
// full npm install from scratch; the hook above handles platform-specific binaries and any
// packages added since the last copy.
const copyToWorktree = ["node_modules"];

// bwrap gives the agent a private home, so pi would see no provider catalog and
// report "Model not found". Mount the host's pi config and point pi at it. It has
// to be writable: pi creates settings.json.lock and auth.json.lock in the same dir.
const HOST_PI_AGENT_DIR = `${process.env.HOME}/.pi/agent`;
const agentSandbox = () => bwrap({ mounts: [{ hostPath: HOST_PI_AGENT_DIR, sandboxPath: HOST_PI_AGENT_DIR }] });
const PI_SESSIONS_DIR = `${HOST_PI_AGENT_DIR}/sessions`;

const workerAgent = () =>
  sandcastle.pi("ollama/sandcastle-worker", {
    env: { PI_CODING_AGENT_DIR: HOST_PI_AGENT_DIR },
    // Session capture defaults to the sandbox home; pi writes under the mounted
    // config dir instead, so both sides of the capture point at that path.
    sessionStorage: {
      hostSessionsDir: PI_SESSIONS_DIR,
      sandboxSessionsDir: PI_SESSIONS_DIR,
    },
  });

// ---------------------------------------------------------------------------
// The run
//
// The sandbox is created once and every step commits to its branch. The loop decides what
// happens between steps and owns every tracker write; the agents inside the sandbox never
// write to the issue.
// ---------------------------------------------------------------------------

const runsDir = join(".sandcastle", "logs", String(stamp));

const sandbox = await sandcastle.createSandbox({
  branch: plan.branch,
  baseBranch: TARGET_BRANCH,
  sandbox: agentSandbox(),
  hooks,
  copyToWorktree,
});

let exitCode = 1;
try {
  exitCode = await runSteps({ plan, sandbox, tracker: ghTracker(), agent: workerAgent(), runsDir });
} finally {
  // Close always: a stopped run leaves its branch and worktree for accept or drop, and the
  // verdicts already copied into the run directory survive the worktree's removal.
  await sandbox.close();
}

process.exit(exitCode);
