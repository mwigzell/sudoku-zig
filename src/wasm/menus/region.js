// region.js — View menu region highlight via engine config.

import * as board from "../board.js";
import * as settings from "./settings.js";

/** @typedef {import("../types").FlowHandlers} FlowHandlers */

export function syncRegionMenu(controls, config) {
  if (!controls.viewRegion) return;
  const enabled = config?.show_region === true;
  controls.viewRegion.setAttribute("aria-checked", enabled ? "true" : "false");
  controls.viewRegion.classList.toggle("selected", enabled);
}

/**
 * View → Show Region: core shades the selected cell's region in the snapshot it returns.
 * @param {{ onChange?: () => void, steps: FlowHandlers, createElement?: (tag: string) => HTMLElement }} [options]
 */
export function wireRegionMenu(
  controls,
  game,
  session,
  boardEl,
  { onChange, steps, createElement } = {},
) {
  const sync = () => syncRegionMenu(controls, session.config);

  const toggle = () =>
    board.runBoardCommand(game, settings.toggleConfigAction(session.config, settings.SHOW_REGION_FIELD), {
      boardEl,
      createElement,
      steps,
      onShown: () => {
        sync();
        onChange?.();
      },
    });

  controls.viewRegion?.addEventListener("click", () => {
    void toggle();
  });

  sync();

  return {
    isEnabled: () => session.config.show_region === true,
    sync,
    toggle,
  };
}
