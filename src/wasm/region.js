// region.js — View menu region highlight via engine config (#8).

import { applyRegionHighlight } from "./board.js";

export function syncRegionMenu(controls, config) {
  if (!controls.viewRegion) return;
  const enabled = config?.show_region === true;
  controls.viewRegion.setAttribute("aria-checked", enabled ? "true" : "false");
  controls.viewRegion.classList.toggle("selected", enabled);
}

export function wireRegionMenu(
  controls,
  game,
  session,
  boardEl,
  getSelection,
  { onChange } = {},
) {
  const syncBoard = () => {
    syncRegionMenu(controls, session.config);
    const { row, col } = getSelection();
    applyRegionHighlight(boardEl, row, col, session.config.show_region === true);
  };

  controls.viewRegion?.addEventListener("click", () => {
    const next = !session.config.show_region;
    const result = game.exec({ action: "set_region", enabled: next });
    if (!result.ok) return;
    session.config = game.getConfig();
    syncBoard();
    onChange?.();
  });

  syncBoard();

  return {
    isEnabled: () => session.config.show_region === true,
    sync: syncBoard,
  };
}
