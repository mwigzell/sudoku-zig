// menu_bar.js — top menu bar: legend-driven enablement; Config items labelled from core's config table.

import * as settings from "./settings.js";

/** @typedef {import("../types").Config} Config */
/** @typedef {import("../types").ConfigTable} ConfigTable */

/** Wasm legend JSON key — pairs with Zig `Legend.@"export"` / `CommandTag.@"export"` (see legend.zig). */
export const LEGEND_WIRE_EXPORT = "export";
export const LEGEND_WIRE_OPEN = "open";
export const LEGEND_WIRE_IMPORT = "import";
export const LEGEND_WIRE_SAVE = "save";
export const LEGEND_WIRE_SAVE_AS = "save_as";
export const LEGEND_WIRE_COPY = "copy";
export const LEGEND_WIRE_PASTE = "paste";

/** Web menu skeleton — no Quit (legend.quit ignored on web). */
export const MENU_BAR_MENUS = [
  {
    label: "File",
    items: [
      { id: "new", label: "New", legendKey: "new" },
      { id: "open", label: "Open", legendKey: LEGEND_WIRE_OPEN },
      { id: "import", label: "Import", legendKey: LEGEND_WIRE_IMPORT },
      { id: "export", label: "Export", legendKey: LEGEND_WIRE_EXPORT },
      { id: "save", label: "Save", legendKey: LEGEND_WIRE_SAVE },
      { id: "saveAs", label: "Save As", legendKey: LEGEND_WIRE_SAVE_AS },
      { id: "autoSave", label: "Auto Save" },
      { id: "settings", label: "Settings" },
    ],
  },
  {
    label: "Edit",
    items: [
      { id: "undo", label: "Undo", legendKey: "undo" },
      { id: "redo", label: "Redo", legendKey: "redo" },
      { id: "copy", label: "Copy", legendKey: LEGEND_WIRE_COPY },
      { id: "paste", label: "Paste", legendKey: LEGEND_WIRE_PASTE },
      { id: "solve", label: "Solve", legendKey: "solve" },
      { id: "hint", label: "Hint", legendKey: "hint" },
      { id: "deselect", label: "Deselect Cell" },
    ],
  },
    {
      label: "View",
      items: [
        { id: "viewSystem", label: "System" },
        { id: "viewLight", label: "Light" },
        { id: "viewDark", label: "Dark" },
        { id: "viewRegion", label: "Show Region" },
        { id: "viewMarks", label: "Show Pencil Marks" },
      ],
    },
  {
    label: "Help",
    items: [{ id: "about", label: "About" }],
  },
];

/** Mirror wasm Legend flags onto File + Edit controls. View/Help stay enabled. */
export function syncMenuBar(legend, controls) {
  for (const menu of MENU_BAR_MENUS) {
    for (const item of menu.items) {
      if (!item.legendKey) continue;
      const control = controls[item.id];
      if (control) control.disabled = !legend[item.legendKey];
    }
  }
  if (controls.viewSystem) controls.viewSystem.disabled = false;
  if (controls.viewLight) controls.viewLight.disabled = false;
  if (controls.viewDark) controls.viewDark.disabled = false;
  if (controls.viewRegion) controls.viewRegion.disabled = false;
  if (controls.viewMarks) controls.viewMarks.disabled = false;
  if (controls.about) controls.about.disabled = false;
  if (controls.settings) controls.settings.disabled = false;
}

/**
 * File → Auto Save shows its row label and core's word for the current value, e.g. "Auto Save (On)".
 * @param {{ autoSave?: HTMLElement | null }} controls
 * @param {Config} config
 * @param {ConfigTable} table
 */
export function syncAutoSave(controls, config, table) {
  if (!controls.autoSave) return;
  const on = config?.auto_save === true;
  controls.autoSave.disabled = false;
  controls.autoSave.setAttribute("aria-checked", on ? "true" : "false");
  controls.autoSave.textContent = `${settings.configRow(table, settings.AUTO_SAVE_FIELD).label} (${settings.onOffLabel(table, on)})`;
}

/**
 * View items that set a Config field carry the table's words: the theme choices and the on/off rows.
 * @param {{ viewSystem?: HTMLElement | null, viewLight?: HTMLElement | null, viewDark?: HTMLElement | null, viewRegion?: HTMLElement | null, viewMarks?: HTMLElement | null }} controls
 * @param {ConfigTable} table
 */
export function labelConfigItems(controls, table) {
  const themeItems = { system: controls.viewSystem, light: controls.viewLight, dark: controls.viewDark };
  for (const [name, el] of Object.entries(themeItems)) {
    if (el) el.textContent = settings.choiceLabel(table, settings.THEME_FIELD, name);
  }
  if (controls.viewRegion) controls.viewRegion.textContent = settings.configRow(table, settings.SHOW_REGION_FIELD).label;
  if (controls.viewMarks) controls.viewMarks.textContent = settings.configRow(table, settings.SHOW_MARKS_FIELD).label;
}

