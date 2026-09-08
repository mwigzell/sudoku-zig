// glue.test.mjs — slice 8a test for the wasm/JS boundary glue.
// Bare node script: `node src/wasm/glue.test.mjs`. No npm deps, no browser.
//
// Drives src/wasm/artifact.wasm through glue.js across the real import
// table (module "env"). Board cell values are parsed out of the artifact's
// own output, never hardcoded.

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

// ── turn 1: grid + legend, straight out of _start ──
{
  const game = await loadArtifact(wasmBytes);
  game.start();

  const gridTurn = game.turns.find(isGridTurn);
  assert.ok(gridTurn, `no turn with 9 box-drawn grid rows; turns=${JSON.stringify(game.turns)}`);
  const rows = gridRows(gridTurn);
  assert.equal(rows.length, 9, `expected 9 grid rows, got ${rows.length}`);
  for (const r of rows) assert.ok(r.includes("│"), `grid row missing │: ${r}`);

  const legendTurn = game.turns.find((t) => t.includes(LEGEND_LINE));
  assert.ok(legendTurn, `legend line missing; turns=${JSON.stringify(game.turns)}`);

  // Pick a provably-empty cell (char = space) from this grid.
  const cellChars = rows.map(parseCells);
  const empty = cellChars
    .flatMap((cells, rowIdx) => cells.map((ch, colIdx) => ({ ch, rowIdx, colIdx })))
    .find((e) => e.ch === " ");
  assert.ok(empty, `no empty (space) cell in ${JSON.stringify(cellChars)}`);
  globalThis.__EMPTY_CELL__ = {
    coord: String.fromCharCode(65 + empty.colIdx) + String(empty.rowIdx + 1),
    rowIdx: empty.rowIdx,
    colIdx: empty.colIdx,
    digit: "3",
  };
}

// ── Fill <cell> <digit> — the digit lands at its row/col in the next grid turn ──
{
  const cell = globalThis.__EMPTY_CELL__;
  const game = await loadArtifact(wasmBytes);
  game.pushLine(`Fill ${cell.coord} ${cell.digit}`);
  game.start();

  const grids = game.turns.filter(isGridTurn);
  assert.ok(
    grids.length >= 2,
    `expected an initial + a post-fill grid turn; turns=${JSON.stringify(game.turns)}`,
  );

  const before = parseCells(gridRows(grids[0])[cell.rowIdx]);
  const landed = parseCells(gridRows(grids[1])[cell.rowIdx]);
  assert.equal(before[cell.colIdx], " ", "chosen cell should start empty");
  assert.equal(
    landed[cell.colIdx],
    cell.digit,
    `digit ${cell.digit} not at cell ${cell.coord} after fill: row="${gridRows(grids[1])[cell.rowIdx]}"`,
  );
}

// ── unknown command — the renderer's error text appears across the boundary ──
{
  const game = await loadArtifact(wasmBytes);
  game.pushLine("XYZZY");
  game.start();

  // Literal captured by driving the artifact once (spec; not recomputed here).
  const errLiteral = 'unknown command "XYZZY"';
  assert.ok(
    game.turns.includes(errLiteral),
    `unknown-command error text missing; turns=${JSON.stringify(game.turns)}`,
  );
}

console.log("glue.test.mjs OK");
