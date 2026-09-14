// glue.test.mjs — wasm glue + shell session contract.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { loadArtifact } from "./glue.js";
import { save, open, newGame } from "../shell.js";

const here = dirname(fileURLToPath(import.meta.url));
const wasmBytes = readFileSync(join(here, "artifact.wasm"));

const game = await loadArtifact(wasmBytes);

assert.equal(game.exports.step, undefined, "REPL step export must be gone");

// ── init ──
{
  const res = game.init({ difficulty: 1, logLevel: 1 });
  assert.equal(res.ok, true, `init failed: ${JSON.stringify(res)}`);
}

// ── legend flags ──
{
  const legend = game.getLegend();
  assert.equal(legend.fill, true);
  assert.equal(legend.quit, true);
  assert.equal(legend.undo, false, "fresh game should not offer undo");
}

// ── fill ──
{
  const state = game.getState();
  const idx = state.cells.findIndex((c) => c.value === 0 && !c.given);
  assert.ok(idx >= 0, "no fillable cell in initial state");
  const row = Math.floor(idx / 9);
  const col = idx % 9;

  const res = game.exec({ action: "fill", row, col, digit: 3 });
  assert.equal(res.ok, true, `fill failed: ${JSON.stringify(res)}`);
  assert.equal(res.is_quit, false);
  assert.equal(res.state.cells[idx].value, 3);

  const legend = game.getLegend();
  assert.equal(legend.undo, true, "fill should enable undo");
}

// ── error_msg ──
{
  const res = game.exec({ action: "xyzzy" });
  assert.equal(res.ok, false);
  assert.ok(res.error, "expected error string");
}

// ── error_msg ──
{
  const state = game.getState();
  const idx = state.cells.findIndex((c) => c.given);
  assert.ok(idx >= 0, "no given cell in initial state");
  const row = Math.floor(idx / 9);
  const col = idx % 9;
  const res = game.exec({ action: "clear", row, col });
  assert.equal(res.ok, false, `expected error: ${JSON.stringify(res)}`);
  assert.match(res.error, /puzzle/i);
}

// ── serialize round-trip ──
{
  const before = game.getState();
  const bytes = game.serialize();
  assert.ok(bytes.length > 16, "SUD0 blob too small");

  const fresh = await loadArtifact(wasmBytes);
  assert.equal(fresh.init({ difficulty: 1 }).ok, true);

  const loaded = fresh.deserialize(bytes);
  assert.equal(loaded.ok, true, `deserialize failed: ${JSON.stringify(loaded)}`);
  assert.deepEqual(fresh.getState(), before, "deserialize did not restore state");
}

// ── shell session round-trip ──
{
  const before = game.getState();
  const saved = save(game);
  assert.equal(saved.ok, true);
  assert.ok(saved.bytes.length > 16);

  const fresh = await loadArtifact(wasmBytes);
  const started = newGame(fresh, { difficulty: 2 });
  assert.equal(started.ok, true);

  const restored = open(fresh, saved.bytes);
  assert.equal(restored.ok, true);
  assert.deepEqual(fresh.getState(), before);
}

// ── quit ──
{
  const res = game.exec({ action: "quit" });
  assert.equal(res.ok, true);
  assert.equal(res.is_quit, true);
}

console.log("glue.test.mjs OK");
