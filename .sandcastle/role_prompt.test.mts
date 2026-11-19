// role_prompt.test.mts — a role's prompt resolved the way a cold spawn would resolve it.
//
// A fork takes its prompt inline, and sandcastle does no substitution or shell expansion on an
// inline prompt, so these are the only things standing between a role and a literal `{{KEY}}`.

import test from "node:test";
import assert from "node:assert/strict";
import { resolveRolePrompt } from "./role_prompt.mts";

/** A sandbox that answers each shell block with a fixed line, recording what it was asked to run. */
function promptSandbox(answers: Record<string, string> = {}) {
  const ran: string[] = [];
  return {
    ran,
    exec: async (command: string) => {
      ran.push(command);
      const stdout = answers[command];
      return stdout === undefined
        ? { exitCode: 1, stdout: "", stderr: "no such command" }
        : { exitCode: 0, stdout, stderr: "" };
    },
  };
}

test("a role's placeholders are filled, and an unfilled one stops the fork", async () => {
  const sandbox = promptSandbox();
  assert.equal(
    await resolveRolePrompt("ticket {{ISSUE}}, part {{ PART }}", { ISSUE: 7, PART: 2 }, sandbox),
    "ticket 7, part 2",
    "a fork is handed text, so the values have to be in it already",
  );
  await assert.rejects(
    () => resolveRolePrompt("issue #{{ISSUE}}", {}, sandbox),
    /needs \{\{ISSUE\}\}/u,
    "a role must never run on a prompt with a literal placeholder left in it",
  );
});

test("a role's shell blocks run in the sandbox and their output replaces them", async () => {
  const sandbox = promptSandbox({ "git log main..branch --oneline": "abc123 one commit" });
  const prompt = await resolveRolePrompt("Commits:\n!`git log main..branch --oneline`\nEnd.", {}, sandbox);

  assert.equal(prompt, "Commits:\nabc123 one commit\nEnd.", "the block's output stands where the block was");
  assert.deepEqual(sandbox.ran, ["git log main..branch --oneline"], "the command runs in the sandbox, so it sees the branch");
});

test("a shell block that fails stops the fork rather than leaving its command in the prompt", async () => {
  const sandbox = promptSandbox();
  await assert.rejects(
    () => resolveRolePrompt("!`gh issue view 7`", {}, sandbox),
    /exited 1: no such command/u,
    "a role reading a failed command's absence as an answer is worse than no role at all",
  );
});

test("a shell block inside an HTML comment is an example, not a command", async () => {
  const sandbox = promptSandbox();
  const prompt = await resolveRolePrompt("Real: !`git status`\n<!-- e.g. !`git diff` -->", {}, promptSandbox({ "git status": "clean" }));

  assert.equal(prompt, "Real: clean\n<!-- e.g. !`git diff` -->", "the commented example is left as written");
  assert.deepEqual(sandbox.ran, [], "and nothing is run for it");
});

test("a prompt with no shell blocks is returned without touching the sandbox", async () => {
  const sandbox = promptSandbox();
  assert.equal(await resolveRolePrompt("just words", {}, sandbox), "just words");
  assert.deepEqual(sandbox.ran, [], "no blocks, no commands");
});
