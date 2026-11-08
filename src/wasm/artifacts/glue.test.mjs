// glue.test.mjs — wasm glue + shell session contract.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import * as glue from "./glue.js";
import { openBytes, runConfigCommand, startNewGame } from "../test_support.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const wasmBytes = readFileSync(join(here, "artifact.wasm"));

const game = await glue.loadArtifact(wasmBytes);

/** Fixed easy grid — live `init` gen is non-deterministic; unsolvable-move tests need this. */
const EASY_FIXTURE =
  "003020600900305001001806400008102900700000008006708200002609500800203009005010300";

assert.equal(game.exports.step, undefined, "REPL step export must be gone");

// ── host startup config (CLI / disk analogue) drives the Config ──
{
  const hostGame = await glue.loadArtifact(wasmBytes);
  const boot = hostGame.bootstrapHostConfig({
    difficulty: 3,
    logLevel: 2,
    theme: "light",
    show_region: true,
    warn_solvability: true,
    auto_restore: true,
    auto_new: true,
    auto_save: true,
  });
  assert.equal(boot.ok, true, `bootstrapHostConfig failed: ${JSON.stringify(boot)}`);
  const cfg = hostGame.getConfig();
  assert.equal(cfg.difficulty, 3, "wasm engine difficulty must match host startup wire");
  assert.equal(cfg.log_level, 2, "wasm engine log_level must match host startup wire");
  assert.equal(cfg.theme, "light");
  assert.equal(cfg.show_region, true);
  assert.equal(cfg.warn_solvability, true);
  assert.equal(cfg.auto_restore, true);
  assert.equal(cfg.auto_new, true);
  assert.equal(cfg.auto_save, true);
}

// ── host build info marks the About version on Debug hosts only ──
{
  const buildGame = await glue.loadArtifact(wasmBytes);
  assert.match(buildGame.getAbout().version, /^\d+\.\d+\.\d+$/, "no host build info shows the bare version");
  buildGame.setHostBuildInfo({ debug_build: true });
  assert.match(buildGame.getAbout().version, /^\d+\.\d+\.\d+ debug$/, "a Debug host marks the About version");
  assert.ok(buildGame.getAbout().summary.includes(buildGame.getAbout().version));
  buildGame.setHostBuildInfo({ debug_build: false });
  assert.match(buildGame.getAbout().version, /^\d+\.\d+\.\d+$/, "a release host shows the bare version");
}

// ── bootstrapHostConfig + generatePuzzle (worker handoff) ──
{
  const handoff = await glue.loadArtifact(wasmBytes);
  const boot = handoff.bootstrapHostConfig({
    difficulty: 2,
    logLevel: 1,
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
  });
  assert.equal(boot.ok, true, `bootstrapHostConfig failed: ${JSON.stringify(boot)}`);
  const empty = handoff.getState().cells.every((c) => c.value === 0);
  assert.equal(empty, true, "host bootstrap starts from an empty grid");
  const progress = [];
  handoff.setGenProgressListener((phase, text) => progress.push([phase, text]));
  const gen = handoff.generatePuzzle({ difficulty: 2, logLevel: 1 });
  handoff.setGenProgressListener(null);
  assert.equal(gen.ok, true, `generatePuzzle failed: ${JSON.stringify(gen)}`);
  assert.equal(gen.line.length, 81);
  // Progress text comes from core; the phase only places it in the dialog.
  assert.equal(progress[0][0], 0, "generation opens with a new attempt");
  assert.ok(progress.every(([, text]) => /^[A-Z].*\.$/.test(text)), "every progress line is a sentence from core");
  startNewGame(handoff, gen.line, "medium");
  assert.equal(handoff.getConfig().difficulty, 2, "New takes the chosen difficulty");
}

// ── init (sync main-thread path; glue contract) ──
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

