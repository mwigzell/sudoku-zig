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

// ── about metadata ──
{
  const about = game.getAbout();
  assert.equal(about.name, "sudoku-zig");
  assert.match(about.version, /^\d+\.\d+\.\d+$/);
  assert.ok(about.commit.length >= 6);
  assert.match(about.build_date, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(about.licence, "MIT");
  assert.ok(Array.isArray(about.logo) && about.logo.length > 0);
  assert.ok(about.summary.includes(about.version));
  assert.ok(about.summary.includes(about.commit));
}

// ── config defaults (WireConfig shape) ──
{
  const config = game.getConfig();
  assert.equal(config.difficulty, 1);
  assert.equal(config.log_level, 1);
  assert.equal(config.theme, "dark");
  assert.equal(config.show_region, false);
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
  assert.equal(legend.redo, false, "fill alone should not enable redo");
}

// ── undo / redo ──
{
  const before = game.getState();
  const idx = before.cells.findIndex((c) => c.value === 0 && !c.given);
  const row = Math.floor(idx / 9);
  const col = idx % 9;
  const digit = 5;

  const fill = game.exec({ action: "fill", row, col, digit });
  assert.equal(fill.ok, true, `fill failed: ${JSON.stringify(fill)}`);
  assert.equal(fill.state.cells[idx].value, digit);

  const undo = game.exec({ action: "undo" });
  assert.equal(undo.ok, true, `undo failed: ${JSON.stringify(undo)}`);
  assert.equal(undo.state.cells[idx].value, 0);

  let legend = game.getLegend();
  assert.equal(legend.redo, true, "undo should enable redo");

  const redo = game.exec({ action: "redo" });
  assert.equal(redo.ok, true, `redo failed: ${JSON.stringify(redo)}`);
  assert.equal(redo.state.cells[idx].value, digit);

  legend = game.getLegend();
  assert.equal(legend.undo, true);
  assert.equal(legend.redo, false, "redo should consume redo availability");
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

// ── view prefs via config ──
{
  let config = game.getConfig();
  assert.equal(config.theme, "dark");
  assert.equal(config.show_region, false);

  const light = game.exec({ action: "set_theme", theme: "light" });
  assert.equal(light.ok, true);
  config = game.getConfig();
  assert.equal(config.theme, "light");

  const region = game.exec({ action: "set_region", enabled: true });
  assert.equal(region.ok, true);
  config = game.getConfig();
  assert.equal(config.show_region, true);
}

// ── serialize errors ──
{
  const fresh = await loadArtifact(wasmBytes);
  const res = fresh.serialize();
  assert.equal(res.ok, false, `expected error before init: ${JSON.stringify(res)}`);
  assert.ok(res.error);
}

// ── serialize round-trip ──
{
  const before = game.getState();
  const saved = game.serialize();
  assert.equal(saved.ok, true, `serialize failed: ${JSON.stringify(saved)}`);
  assert.ok(saved.bytes.length > 16, "SUD0 blob too small");

  const fresh = await loadArtifact(wasmBytes);
  assert.equal(fresh.init({ difficulty: 1 }).ok, true);

  const loaded = fresh.deserialize(saved.bytes);
  assert.equal(loaded.ok, true, `deserialize failed: ${JSON.stringify(loaded)}`);
  assert.deepEqual(fresh.getState(), before, "deserialize did not restore state");
}

// ── newGame returns fresh state for re-render ──
{
  const before = game.getState();
  const idx = before.cells.findIndex((c) => c.value === 0 && !c.given);
  assert.ok(idx >= 0, "no fillable cell");
  const row = Math.floor(idx / 9);
  const col = idx % 9;

  const fill = game.exec({ action: "fill", row, col, digit: 7 });
  assert.equal(fill.ok, true);
  assert.equal(fill.state.cells[idx].value, 7);

  const result = newGame(game, { difficulty: 2, logLevel: 1 });
  assert.equal(result.ok, true, `newGame failed: ${JSON.stringify(result)}`);
  assert.deepEqual(result.state, game.getState());
  assert.deepEqual(result.legend, game.getLegend());
  assert.deepEqual(result.config, game.getConfig());
  assert.equal(result.state.cells[idx].value, before.cells[idx].value, "new clears mutations");
  assert.equal(result.legend.undo, false);
  assert.equal(result.config.difficulty, 2);
}

// ── shell session round-trip ──
{
  const before = game.getState();
  const configBefore = game.getConfig();
  const saved = save(game);
  assert.equal(saved.ok, true);
  assert.ok(saved.bytes.length > 16);

  const restored = open(game, saved.bytes);
  assert.equal(restored.ok, true);
  assert.deepEqual(game.getState(), before);
  assert.deepEqual(game.getConfig(), configBefore, "view config survives open on same instance");

  const fresh = await loadArtifact(wasmBytes);
  const started = newGame(fresh, { difficulty: 2 });
  assert.equal(started.ok, true);
  assert.equal(started.config.theme, "dark");
  assert.equal(started.config.difficulty, 2);
  const freshOpen = open(fresh, saved.bytes);
  assert.equal(freshOpen.ok, true);
  assert.deepEqual(fresh.getState(), before);
  assert.equal(fresh.getConfig().theme, "dark", "SUD0 does not carry view config");
}

// ── quit ──
{
  const res = game.exec({ action: "quit" });
  assert.equal(res.ok, true);
  assert.equal(res.is_quit, true);
}

console.log("glue.test.mjs OK");
