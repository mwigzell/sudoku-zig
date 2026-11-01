// region.js — View menu region highlight via engine config.

import { applyRegionHighlight } from "./board.js";
import { applyConfigOutcomeStatus, persistSettingsAfter } from "./shell.js";

/** @typedef {import("./types").FlowHandlers} FlowHandlers */

const SET_REGION = "set_region";

export function syncRegionMenu(controls, config) {
  if (!controls.viewRegion) return;
  const enabled = config?.show_region === true;
  controls.viewRegion.setAttribute("aria-checked", enabled ? "true" : "false");
  controls.viewRegion.classList.toggle("selected", enabled);
}

/**
 * @param {{ onChange?: () => void, settingsFlow?: FlowHandlers, statusEl?: HTMLElement }} [options]
 */
export function wireRegionMenu(
  controls,
  game,
  session,
  boardEl,
  getSelection,
  { onChange, settingsFlow, statusEl } = {},
) {
  const syncBoard = () => {
    syncRegionMenu(controls, session.config);
    const sel = getSelection();
    if (sel) {
      applyRegionHighlight(boardEl, sel.row, sel.col, session.config.show_region === true);
    } else {
      applyRegionHighlight(boardEl, null, null, false);
    }
  };

  controls.viewRegion?.addEventListener("click", () => {
    void (async () => {
      const next = !session.config.show_region;
      const result = game.exec({ action: SET_REGION, enabled: next });
      if (!applyConfigOutcomeStatus(session, game, statusEl, result)) return;
      syncBoard();
      onChange?.();
      await persistSettingsAfter(game, SET_REGION, settingsFlow);
    })();
  });

  syncBoard();

  return {
    isEnabled: () => session.config.show_region === true,
    sync: syncBoard,
  };
}
