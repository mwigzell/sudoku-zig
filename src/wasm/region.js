// region.js — View menu region highlight toggle (#8).

import { applyRegionHighlight } from "./board.js";

export const REGION_STORAGE_KEY = "sudoku-region-highlight";

export function readRegionEnabled(storage = globalThis.localStorage) {
  try {
    return storage?.getItem(REGION_STORAGE_KEY) === "true";
  } catch {
    return false;
  }
}

export function writeRegionEnabled(enabled, storage = globalThis.localStorage) {
  try {
    storage?.setItem(REGION_STORAGE_KEY, enabled ? "true" : "false");
  } catch {
    /* ignore */
  }
}

export function syncRegionMenu(controls, enabled) {
  if (!controls.viewRegion) return;
  controls.viewRegion.setAttribute("aria-checked", enabled ? "true" : "false");
  controls.viewRegion.classList.toggle("selected", enabled);
}

export function wireRegionMenu(
  controls,
  getSelection,
  boardEl,
  { storage = globalThis.localStorage } = {},
) {
  let enabled = readRegionEnabled(storage);
  syncRegionMenu(controls, enabled);

  const syncBoard = () => {
    const { row, col } = getSelection();
    applyRegionHighlight(boardEl, row, col, enabled);
  };

  controls.viewRegion?.addEventListener("click", () => {
    enabled = !enabled;
    syncRegionMenu(controls, enabled);
    writeRegionEnabled(enabled, storage);
    syncBoard();
  });

  syncBoard();

  return {
    isEnabled: () => enabled,
    sync: syncBoard,
  };
}
