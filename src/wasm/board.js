// board.js — DOM board shell: render GameSnapshot (with core's selection and region), select input, play loop.

import * as stepRunner from "./flows/step_runner.js";

/** @typedef {import("./types").GameApi} GameApi */
/** @typedef {import("./types").FlowHandlers} FlowHandlers */
/** @typedef {import("./types").FlowStep} FlowStep */

const GRID_SIZE = 9;
export const FRAME_SIZE = 11;
export const PLAY_OFFSET = 1;
export const GUTTER_FR = 1;
export const PLAY_FR = 2;
export const COLUMN_LETTERS = "ABCDEFGHI";

export function getPlayGrid(frameEl) {
  return frameEl.querySelector(".board-play");
}

/** Build symmetric frame shell once; return inner 9×9 play grid. */
export function ensureBoardFrame(frameEl, createElement = (tag) => document.createElement(tag)) {
  if (typeof frameEl.querySelector === "function") {
    const existing = getPlayGrid(frameEl);
    if (existing) return existing;
  }

  frameEl.classList.add("board-frame");
  frameEl.replaceChildren();
  frameEl.setAttribute("role", "group");
  frameEl.setAttribute("aria-label", "Sudoku board");

  const playEnd = PLAY_OFFSET + GRID_SIZE;

  for (let r = 0; r < FRAME_SIZE; r += 1) {
    for (let c = 0; c < FRAME_SIZE; c += 1) {
      if (r >= PLAY_OFFSET && r < playEnd && c >= PLAY_OFFSET && c < playEnd) continue;

      const el = createElement("div");
      el.style.gridRow = String(r + 1);
      el.style.gridColumn = String(c + 1);

      if ((r === 0 || r === playEnd) && c >= PLAY_OFFSET && c < playEnd) {
        el.classList.add("label-cell", "col-label");
        el.textContent = COLUMN_LETTERS[c - PLAY_OFFSET];
      } else if ((c === 0 || c === playEnd) && r >= PLAY_OFFSET && r < playEnd) {
        el.classList.add("label-cell", "row-label");
        el.textContent = String(r - PLAY_OFFSET + 1);
      } else {
        el.classList.add("gutter-cell");
      }
      frameEl.appendChild(el);
    }
  }

  const playEl = createElement("div");
  playEl.classList.add("board-play");
  playEl.setAttribute("role", "grid");
  playEl.style.gridColumn = "2 / 11";
  playEl.style.gridRow = "2 / 11";
  frameEl.appendChild(playEl);
  return playEl;
}

function resolvePlayGrid(boardEl) {
  if (boardEl.classList?.contains("board-play")) return boardEl;
  if (typeof boardEl.querySelector === "function") {
    const play = getPlayGrid(boardEl);
    if (play) return play;
    return ensureBoardFrame(boardEl);
  }
  return boardEl;
}

/** Flat cell index, as core's snapshot numbers cells (`region` lists these). */
export function cellIndex(row, col) {
  return row * GRID_SIZE + col;
}

/** The digits (1..9) marked in a cell's 9-bit `marks`: bit `k` is digit `k + 1`. */
export function markDigits(marks) {
  const digits = [];
  for (let k = 0; k < GRID_SIZE; k += 1) if (marks & (1 << k)) digits.push(k + 1);
  return digits;
}

/** Marks to draw in a cell: only when core says marks are visible, and only in an empty cell. */
function shownMarks(state, cell) {
  return state.marks_visible === true && cell.value === 0 ? (cell.marks ?? 0) : 0;
}

/**
 * A cell's marks as a 3×3 grid of nine slots; a digit always sits in its own slot and an unset one is blank.
 * @param {number} marks
 * @param {(tag: string) => HTMLElement} createElement
 */
function marksGrid(marks, createElement) {
  const grid = createElement("div");
  grid.classList.add("marks");
  for (let k = 0; k < GRID_SIZE; k += 1) {
    const slot = createElement("span");
    if (marks & (1 << k)) slot.textContent = String(k + 1);
    grid.appendChild(slot);
  }
  return grid;
}

export function formatDigit(cell) {
  return cell.value === 0 ? "" : String(cell.value);
}

export function cellClasses(row, col, cell) {
  const classes = ["cell"];
  if (cell.given) classes.push("given");
  else if (cell.value === 0) classes.push("empty");
  else classes.push("player");
  if (cell.conflict) classes.push("conflict");
  if (col % 3 === 2 && col !== GRID_SIZE - 1) classes.push("box-right");
  if (row % 3 === 2 && row !== GRID_SIZE - 1) classes.push("box-bottom");
  return classes;
}

