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

export function wireSelection(boardEl, { row = 0, col = 0, onSelect } = {}) {
  let selected = { row, col };

  const select = (nextRow, nextCol) => {
    selected = applySelection(boardEl, nextRow, nextCol);
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
