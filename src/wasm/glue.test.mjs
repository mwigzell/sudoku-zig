// glue.test.mjs — the wasm/JS boundary contract, driven end to end.
// Bare node script: `node src/wasm/glue.test.mjs`. No npm deps, no browser.
//
// Each section gets a fresh instantiation. The step contract:
//   _start  → initial board + legend via page_bytes_out
//   step(line) → { text, done } — one command turn, done = 1 on quit
// Board cell values are parsed out of the artifact's own output, never hardcoded.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { loadArtifact } from "./glue.js";

const here = dirname(fileURLToPath(import.meta.url));
const wasmBytes = readFileSync(join(here, "artifact.wasm"));

const LEGEND_LINE = "  Command: (F)ill (C)lear (Q)uit (S)ave (O)pen (N)ew (Sa)veAs";

// Row format (styler.zig): "{d}│ {c} {c} {c} │ {c} {c} {c} │ {c} {c} {c} │"
// → 9 cell chars in order; empty cells stay " ".
const parseCells = (rowText) => {
  const m = rowText.match(/^[1-9]│(.*)$/);
  const cells = [];
  for (const g of m[1].split("│")) if (g.length >= 6) cells.push(g[1], g[3], g[5]);
  return cells;
};
const gridRows = (text) => text.split("\n").filter((l) => /^[1-9]│/.test(l));
const isGridTurn = (text) => gridRows(text).length === 9;
const newGame = async () => {
  const game = await loadArtifact(wasmBytes);
  game.start();
  return game;
};

// ── initial render: grid + legend, straight out of _start ──
{
  const game = await newGame();
  const gridTurn = game.turns.find(isGridTurn);
  assert.ok(gridTurn, `no turn with 9 box-drawn grid rows; turns=${JSON.stringify(game.turns)}`);
  assert.equal(gridRows(gridTurn).length, 9, "expected 9 grid rows");

  const legendTurn = game.turns.find((t) => t.includes(LEGEND_LINE));
  assert.ok(legendTurn, `legend line missing; turns=${JSON.stringify(game.turns)}`);
}

// ── Fill <cell> <digit> — the digit lands at its row/col in the turn text ──
{
  const game = await newGame();
  const gridTurn = game.turns.find(isGridTurn);
  const rows = gridRows(gridTurn);
  const empty = rows
    .map(parseCells)
    .flatMap((cells, rowIdx) => cells.map((ch, colIdx) => ({ ch, rowIdx, colIdx })))
    .filter((e) => e.ch === " ");
  assert.ok(empty.length > 0, `no empty cells in the initial grid: ${JSON.stringify(rows)}`);

  // An empty cell may still be a given one — try each until the fill lands.
  let landed = false;
  for (const { rowIdx, colIdx } of empty) {
    const coord = String.fromCharCode(65 + colIdx) + String(rowIdx + 1);
    game.turns.length = 0;
    const turn = game.step(`Fill ${coord} 3`);
    if (turn.done || /failed/.test(turn.text)) continue;
    const rowsAfter = game.turns.map(gridRows).find((r) => r.length === 9);
    assert.ok(rowsAfter, `no grid re-render after Fill ${coord}: ${JSON.stringify(game.turns)}`);
    assert.equal(
      parseCells(rowsAfter[rowIdx])[colIdx],
      "3",
      `digit 3 not at cell ${coord} after fill: row="${rowsAfter[rowIdx]}"`,
    );
    landed = true;
    break;
  }
  assert.ok(landed, `no empty cell accepted Fill (gave up on ${empty.length} candidates)`);
}

// ── unknown command — the renderer's error text appears across the boundary ──
{
  const game = await newGame();
  const turn = game.step("XYZZY");
  assert.equal(turn.done, false, "an unknown command must not end the session");
  assert.ok(
    turn.text.includes('unknown command "XYZZY"'),
    `unknown-command error text missing: ${JSON.stringify(turn.text)}`,
  );
}

// ── Quit — the done flag ends the session ──
{
  const game = await newGame();
  const turn = game.step("Quit");
  assert.equal(turn.done, true, `Quit must set the done flag; text=${JSON.stringify(turn.text)}`);
}

console.log("glue.test.mjs OK");
