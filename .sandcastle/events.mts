// events.mts — the run's own log: one timestamped line per event.
//
// A run's stdout is what a person watches while it goes; the event log is what is left afterwards.
// Both files carry the same events: `events.jsonl` for a program to read (`status`, `watch`) and
// `run.log` for a person to read, one line each.

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** The kinds of event a run records. One per transition the loop makes. */
export type EventKind =
  | "run"
  | "step"
  | "agent-start"
  | "agent-end"
  | "agent-cost"
  | "heartbeat"
  | "verdict"
  | "tick"
  | "criterion"
  | "end"
  | "stop"
  | "detail";

/** One line of the run's log: when it happened, what kind it was, what it said, and its step. */
export type RunEvent = {
  /** ISO 8601 timestamp, so two logs can be read side by side. */
  at: string;
  kind: EventKind;
  message: string;
  /** The iteration a step event belongs to; absent on other events and on logs written before it. */
  step?: { at: number; of: number };
  /**
   * What an agent said while it worked, one event per line of its transcript. A `detail` carries
   * `role` so a reader can tell the implementer's reasoning from the reviewer's.
   */
  role?: string;
  /**
   * What one agent run cost, on its `agent-cost` event: the session it ran in and its tokens, so
   * two consecutive steps can be compared without opening the agent's own session file.
   */
  cost?: AgentCost;
};

/** One agent run's session and token cost, as the agent reported them. */
export type AgentCost = {
  /** The session this run used; a fork's own id, not the seed's. */
  sessionId: string | null;
  /** Tokens the model read that were not cached. */
  inputTokens: number;
  /** Tokens written to the prompt cache, which a fork's shared prefix mostly is. */
  cacheCreationInputTokens: number;
  /** Tokens read from the prompt cache. */
  cacheReadInputTokens: number;
  /** Tokens the model wrote. */
  outputTokens: number;
};

/** `events.jsonl`, the machine-readable half of the run's log. */
export function eventsPath(runsDir: string): string {
  return join(runsDir, "events.jsonl");
}

/** `run.log`, the half a person reads. */
export function runLogPath(runsDir: string): string {
  return join(runsDir, "run.log");
}

/**
 * What one agent run cost, as one line: its session, then its tokens.
 *
 * The figures are the agent's own, and a fork's cached prefix shows up as cache reads, which is
 * what makes the seed's saving visible: a step that re-read the startup context would pay it
 * again as input.
 */
export function formatAgentCost(cost: AgentCost): string {
  const session = cost.sessionId === null ? "no session id" : `session ${cost.sessionId}`;
  return (
    `${session}: input ${cost.inputTokens}, cached input ${cost.cacheReadInputTokens}` +
    ` (+${cost.cacheCreationInputTokens} written), output ${cost.outputTokens}`
  );
}

/**
 * `event` as its `run.log` line: the time, the kind in brackets, then the message.
 *
 * The line is plain text so the file reads the same everywhere; `paintRunLogLine` adds the colour
 * and the section rules a person watching the terminal needs.
 */
export function formatRunLogLine(event: RunEvent): string {
  const role = event.role === undefined ? "" : ` ${event.role}`;
  return `${event.at} [${event.kind}${role}] ${event.message}`;
}

/** The ANSI colours a watching terminal uses; empty strings when colour is off. */
const NO_COLOUR = { reset: "", dim: "", bold: "", red: "", green: "", yellow: "", cyan: "", magenta: "" };
type Palette = typeof NO_COLOUR;

function palette(on: boolean): Palette {
  if (!on) return NO_COLOUR;
  return {
    reset: "\u001b[0m",
    dim: "\u001b[2m",
    bold: "\u001b[1m",
    red: "\u001b[31m",
    green: "\u001b[32m",
    yellow: "\u001b[33m",
    cyan: "\u001b[36m",
    magenta: "\u001b[35m",
  };
}

/** A rule the width of the terminal, so a new section is unmistakable while following a run. */
function rule(colour: string, label: string, width = 78): string {
  const head = label.length === 0 ? "" : ` ${label} `;
  const fill = Math.max(2, width - head.length - 2);
  return `${colour}${"\u2501".repeat(2)}${head}${"\u2501".repeat(fill)}${NO_COLOUR.reset}`;
}

/**
 * One `run.log` line as a person watching the run should see it.
 *
 * The colour says what happened at a glance — green for a tick or a pass, red for a stop or a
 * failure, cyan for an agent taking over — and a rule opens each new step and the final review, so
 * the reader can see where in the run they are without reading the messages.
 *
 * `colour`: whether the caller's terminal takes ANSI escapes.
 */
export function paintRunLogLine(event: RunEvent, colour: boolean): string {
  const c = palette(colour);
  const time = `${c.dim}${event.at.slice(11, 19)}${c.reset}`;
  const body = event.message;
  switch (event.kind) {
    case "step": {
      // The message opens with the stage ("step N/M: …"), which older logs carry where `step` is absent.
      const stage = event.step ? `${event.step.at}/${event.step.of}` : (/^step (\d+\/\d+)/u.exec(body)?.[1] ?? "");
      const title = body.replace(/^step \d+\/\d+: /u, "");
      return `${rule(c.cyan, `STEP ${stage}`)}\n${c.cyan}${c.bold}${title}${c.reset}`;
    }
    case "agent-start":
      return `${time} ${c.cyan}${c.bold}\u25b6 ${body}${c.reset}`;
    case "agent-end":
      return `${time} ${c.dim}\u25a0 ${body} ended${c.reset}`;
    case "detail":
      return `${c.dim}         \u2502 ${body}${c.reset}`;
    case "verdict":
      return body.includes("STOP")
        ? `${time} ${c.red}${c.bold}\u2717 ${body}${c.reset}`
        : `${time} ${c.green}\u2713 ${body}${c.reset}`;
    case "tick":
      return `${time} ${c.green}${c.bold}\u2611 ${body}${c.reset}`;
    case "criterion":
      return `${time} ${c.green}\u2611 ${body}${c.reset}`;
    case "stop":
      return `${rule(c.red, "STOPPED")}\n${time} ${c.red}${c.bold}${body}${c.reset}`;
    case "end":
      return `${rule(c.green, "FINISHED")}\n${time} ${c.green}${c.bold}${body}${c.reset}`;
    case "run":
      return `${rule(c.magenta, "RUN")}\n${time} ${c.magenta}${body}${c.reset}`;
    case "heartbeat":
      return `${time} ${c.dim}${body}${c.reset}`;
    default:
      return `${time} ${body}`;
  }
}

/**
 * Append one event to both halves of the run's log.
 *
 * `runsDir`: the run's directory, created when the run has not made it yet.
 * `event`: the transition, already timed by the caller so the two files agree.
 */
export function appendEvent(runsDir: string, event: RunEvent): void {
  mkdirSync(runsDir, { recursive: true });
  appendFileSync(eventsPath(runsDir), `${JSON.stringify(event)}\n`);
  appendFileSync(runLogPath(runsDir), `${formatRunLogLine(event)}\n`);
}

/** Every event the run recorded, in order; empty when the run left no log (or none yet). */
export function readEvents(runsDir: string): RunEvent[] {
  const file = eventsPath(runsDir);
  if (!existsSync(file)) return [];
  return readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line) as RunEvent);
}