/** Resolve menu control elements from the page shell. */
export function collectMenuBarControls(root) {
  return {
    new: root.querySelector("#file-new"),
    open: root.querySelector("#file-open"),
    import: root.querySelector("#file-import"),
    export: root.querySelector("#file-export"),
    save: root.querySelector("#file-save"),
    saveAs: root.querySelector("#file-save-as"),
    autoSave: root.querySelector("#file-auto-save"),
    settings: root.querySelector("#file-settings"),
    undo: root.querySelector("#edit-undo"),
    redo: root.querySelector("#edit-redo"),
    copy: root.querySelector("#edit-copy"),
    paste: root.querySelector("#edit-paste"),
    solve: root.querySelector("#edit-solve"),
    hint: root.querySelector("#edit-hint"),
    deselect: root.querySelector("#edit-deselect"),
    viewSystem: root.querySelector("#view-system"),
    viewLight: root.querySelector("#view-light"),
    viewDark: root.querySelector("#view-dark"),
    viewRegion: root.querySelector("#view-region"),
    viewMarks: root.querySelector("#view-marks"),
    about: root.querySelector("#help-about"),
  };
}

/** Menubar dropdowns: open on mousedown, drag across titles, release on an item to run it; Escape or a click outside closes. */
export function wireMenuDropdowns(root = document) {
  const menus = [...root.querySelectorAll("#menu-bar .menu")];

  const closeAll = () => {
    for (const menu of menus) {
      menu.dataset.open = "false";
      const panel = menu.querySelector(".menu-panel");
      const trigger = menu.querySelector(".menu-trigger");
      if (panel) panel.hidden = true;
      if (trigger) trigger.setAttribute("aria-expanded", "false");
    }
  };

  const openMenu = (menu) => {
    closeAll();
    menu.dataset.open = "true";
    const panel = menu.querySelector(".menu-panel");
    const trigger = menu.querySelector(".menu-trigger");
    if (panel) panel.hidden = false;
    if (trigger) trigger.setAttribute("aria-expanded", "true");
  };

  /** True while the primary button is down after a menu-trigger press — enables drag-across. */
  let barDragging = false;
  /** Trigger pressed while its menu was open; mouseup on that same trigger toggles closed. */
  let pendingCloseTrigger = null;

  const endBarDrag = (event) => {
    if (pendingCloseTrigger && event.target === pendingCloseTrigger) closeAll();
    barDragging = false;
    pendingCloseTrigger = null;
  };

  const doc = root.ownerDocument ?? globalThis.document;
  const panelItemSelector =
    ".menu-panel button[role=menuitem], .menu-panel button[role=menuitemradio], .menu-panel button[role=menuitemcheckbox]";

  /** Trigger mousedown suppresses the item's native click — activate release target ourselves. */
  const activateDragReleaseMenuItem = (event) => {
    if (!barDragging || event.button !== 0) return;
    if (typeof doc.elementFromPoint !== "function") return;
    const hit = doc.elementFromPoint(event.clientX, event.clientY);
    const item = hit?.closest?.(panelItemSelector) ?? null;
    if (!item || item.disabled) return;
    const panel = item.closest?.(".menu-panel");
    if (!panel || panel.hidden) return;
    const menu = panel.closest?.(".menu");
    if (menu?.dataset?.open !== "true") return;
    item.click();
  };

  const onBarMouseUp = (event) => {
    activateDragReleaseMenuItem(event);
    endBarDrag(event);
  };

  if (doc?.addEventListener) {
    doc.addEventListener("mouseup", onBarMouseUp, { capture: true });
  } else {
    root.addEventListener?.("mouseup", onBarMouseUp);
  }

  for (const menu of menus) {
    const trigger = menu.querySelector(".menu-trigger");
    trigger?.addEventListener("mousedown", (event) => {
      event.preventDefault();
      event.stopPropagation();
      barDragging = true;
      if (menu.dataset.open === "true") pendingCloseTrigger = trigger;
      else {
        pendingCloseTrigger = null;
        openMenu(menu);
      }
    });
    // Drag across menu titles switches the open panel.
    menu.addEventListener("mouseenter", () => {
      if (!barDragging) return;
      openMenu(menu);
    });
    // Swallow the click that follows mousedown so root click does not instantly close.
    trigger?.addEventListener("click", (event) => {
      event.stopPropagation();
    });
    const panel = menu.querySelector(".menu-panel");
    panel?.addEventListener?.("click", (event) => {
      event.stopPropagation();
      // Menu actions should always dismiss the dropdown after activation.
      const item = event.target?.closest?.(panelItemSelector) ?? null;
      if (item && !item.disabled) closeAll();
    });
  }

  root.addEventListener("click", () => closeAll());
  root.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeAll();
  });

  closeAll();
  return { closeAll, openMenu };
}

/** Wire the dropdowns, label the Config items from the table, and keep enablement and Auto Save in step with the session. */
export function wireMenuBar(controls, session, root) {
  const dropdowns = root ? wireMenuDropdowns(root) : null;
  labelConfigItems(controls, session.configTable);
  const sync = () => {
    syncMenuBar(session.legend, controls);
    syncAutoSave(controls, session.config, session.configTable);
  };
  sync();
  return { sync, closeAll: () => dropdowns?.closeAll() };
}
