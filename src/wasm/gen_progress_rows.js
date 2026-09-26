// gen_progress_rows.js — progressive generating modal rows (wire phase → slots I–V).

import { formatGenProgress } from "./gen_progress_format.js";

/** Row slots I–IV are live; V is reserved (model only, not mounted in DOM). */
export const GEN_PROGRESS_ROW_COUNT = 5;
export const GEN_PROGRESS_DOM_ROW_COUNT = 4;
export const GEN_PROGRESS_ROW_CLASS = "gen-progress-row";
export const GEN_PROGRESS_ATTEMPT_HINT_CLASS = "gen-progress-attempt-hint";
export const GEN_PROGRESS_HINT_FAST = "Fast strip";
export const GEN_PROGRESS_HINT_DIG_HOLE = "Dig-hole fallback";

/** Empty row slots before the first progress event. */
export function createGenProgressRowState() {
  return { rows: ["", "", "", "", ""], attemptHint: "" };
}

function attemptHintForPhase(phase, priorHint) {
  switch (phase) {
    case 0:
      return "";
    case 1:
      return GEN_PROGRESS_HINT_DIG_HOLE;
    case 2:
      return priorHint === GEN_PROGRESS_HINT_DIG_HOLE ? priorHint : GEN_PROGRESS_HINT_FAST;
    default:
      return priorHint;
  }
}

function rowIndexForPhase(phase) {
  switch (phase) {
    case 0:
      return 0;
    case 1:
    case 2:
      return 1;
    case 3:
    case 4:
      return 2;
    case 5:
      return 3;
    default:
      return 0;
  }
}

/** Apply one `(phase, a, b)` event; update the active row and clear deeper slots. */
export function applyGenProgressRowEvent(state, phase, a, b) {
  const rows = state.rows.slice();
  const depth = rowIndexForPhase(phase);
  rows[depth] = formatGenProgress(phase, a, b);
  for (let i = depth + 1; i < GEN_PROGRESS_ROW_COUNT; i += 1) {
    rows[i] = "";
  }
  const attemptHint = attemptHintForPhase(phase, state.attemptHint ?? "");
  return { rows, attemptHint };
}

function defaultCreateElement(tag) {
  return document.createElement(tag);
}

function ensureAttemptHintEl(containerEl, createElement, firstRowEl, secondRowEl) {
  const sel = `.${GEN_PROGRESS_ATTEMPT_HINT_CLASS}`;
  let hintEl =
    typeof containerEl.querySelector === "function" ? containerEl.querySelector(sel) : null;
  if (hintEl) return hintEl;
  hintEl = createElement("div");
  hintEl.classList.add(GEN_PROGRESS_ATTEMPT_HINT_CLASS);
  hintEl.hidden = true;
  const anchor = secondRowEl ?? firstRowEl?.nextSibling ?? null;
  if (typeof containerEl.insertBefore === "function" && anchor) {
    containerEl.insertBefore(hintEl, anchor);
  } else {
    containerEl.appendChild(hintEl);
  }
  return hintEl;
}

/** Create five row slot elements under the generating modal progress container. */
export function ensureProgressRowSlots(containerEl, createElement = defaultCreateElement) {
  const existing =
    typeof containerEl.querySelectorAll === "function"
      ? containerEl.querySelectorAll(`.${GEN_PROGRESS_ROW_CLASS}`)
      : [];
  if (existing.length === GEN_PROGRESS_DOM_ROW_COUNT) {
    ensureAttemptHintEl(containerEl, createElement, existing[0], existing[1]);
    return [...existing];
  }
  containerEl.replaceChildren?.();
  const slots = [];
  for (let i = 0; i < GEN_PROGRESS_DOM_ROW_COUNT; i += 1) {
    const row = createElement("div");
    row.classList.add(GEN_PROGRESS_ROW_CLASS);
    row.hidden = true;
    containerEl.appendChild(row);
    slots.push(row);
  }
  ensureAttemptHintEl(containerEl, createElement, slots[0], slots[1]);
  return slots;
}

/** Paint row model state; hide slot elements with no text. */
export function renderGenProgressRows(containerEl, state, createElement) {
  const slots = ensureProgressRowSlots(containerEl, createElement);
  const hintEl = ensureAttemptHintEl(containerEl, createElement, slots[0], slots[1]);
  for (let i = 0; i < GEN_PROGRESS_DOM_ROW_COUNT; i += 1) {
    const text = state.rows[i] ?? "";
    slots[i].textContent = text;
    slots[i].hidden = text.length === 0;
  }
  const hint = state.attemptHint ?? "";
  hintEl.textContent = hint;
  hintEl.hidden = hint.length === 0;
}

/** Show or hide the progress block (`#generating-progress-rows`). */
export function setProgressRowsVisible(containerEl, visible) {
  if (containerEl?.style) {
    containerEl.style.display = visible ? "block" : "none";
  }
}

/** Feed `(phase, a, b)` wire events into a modal wired with `renderProgressRows`. */
export function createGenProgressModalSink(modal) {
  let state = createGenProgressRowState();
  return {
    push(phase, a, b) {
      state = applyGenProgressRowEvent(state, phase, a, b);
      modal.renderProgressRows(state);
    },
  };
}
