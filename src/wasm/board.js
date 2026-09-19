// board.js — DOM board shell: render GameSnapshot, selection, play loop.

import { applyEventStatus, applyExecResult } from "./shell.js";

export { applyEventStatus };

const GRID_SIZE = 9;

export function cellIndex(row, col) {
  return row * GRID_SIZE + col;
}

export function cellsInRegion(row, col) {
  const boxRow = Math.floor(row / 3) * 3;
  const boxCol = Math.floor(col / 3) * 3;
  const indices = new Set();
  for (let c = 0; c < GRID_SIZE; c += 1) indices.add(cellIndex(row, c));
  for (let r = 0; r < GRID_SIZE; r += 1) indices.add(cellIndex(r, col));
  for (let r = boxRow; r < boxRow + 3; r += 1) {
    for (let c = boxCol; c < boxCol + 3; c += 1) indices.add(cellIndex(r, c));
  }
  return indices;
}

export function applyRegionHighlight(boardEl, row, col, enabled) {
  const region = enabled ? cellsInRegion(row, col) : null;
  for (const cell of boardEl.children) {
    cell.classList.remove("region");
    if (!region) continue;
    const r = Number(cell.dataset.row);
    const c = Number(cell.dataset.col);
    if (region.has(cellIndex(r, c))) cell.classList.add("region");
  }
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

export function boardCellDescriptors(state) {
  return state.cells.map((cell, index) => {
    const row = Math.floor(index / GRID_SIZE);
    const col = index % GRID_SIZE;
    return {
      row,
      col,
      cell,
      classes: cellClasses(row, col, cell),
      text: formatDigit(cell),
    };
  });
}

export function renderBoard(boardEl, state, createElement = (tag) => document.createElement(tag)) {
  const cells = boardCellDescriptors(state).map(({ row, col, classes, text }) => {
    const el = createElement("div");
    el.classList.add(...classes);
    el.textContent = text;
    el.dataset.row = String(row);
    el.dataset.col = String(col);
    el.setAttribute("role", "gridcell");
    return el;
  });
  boardEl.replaceChildren(...cells);
}

export function setStatus(statusEl, message, { error = false } = {}) {
  statusEl.textContent = message;
  statusEl.className = error ? "error" : "";
}

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

export function findCellElement(boardEl, row, col) {
  for (const cell of boardEl.children) {
    if (Number(cell.dataset.row) === row && Number(cell.dataset.col) === col) return cell;
  }
  return null;
}

export function applySelection(boardEl, row, col) {
  for (const cell of boardEl.children) {
    cell.classList.remove("selected");
  }
  const target = findCellElement(boardEl, row, col);
  if (target) target.classList.add("selected");
  return { row, col };
}

const ARROW_KEYS = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]);

export function wireSelection(boardEl, { row = 0, col = 0, onSelect, regionEnabled } = {}) {
  let selected = { row, col };

  const syncRegion = (nextRow, nextCol) => {
    if (regionEnabled) applyRegionHighlight(boardEl, nextRow, nextCol, regionEnabled());
  };

  const select = (nextRow, nextCol) => {
    selected = applySelection(boardEl, nextRow, nextCol);
    syncRegion(nextRow, nextCol);
    onSelect?.(selected);
    return selected;
  };

  boardEl.tabIndex = 0;

  boardEl.addEventListener("click", (event) => {
    const target = event.target;
    if (target?.dataset?.row == null || target?.dataset?.col == null) return;
    select(Number(target.dataset.row), Number(target.dataset.col));
  });

  boardEl.addEventListener("keydown", (event) => {
    if (!ARROW_KEYS.has(event.key)) return;
    event.preventDefault();
    const next = moveSelection(selected.row, selected.col, event.key);
    select(next.row, next.col);
  });

  select(row, col);

  return {
    getSelection() {
      return { ...selected };
    },
    select,
  };
}

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

export function applySuccessfulExec(boardEl, selection, statusEl, result, createElement) {
  renderBoard(boardEl, result.state, createElement);
  const { row, col } = selection.getSelection();
  selection.select(row, col);
  applyEventStatus(statusEl, result);
}

export function handlePlayKey(
  game,
  boardEl,
  selection,
  statusEl,
  errorModal,
  key,
  session,
  createElement,
  code = "",
) {
  const play = parsePlayKey(key, code);
  if (!play) return { handled: false };

  const { row, col } = selection.getSelection();
  const result =
    play.type === "fill"
      ? game.exec({ action: "fill", row, col, digit: play.digit })
      : game.exec({ action: "clear", row, col });

  if (!result.ok) {
    applyExecResult(statusEl, errorModal, result);
    return { handled: true };
  }

  applySuccessfulExec(boardEl, selection, statusEl, result, createElement);
  session.state = result.state;
  session.legend = game.getLegend();
  return { handled: true, legend: session.legend };
}

export function wirePlayLoop(
  boardEl,
  game,
  selection,
  statusEl,
  errorModal,
  session,
  { onLegendChange } = {},
) {
  boardEl.addEventListener(
    "keydown",
    (event) => {
      const outcome = handlePlayKey(
        game,
        boardEl,
        selection,
        statusEl,
        errorModal,
        event.key,
        session,
        undefined,
        event.code,
      );
      if (!outcome.handled) return;
      event.preventDefault();
      if (outcome.legend) onLegendChange?.(outcome.legend);
    },
    { capture: true },
  );

  return {
    getState() {
      return session.state;
    },
    getLegend() {
      return session.legend;
    },
  };
}
