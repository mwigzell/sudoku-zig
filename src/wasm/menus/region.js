// region.js — View menu region highlight via engine config.

import * as board from "../board.js";
import * as commandFlowMod from "../flows/command_flow.js";

/** @typedef {import("../types").FlowHandlers} FlowHandlers */

const TOGGLE_REGION = "toggle_region";

export function syncRegionMenu(controls, config) {
  if (!controls.viewRegion) return;
  const enabled = config?.show_region === true;
  controls.viewRegion.setAttribute("aria-checked", enabled ? "true" : "false");
  controls.viewRegion.classList.toggle("selected", enabled);
}

/**
 * @param {{ onChange?: () => void, commandFlow?: FlowHandlers }} [options]
 */
export function wireRegionMenu(
  controls,
  game,
  session,
  boardEl,
  getSelection,
  { onChange, commandFlow } = {},
) {
  const syncBoard = () => {
    syncRegionMenu(controls, session.config);
    const sel = getSelection();
    if (sel) {
      board.applyRegionHighlight(boardEl, sel.row, sel.col, session.config.show_region === true);
    } else {
      board.applyRegionHighlight(boardEl, null, null, false);
    }
  };

  controls.viewRegion?.addEventListener("click", () => {
    void commandFlowMod.runSessionCommand(game, { action: TOGGLE_REGION }, commandFlow, () => {
      syncBoard();
      onChange?.();
    });
  });

  syncBoard();

  return {
    isEnabled: () => session.config.show_region === true,
    sync: syncBoard,
  };
}
