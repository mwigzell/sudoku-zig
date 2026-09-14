// board.js — DOM board shell: render GameSnapshot, status bar helpers (#37).

const GRID_SIZE = 9;

export function cellIndex(row, col) {
  return row * GRID_SIZE + col;
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
