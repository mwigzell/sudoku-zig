// Sequential reviewer: one issue per run, one agent per step.
//
// The issue's `## Steps` are the loop's iterations. Each iteration starts two fresh agent
// sessions on the same run branch: an implementer performs one step and commits once, a
// reviewer falsifies that step and writes `.sandcastle/verdict.json`. The host reads the
// verdict, decides whether the step stands, and — the only actor allowed to do so — ticks
// the step on the issue. A step that fails, proves nothing, drifts or endangers an
// acceptance criterion stops the loop with the branch left for accept or drop.
//
// This entry is project-owned, as is `project.mts`: the two places allowed to run `gh`, to
// name the agent, and to know this repository. Everything the generic modules need is handed
// to them as `PROJECT`.
//
// Usage:
//   npx tsx .sandcastle/main.mts --issue <number> [--plan]
//   npm run sandcastle -- --issue <number>
//   npm run sandcastle:plan -- --issue <number>
//

import * as sandcastle from "@ai-hero/sandcastle";
import { bwrap } from "@ai-hero/sandcastle/sandboxes/bwrap";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PROJECT } from "./project.mts";
import { formatPlan, makePlan } from "./plan.mts";
import { runSteps, type Tracker } from "./loop.mts";
import { decideResume, type UnsettledRun } from "./resume.mts";
import { readRunRecord } from "./run_record.mts";

/** The host's run directory: one per run stamp, beside every other run this repository ran. */
function runDir(stamp: number): string {
  return join(PROJECT.paths.runsDir, String(stamp));
}

const git = (args: string[]): string => execFileSync("git", args, { encoding: "utf8" }).trim();

/**
 * The real tracker: `gh` as the host's logged-in user.
 *
 * A body file rather than `--body` keeps the argument list short and the shell out of the
 * write; the temporary file is removed whether or not `gh` succeeds. It lives in the entry
 * because `gh` is a project capability: the generic loop only ever sees a `Tracker`.
 */
