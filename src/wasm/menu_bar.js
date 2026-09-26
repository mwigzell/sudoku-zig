// menu_bar.js — top menu bar: legend-driven enablement.

/** Wasm legend JSON key — pairs with Zig `Legend.@"export"` / `CommandTag.@"export"` (see legend.zig). */
export const LEGEND_WIRE_EXPORT = "export";
export const LEGEND_WIRE_COPY = "copy";
export const LEGEND_WIRE_PASTE = "paste";

/** Web menu skeleton — no Quit (legend.quit ignored on web). */
export const MENU_BAR_MENUS = [
  {
    label: "File",
    items: [
      { id: "new", label: "New", legendKey: "new" },
      { id: "open", label: "Open", legendKey: "open" },
      { id: "import", label: "Import", legendKey: "import" },
      { id: "export", label: "Export", legendKey: LEGEND_WIRE_EXPORT },
      { id: "save", label: "Save", legendKey: "save" },
      { id: "saveAs", label: "Save As", legendKey: "save_as" },
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
      { id: "deselect", label: "Deselect Cell" },
    ],
  },
    {
      label: "View",
      items: [
        { id: "viewLight", label: "Light" },
        { id: "viewDark", label: "Dark" },
        { id: "viewRegion", label: "Show Region" },
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
  if (controls.viewLight) controls.viewLight.disabled = false;
  if (controls.viewDark) controls.viewDark.disabled = false;
  if (controls.viewRegion) controls.viewRegion.disabled = false;
  if (controls.about) controls.about.disabled = false;
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
    undo: root.querySelector("#edit-undo"),
    redo: root.querySelector("#edit-redo"),
    copy: root.querySelector("#edit-copy"),
    paste: root.querySelector("#edit-paste"),
    solve: root.querySelector("#edit-solve"),
    deselect: root.querySelector("#edit-deselect"),
    viewLight: root.querySelector("#view-light"),
    viewDark: root.querySelector("#view-dark"),
    viewRegion: root.querySelector("#view-region"),
    about: root.querySelector("#help-about"),
  };
}

/** Keep menu controls aligned with session.legend; File handlers wired in C.6. */
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
    });
  }

  root.addEventListener("mouseup", (event) => endBarDrag(event));
  root.addEventListener("click", () => closeAll());
  root.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeAll();
  });

  closeAll();
  return { closeAll, openMenu };
}

/** Keep menu controls aligned with session.legend; File handlers wired in C.6. */
export function wireMenuBar(controls, session, root) {
  if (root) wireMenuDropdowns(root);
  const sync = () => syncMenuBar(session.legend, controls);
  sync();
  return { sync };
}