// ── clear dead-end cell then targeted hint → placement on restored grid ──
{
  const fresh = await glue.loadArtifact(wasmBytes);
  assert.equal(fresh.init({ difficulty: 1 }).ok, true);
  assert.equal(startNewGame(fresh, EASY_FIXTURE).loaded, true);
  assert.equal(fresh.exec({ action: "fill", row: 1, col: 1, digit: 8 }).ok, true);
  assert.equal(fresh.exec({ action: "clear", row: 1, col: 1 }).ok, true);
  const hint = fresh.exec({ action: "hint", row: 1, col: 1 });
  assert.equal(hint.ok, true, JSON.stringify(hint));
  assert.match(hint.msg ?? "", /B2 takes [1-9]\./);
}

// ── hint (engine-pick placement must show ASCII digit, not control char) ──
{
  const fresh = await glue.loadArtifact(wasmBytes);
  assert.equal(fresh.init({ difficulty: 1 }).ok, true);
  const res = fresh.exec({ action: "hint" });
  assert.equal(res.ok, true, `hint failed: ${JSON.stringify(res)}`);
  assert.match(res.msg ?? "", / takes [1-9]\./);
  assert.match(res.msg ?? "", /[1-9]/);
  assert.doesNotMatch(res.msg ?? "", /\x08/);
}

// ── hint on dead board: ok msg with no-solution tag (not error) ──
{
  const fresh = await glue.loadArtifact(wasmBytes);
  assert.equal(fresh.init({ difficulty: 1 }).ok, true);
  assert.equal(startNewGame(fresh, EASY_FIXTURE).loaded, true);
  assert.equal(fresh.exec({ action: "fill", row: 1, col: 1, digit: 8 }).ok, true);
  const pick = fresh.exec({ action: "hint" });
  assert.equal(pick.ok, true, JSON.stringify(pick));
  assert.match(pick.msg ?? "", /no solution/i);
  assert.equal(pick.error, undefined);
  const targeted = fresh.exec({ action: "hint", row: 1, col: 1 });
  assert.equal(targeted.ok, true, JSON.stringify(targeted));
  assert.match(targeted.msg ?? "", /no solution/i);
  assert.match(targeted.msg ?? "", /B2/);
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
  assert.equal(config.theme, "system");
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
  assert.equal(config.theme, "system");
  assert.equal(config.show_region, false);
  assert.equal(config.warn_solvability, false);

  runConfigCommand(game, { action: "set_theme", theme: "light" });
  config = game.getConfig();
  assert.equal(config.theme, "light");

  runConfigCommand(game, { action: "toggle_region" });
  config = game.getConfig();
  assert.equal(config.show_region, true);
}

// ── toSaveFormat errors ──
{
  const fresh = await glue.loadArtifact(wasmBytes);
  const res = fresh.toSaveFormat();
  assert.equal(res.ok, false, `expected error before init: ${JSON.stringify(res)}`);
  assert.ok(res.error);
}

// ── toSaveFormat round-trip ──
{
  const before = game.getState();
  const saved = game.toSaveFormat();
  assert.equal(saved.ok, true, `toSaveFormat failed: ${JSON.stringify(saved)}`);
  assert.ok(saved.bytes.length > 16, "SUD0 blob too small");

  const fresh = await glue.loadArtifact(wasmBytes);
  assert.equal(fresh.init({ difficulty: 1 }).ok, true);

  const loaded = openBytes(fresh, saved.bytes);
  assert.equal(loaded.text, null, "solvable load should not warn");
  const opened = fresh.getState();
  assert.deepEqual(opened.cells, before.cells, "open did not restore the board");
  assert.equal(opened.selected, null, "open drops the selection");
  assert.equal(opened.region, null, "nothing selected shades nothing");
}

// ── open warns on dead puzzle (same as native open) ──
{
  const dead = await glue.loadArtifact(wasmBytes);
  assert.equal(dead.init({ difficulty: 1 }).ok, true);
  runConfigCommand(dead, { action: "toggle_warn_solvability" });
  assert.equal(startNewGame(dead, EASY_FIXTURE).loaded, true);
  const bad = dead.exec({ action: "fill", row: 1, col: 1, digit: 8 });
  assert.equal(bad.ok, true);
  assert.match(bad.msg ?? "", /no solution/i);
  assert.doesNotMatch(bad.msg ?? "", / should be /);
  const saved = dead.toSaveFormat();
  assert.equal(saved.ok, true);

  const fresh = await glue.loadArtifact(wasmBytes);
  assert.equal(fresh.init({ difficulty: 1 }).ok, true);
  runConfigCommand(fresh, { action: "toggle_warn_solvability" });
  const loaded = openBytes(fresh, saved.bytes);
  assert.match(loaded.text ?? "", /no solution/i);

  const named = await glue.loadArtifact(wasmBytes);
  assert.equal(named.init({ difficulty: 1 }).ok, true);
  runConfigCommand(named, { action: "toggle_warn_solvability" });
  const opened = openBytes(named, saved.bytes, "dead.sud");
  assert.match(opened.text ?? "", /The file dead\.sud is open\./);
  assert.match(opened.text ?? "", /no solution/i);
  assert.equal(opened.file, "dead.sud");
}