/**
 * What to draw for each cell; the selected cell and its region come from core's snapshot.
 * @param {import("./types").GameState} state
 */
export function boardCellDescriptors(state) {
  const region = new Set(state.region ?? []);
  const selected = state.selected ?? null;
  return state.cells.map((cell, index) => {
    const row = Math.floor(index / GRID_SIZE);
    const col = index % GRID_SIZE;
    const classes = cellClasses(row, col, cell);
    if (selected?.row === row && selected?.col === col) classes.push("selected");
    if (region.has(index)) classes.push("region");
    return {
      row,
      col,
      cell,
      classes,
      text: formatDigit(cell),
      marks: shownMarks(state, cell),
    };
  });
}

export function renderBoard(frameEl, state, createElement = (tag) => document.createElement(tag)) {
  const playEl =
    typeof frameEl.querySelector === "function"
      ? ensureBoardFrame(frameEl, createElement)
      : resolvePlayGrid(frameEl);
  const cells = boardCellDescriptors(state).map(({ row, col, classes, text, marks }) => {
    const el = createElement("div");
    el.classList.add(...classes);
    el.textContent = text;
    if (marks) el.appendChild(marksGrid(marks, createElement));
    el.dataset.row = String(row);
    el.dataset.col = String(col);
    el.setAttribute("role", "gridcell");
    return el;
  });
  playEl.replaceChildren(...cells);
}

export function setStatus(statusEl, message, { error = false, busy = false } = {}) {
  statusEl.textContent = message;
  statusEl.className = error ? "error" : busy ? "generating" : "";
}

/** Arrow-key cursor movement constrained inside the 9x9 play grid. */
export function moveSelection(row, col, key) {
  switch (key) {
    case "ArrowUp":
      return { row: Math.max(0, row - 1), col };
    case "ArrowDown":
      return { row: Math.min(GRID_SIZE - 1, row + 1), col };
    case "ArrowLeft":
      return { row, col: Math.max(0, col - 1) };
    case "ArrowRight":
      return { row, col: Math.min(GRID_SIZE - 1, col + 1) };
    default:
      return { row, col };
  }
}

const ARROW_KEYS = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]);

/**
 * Select the cell at `at` in core, or deselect when `at` is null; the board redraws from core's frame.
 * @param {GameApi} game
 * @param {{ row: number, col: number } | null} at
 * @param {{ boardEl: HTMLElement, createElement?: (tag: string) => HTMLElement, steps: FlowHandlers, onShown?: (step: FlowStep) => void }} options
 */
export function selectCell(game, at, options) {
  const action = at ? { action: "select", row: at.row, col: at.col } : { action: "deselect" };
  return runBoardCommand(game, action, options);
}

/**
 * Tap, tap-again and arrow keys send select and deselect to core; the selection is core's, read from the session.
 * @param {HTMLElement} frameEl
 * @param {{ game: GameApi, session: import("./types").WebSession, steps: FlowHandlers, createElement?: (tag: string) => HTMLElement, onSelect?: () => void }} options
 */
export function wireSelection(frameEl, { game, session, steps, createElement, onSelect }) {
  const playEl = resolvePlayGrid(frameEl);
  /** @returns {{ row: number, col: number } | null} */
  const current = () => session.state?.selected ?? null;
  /** @param {{ row: number, col: number } | null} at */
  const send = (at) => selectCell(game, at, { boardEl: frameEl, createElement, steps, onShown: () => onSelect?.() });

  playEl.tabIndex = 0;

  const cellFromEvent = (event) => {
    const el = event.target?.closest?.("[data-row][data-col]");
    if (!el || !playEl.contains(el)) return null;
    return { row: Number(el.dataset.row), col: Number(el.dataset.col) };
  };

  /** Track press target so click-to-deselect only toggles off when press+click match. */
  let pointerDownCell = null;
  const doc = playEl.ownerDocument ?? globalThis.document;
  doc.addEventListener(
    "pointerdown",
    (event) => {
      if (!playEl.contains(event.target)) pointerDownCell = null;
    },
    { capture: true },
  );
  playEl.addEventListener("pointerdown", (event) => {
    pointerDownCell = cellFromEvent(event);
  });
  playEl.addEventListener("click", (event) => {
    const cell = cellFromEvent(event);
    if (!cell) return;
    const selected = current();
    const sameAsSelected = selected?.row === cell.row && selected?.col === cell.col;
    const sameAsPress = pointerDownCell?.row === cell.row && pointerDownCell?.col === cell.col;
    void send(sameAsSelected && sameAsPress ? null : cell);
  });

  const onArrowKey = (event) => {
    if (!ARROW_KEYS.has(event.key)) return;
    const selected = current();
    if (!selected) return;
    const target = event.target;
    if (typeof target?.closest === "function") {
      if (target.closest("input, textarea, select, [contenteditable=true]")) return;
    }
    event.preventDefault();
    void send(moveSelection(selected.row, selected.col, event.key));
  };

  doc.addEventListener("keydown", onArrowKey);

  return {
    /** Core's selected cell, or null. */
    getSelection() {
      const selected = current();
      return selected ? { ...selected } : null;
    },
    /** @param {number} row @param {number} col */
    select: (row, col) => send({ row, col }),
    deselect: () => send(null),
  };
}

