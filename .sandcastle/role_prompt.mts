// role_prompt.mts — a role's prompt, resolved the way a cold spawn would resolve it.
//
// A fork takes its prompt inline, and an inline prompt gets no `{{KEY}}` substitution and no
// `!`command`` expansion from sandcastle. A role prompt needs both, so this fills its arguments and
// runs its shell blocks before the fork is made.
//
// The template's text and the sandbox the blocks run in are both handed in: this module knows no
// path and starts no process, so it stays project-neutral.

/** The sandbox command a prompt's shell blocks run in; the same cwd sandcastle uses. */
export interface PromptSandbox {
  exec(command: string): Promise<{ exitCode: number; stdout: string; stderr: string }>;
}

/** A `!`command`` block, and where it sits in the template. */
const SHELL_BLOCK = /!`(?<command>[^`]+)`/gu;
/** A `{{KEY}}` placeholder, matching sandcastle's own pattern. */
const PLACEHOLDER = /\{\{\s*(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*\}\}/gu;
/** Blocks inside an HTML comment are examples, not commands to run. */
const HTML_COMMENT = /<!--[\s\S]*?(?:-->|$)/gu;

/**
 * A role's prompt with its arguments filled and its shell blocks expanded.
 *
 * `template`: the prompt's text, already read by the caller that knows where prompts live.
 * `args`: values for the template's placeholders; a placeholder with no value throws, so a role
 * never runs on a prompt with a literal `{{KEY}}` left in it.
 * `sandbox`: where the shell blocks run, so they see the branch under review.
 */
export async function resolveRolePrompt(
  template: string,
  args: Record<string, string | number>,
  sandbox: PromptSandbox,
): Promise<string> {
  const filled = template.replace(PLACEHOLDER, (_match, key: string) => {
    const value = args[key];
    if (value === undefined) throw new Error(`the role prompt needs {{${key}}} and no value was given`);
    return String(value);
  });

  const comments = [...filled.matchAll(HTML_COMMENT)].map((match) => [match.index, match.index + match[0].length]);
  const blocks = [...filled.matchAll(SHELL_BLOCK)].filter(
    (match) => !comments.some(([start, end]) => match.index >= start! && match.index < end!),
  );
  if (blocks.length === 0) return filled;

  const outputs = await Promise.all(
    blocks.map(async (block) => {
      const command = block.groups?.command ?? "";
      const result = await sandbox.exec(command);
      if (result.exitCode !== 0) {
        throw new Error(`the prompt's \`${command}\` exited ${result.exitCode}: ${result.stderr}`);
      }
      return result.stdout.trimEnd();
    }),
  );

  let expanded = "";
  let cursor = 0;
  for (const [index, block] of blocks.entries()) {
    expanded += filled.slice(cursor, block.index) + outputs[index];
    cursor = block.index! + block[0].length;
  }
  return expanded + filled.slice(cursor);
}