// ── New shows the fresh game for re-render ──
{
  const before = game.getState();
  const idx = before.cells.findIndex((c) => c.value === 0 && !c.given);
  assert.ok(idx >= 0, "no fillable cell");
  const row = Math.floor(idx / 9);
  const col = idx % 9;

  const fill = game.exec({ action: "fill", row, col, digit: 7 });
  assert.equal(fill.ok, true);
  assert.equal(fill.state.cells[idx].value, 7);

  const result = startNewGame(game, EASY_FIXTURE, "medium");
  assert.equal(result.loaded, true);
  assert.deepEqual(result.state, game.getState());
  assert.deepEqual(result.legend, game.getLegend());
  assert.deepEqual(result.config, game.getConfig());
  assert.notEqual(result.state.cells[idx].value, 7, "new clears player fill");
  assert.notDeepEqual(result.state, fill.state, "new replaces board");
  assert.equal(result.legend.undo, false);
  assert.equal(result.config.difficulty, 2);
}

// ── shell session round-trip ──
{
  const before = game.getState();
  const configBefore = game.getConfig();
  const saved = game.toSaveFormat();
  assert.equal(saved.ok, true);
  assert.ok(saved.bytes.length > 16);

  openBytes(game, saved.bytes);
  assert.deepEqual(game.getState(), before);
  assert.deepEqual(game.getConfig(), configBefore, "view config survives open on same instance");

  const fresh = await glue.loadArtifact(wasmBytes);
  assert.equal(fresh.init({ difficulty: 2, logLevel: 1 }).ok, true);
  const started = startNewGame(fresh, EASY_FIXTURE, "medium");
  assert.equal(started.config.theme, "system");
  assert.equal(started.config.difficulty, 2);
  openBytes(fresh, saved.bytes);
  assert.deepEqual(fresh.getState(), before);
  assert.equal(fresh.getConfig().theme, "system", "SUD0 does not carry view config");
}

// ── quit ──
{
  const res = game.exec({ action: "quit" });
  assert.equal(res.ok, true);
  assert.equal(res.is_quit, true);
}

// ── toPuzzle ──
{
  const fresh = await glue.loadArtifact(wasmBytes);
  const res = fresh.toPuzzle();
  assert.equal(res.ok, false, "export before init should fail");
  assert.ok(res.error);

  assert.equal(fresh.init({ difficulty: 1 }).ok, true);
  let exported = fresh.toPuzzle();
  assert.equal(exported.ok, true, `toPuzzle failed: ${JSON.stringify(exported)}`);
  assert.equal(exported.bytes.length, 81);

  assert.equal(startNewGame(fresh, EASY_FIXTURE).loaded, true);
  exported = fresh.toPuzzle();
  assert.equal(new TextDecoder().decode(exported.bytes), EASY_FIXTURE);

  const idx = fresh.getState().cells.findIndex((c) => c.value === 0 && !c.given);
  assert.ok(idx >= 0);
  const row = Math.floor(idx / 9);
  const col = idx % 9;
  assert.equal(fresh.exec({ action: "fill", row, col, digit: 4 }).ok, true);
  const afterFill = fresh.toPuzzle();
  assert.equal(afterFill.ok, true);
  const line = new TextDecoder().decode(afterFill.bytes);
  assert.notEqual(line, EASY_FIXTURE);
  assert.equal(startNewGame(fresh, line).loaded, true);
}

console.log("glue.test.mjs OK");
