// wasm/shell.js — web session file UX (save/open/new/save_as analogs).
// Uses glue's gameplay API + serialize/deserialize; no SUD0 parsing here.

/** Save current game — returns opaque SUD0 bytes. */
export function save(game) {
  const bytes = game.serialize();
  return { ok: true, bytes };
}

/** Save-as is the same bytes path until a picker supplies a target name. */
export function saveAs(game) {
  return save(game);
}

/** Restore game state from opaque SUD0 bytes. */
export function open(game, bytes) {
  const result = game.deserialize(bytes);
  if (!result.ok) return result;
  return { ok: true, state: game.getState() };
}

/** Start a fresh game at the given difficulty (PlayerDifficulty wire values). */
export function newGame(game, { difficulty = 1, logLevel = 1 } = {}) {
  const result = game.init({ difficulty, logLevel });
  if (!result.ok) return result;
  return { ok: true, state: game.getState(), legend: game.getLegend() };
}