/** Keyboard/pad input parser for gameplay edits (`fill`/`clear`). */
export function parsePlayKey(key, code = "") {
  if (key.length === 1 && key >= "1" && key <= "9") {
    return { type: "fill", digit: Number(key) };
  }
  if (key === "0" || code === "Digit0" || code === "Numpad0") {
    return { type: "clear" };
  }
  if (key === " " || key === "Spacebar" || code === "Space") {
    return { type: "clear" };
  }
  if (
    key === "Delete" ||
    key === "Backspace" ||
    code === "Delete" ||
    code === "Backspace"
  ) {
    return { type: "clear" };
  }
  return null;
}

/**
 * Run a board command through core and redraw from the game core shows.
 * @param {GameApi} game
 * @param {import("./types").ExecAction} action
 * @param {{ boardEl: HTMLElement, createElement?: (tag: string) => HTMLElement, steps: FlowHandlers, onShown?: (step: FlowStep) => void }} options
 */
export function runBoardCommand(game, action, { boardEl, createElement, steps, onShown }) {
  return stepRunner.runCommand(game, action, steps, (step) => {
    renderBoard(boardEl, step.state, createElement);
    onShown?.(step);
  });
}

/**
 * Run one play key against the selected cell through core.
 * @param {GameApi} game
 * @param {{ steps: FlowHandlers, onShown?: (step: FlowStep) => void }} options
 */
export function handlePlayKey(
  game,
  boardEl,
  selection,
  key,
  createElement,
  code,
  { steps, onShown },
) {
  const play = parsePlayKey(key, code);
  if (!play) return { handled: false };
  const sel = selection.getSelection();
  if (!sel) return { handled: false };
  const { row, col } = sel;
  const action =
    play.type === "fill" ? { action: "fill", row, col, digit: play.digit } : { action: "clear", row, col };
  const done = runBoardCommand(game, action, { boardEl, createElement, steps, onShown });
  return { handled: true, done };
}

/**
 * Board key + play-pad event loop that feeds `handlePlayKey` and syncs legend hooks.
 * @param {GameApi} game
 * @param {{ steps: FlowHandlers, onLegendChange?: (legend: Record<string, boolean>) => void, playPadEl?: HTMLElement | null, createElement?: (tag: string) => HTMLElement }} options
 */
export function wirePlayLoop(
  frameEl,
  game,
  selection,
  session,
  { steps, onLegendChange, playPadEl = null, createElement },
) {
  const playEl = resolvePlayGrid(frameEl);
  const runPlayInput = (key, code = "") =>
    handlePlayKey(game, frameEl, selection, key, createElement, code, {
      steps,
      onShown: (step) => onLegendChange?.(step.legend),
    });
  playEl.addEventListener("keydown", (event) => {
    const outcome = runPlayInput(event.key, event.code);
    if (!outcome.handled) return;
    event.preventDefault();
  }, { capture: true });

  if (playPadEl?.querySelectorAll) {
    for (const btn of playPadEl.querySelectorAll("[data-play-key]")) {
      btn.addEventListener("click", () => {
        const key = btn.dataset?.playKey ?? "";
        const code = btn.dataset?.playCode ?? "";
        runPlayInput(key, code);
      });
    }
  }

  return {
    getState() {
      return session.state;
    },
    getLegend() {
      return session.legend;
    },
  };
}
