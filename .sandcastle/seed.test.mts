// seed.test.mts — the run's one seed session, and the stop when a role could not fork it.

import test from "node:test";
import assert from "node:assert/strict";
import { capturedSessionId, openSeed } from "./seed.mts";

/** A sandbox whose one seed run answers with `opened`; a fork is recorded, not performed. */
function seedSandbox(opened: { iterations: Array<{ sessionId?: string }>; fork?: unknown }) {
  const forks: Array<{ prompt: string; name: string }> = [];
  return {
    forks,
    run: async () => ({
      commits: [],
      stdout: "",
      ...opened,
      fork:
        opened.fork === undefined
          ? undefined
          : async (prompt: string, options?: { name?: string }) => {
              forks.push({ prompt, name: options?.name ?? "" });
              return { commits: [], iterations: [], stdout: "" };
            },
    }),
  };
}

test("a run's seed is one session, and every role forks it by name", async () => {
  const sandbox = seedSandbox({ iterations: [{ sessionId: "seed-1" }], fork: true });
  const seed = await openSeed(sandbox as never, {} as never, "seed-prompt.md");

  assert.equal(seed.sessionId, "seed-1", "the seed's id is what a resumed run forks again");
  await seed.fork("the implementer's instruction", { name: "implementer-step-1of2" });
  assert.deepEqual(
    sandbox.forks,
    [{ prompt: "the implementer's instruction", name: "implementer-step-1of2" }],
    "a fork carries the role's resolved prompt and its log name, and nothing else",
  );
});

test("a seed the agent gave no session id for stops the run, naming that", async () => {
  const sandbox = seedSandbox({ iterations: [{}], fork: true });
  await assert.rejects(
    () => openSeed(sandbox as never, {} as never, "seed-prompt.md"),
    /captured no session id/u,
    "a run with no seed id has nothing to fork, so it says so rather than spawning cold",
  );
});

test("an agent that cannot fork stops the run, naming that", async () => {
  const sandbox = seedSandbox({ iterations: [{ sessionId: "seed-1" }] });
  await assert.rejects(
    () => openSeed(sandbox as never, {} as never, "seed-prompt.md"),
    /cannot fork/u,
    "every role would spawn cold, so the run stops instead of quietly paying the startup context twice",
  );
});

test("a session id is read from the last iteration, or reported as none", () => {
  assert.equal(capturedSessionId({ iterations: [{ sessionId: "a" }, { sessionId: "b" }] } as never), "b");
  assert.equal(capturedSessionId({ iterations: [{ sessionId: "" }] } as never), null, "an empty id is no id");
  assert.equal(capturedSessionId({ iterations: [] } as never), null, "a run that never started has none either");
});
