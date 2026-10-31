// test_support.mjs — node test helpers: give fake games the real core flow from the wasm artifact.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadArtifact } from "./artifacts/glue.js";

const here = dirname(fileURLToPath(import.meta.url));
const wasmBytes = readFileSync(join(here, "artifacts/artifact.wasm"));

/** A real wasm game bootstrapped like the host does; `config` overrides the defaults. */
export async function loadGame(config = {}) {
  const game = await loadArtifact(wasmBytes);
  const boot = game.bootstrapHostConfig({
    difficulty: 1,
    logLevel: 1,
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
    ...config,
  });
  if (!boot.ok) throw new Error(`game bootstrap failed: ${boot.error}`);
  return game;
}

/** Fresh wasm instance bootstrapped with `autoSave`, for flow exports only. */
export function loadCoreFlow({ autoSave = false } = {}) {
  return loadGame({ auto_save: autoSave });
}

/** Attach real `flowStart` / `flowNext` / `fileSessionEvent` to a fake game once; returns the game. */
export async function withCoreFlow(game, options = {}) {
  if (typeof game.flowStart === "function") return game;
  const core = await loadCoreFlow(options);
  game.flowStart = (start) => core.flowStart(start);
  game.flowNext = (input) => core.flowNext(input);
  game.fileSessionEvent = (event, name) => core.fileSessionEvent(event, name);
  return game;
}

/** Fetch fake answering `/current-file-exists` with `exists` and recording every call. */
export function hostFetch({ exists = false, calls = [] } = {}) {
  const fetchFn = async (url, init = {}) => {
    calls.push({ url, init });
    if (url === "./current-file-exists") return { ok: true, status: 200, json: async () => ({ exists }) };
    return { ok: true, status: 204, json: async () => ({}) };
  };
  return { fetchFn, calls };
}

/** The host write in recorded fetch calls, if any. */
export function postedCurrentFile(calls) {
  return calls.find((call) => call.url === "./current-file");
}

/** Let a flow started without `await` run its async steps to the end. */
export async function settleFlow() {
  for (let i = 0; i < 8; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
}