export function ghTracker(): Tracker {
  return {
    read: (issue) => {
      const raw = execFileSync("gh", ["issue", "view", String(issue), "--json", "title,body"], { encoding: "utf8" });
      return JSON.parse(raw) as { title: string; body: string };
    },
    writeBody: (issue, body) => {
      const file = join(tmpdir(), `sandcastle-issue-${issue}.md`);
      writeFileSync(file, body);
      try {
        execFileSync("gh", ["issue", "edit", String(issue), "--body-file", file], { encoding: "utf8" });
      } finally {
        rmSync(file, { force: true });
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Preflight
//
// A run starts from HEAD and leaves a worktree and a branch behind, so the
// repo has to be in a state where that is safe. Each check throws: a run that
// would misbehave should not start at all.
// ---------------------------------------------------------------------------

/** Every run leaves a worktree, so more than one line means an earlier run was never settled. */
function checkNoLeftoverWorktrees(): void {
  const worktrees = git(["worktree", "list", "--porcelain"])
    .split("\n\n")
    .filter((block) => block.trim().length > 0);
  if (worktrees.length > 1) {
    throw new Error(`a previous run's worktree is still here (${worktrees.length} worktrees): accept or drop it first`);
  }
}

/**
 * Every unaccepted run the repository holds: one `sandcastle/*` branch each, with the aim its run
 * directory recorded. A branch whose stamp carries no record reads as a run of unknown aim.
 */
function unsettledRuns(): UnsettledRun[] {
  return git(["branch", "--list", "sandcastle/*", "--format=%(refname:short)"])
    .split("\n")
    .map((line) => line.trim())
    .filter((branch) => branch.length > 0)
    .map((branch) => {
      const stamp = Number(branch.slice(branch.lastIndexOf("/") + 1));
      const record = Number.isInteger(stamp) && stamp > 0 ? readRunRecord(runDir(stamp)) : null;
      return { stamp, branch, issue: record === null ? null : record.issue };
    });
}

/** The implementer commits into a worktree cut from HEAD, so uncommitted work would not travel with it. */
function checkCleanTree(): void {
  const dirty = git(["status", "--porcelain"]);
  if (dirty.length > 0) {
    throw new Error(`working tree is not clean:\n${dirty}`);
  }
}

/** bwrap hides the host's gh login, so the agent's first gh call needs a token in the project's env file. */
function checkGitHubToken(): void {
  const envPath = new URL(`../${PROJECT.paths.env}`, import.meta.url);
  if (!existsSync(envPath) || !/^GH_TOKEN=\S+/mu.test(readFileSync(envPath, "utf8"))) {
    throw new Error(`${PROJECT.paths.env} has no GH_TOKEN; the agent cannot read issues without one`);
  }
}

// ---------------------------------------------------------------------------
// The run's aim
//
// A run is aimed at one issue: its `## Steps` are the loop's iterations, so there is
// nothing to pick from a label list. `--plan` reads that issue and prints the run's
// shape without starting one, so a run can be inspected before it costs an agent.
// ---------------------------------------------------------------------------

/** The branch the run is cut from and accepted into: whatever HEAD is on when it starts. */
function currentBranch(): string {
  return git(["rev-parse", "--abbrev-ref", "HEAD"]);
}

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

/**
 * Run the harness for one aim, and return the process exit code.
 *
 * Nothing at module scope starts a run: the entry runs only under `import.meta.main`, so
 * `accept.mts` and `drop.mts` import `ghTracker` and the project facts without one.
 */
async function main(): Promise<number> {
  const argv = process.argv.slice(2);
  const issue = Number(argumentValue("--issue", argv) ?? "");
  if (!Number.isInteger(issue) || issue <= 0) {
    console.error(`usage: npm run sandcastle -- --issue <number> [--plan]\nmanual: ${PROJECT.docs.harness}`);
    return 1;
  }

  const viewed = readIssue(issue);

  if (argv.includes("--plan")) {
    // A plan costs no agent and leaves no worktree or branch; a stopped run in the way is the run's
    // business, so the shape it prints may differ from a run's only in the branch head and stamp it would carry.
    const shape = makePlan(issue, viewed.title, viewed.body, {
      stamp: Date.now(),
      targetBranch: currentBranch(),
      labels: viewed.labels,
      project: PROJECT,
    });
    for (const line of formatPlan(shape)) console.log(line);
    // A refused issue cannot be run, so the plan's exit code says so; a reader that scripts
    // the harness sees the refusal instead of a plan it would otherwise act on.
    return shape.refusal === null ? 0 : 1;
  }

  // An aim at an issue whose run stopped continues that run: its branch, its ticks and its logs are
  // the work it already earned, and only the unticked steps are left. An unaccepted run aimed
  // elsewhere is settled first, by accept or drop.
  const decision = decideResume(unsettledRuns(), issue);
  if (decision.kind === "stop") {
    console.error(`[stop] ${decision.reason}`);
    return 1;
  }
  const stamp = decision.kind === "resume" ? decision.stamp : Date.now();
  if (decision.kind === "resume") console.log(`[resume] continuing ${decision.branch}: the steps it ticked are history`);

  const runsDir = runDir(stamp);
  // A resumed run keeps the base it was cut from; a fresh one starts from the branch HEAD is on.
  const targetBranch = decision.kind === "resume"
    ? (readRunRecord(runsDir)?.targetBranch ?? currentBranch())
    : currentBranch();

  const plan = makePlan(issue, viewed.title, viewed.body, {
    stamp,
    targetBranch,
    labels: viewed.labels,
    project: PROJECT,
  });

  if (plan.refusal !== null) {
    for (const line of formatPlan(plan)) console.error(line);
    return 1;
  }

  // Preflight belongs to a run that will leave a worktree and a branch behind, so a plan
  // read above pays for none of it.
  checkNoLeftoverWorktrees();
  checkCleanTree();
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
    sandcastle.pi(PROJECT.agent.model, {
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

  const sandbox = await sandcastle.createSandbox({
    branch: plan.branch,
    baseBranch: plan.targetBranch,
    sandbox: agentSandbox(),
    hooks,
    copyToWorktree,
  });

  try {
    return await runSteps({ plan, sandbox, tracker: ghTracker(), agent: workerAgent(), runsDir, project: PROJECT });
  } finally {
    // Close always: a stopped run leaves its branch and worktree for accept or drop, and the
    // verdicts already copied into the run directory survive the worktree's removal.
    await sandbox.close();
  }
}

// Only a direct invocation starts a run: the tracker above is importable by accept and drop.
if (import.meta.main) process.exit(await main());
