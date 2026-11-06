// shortcuts.js — web keyboard shortcuts: each key presses the menu item or pad button it names.

/** @typedef {import("../types").Shortcut} Shortcut */

/** @type {Shortcut[]} */
export const SHORTCUTS = [
  { key: "p", target: '#play-pad [data-pad-command="pencil"]' },
  { key: "h", target: "#edit-hint" },
  { key: "r", target: "#view-region" },
  { key: "m", target: "#view-marks" },
  { key: "s", mod: true, target: "#file-save" },
  { key: "s", mod: true, shift: true, target: "#file-save-as" },
  { key: "o", mod: true, target: "#file-open" },
  { key: "z", mod: true, target: "#edit-undo" },
  { key: "z", mod: true, shift: true, target: "#edit-redo" },
];

/** Keys typed here are text, not shortcuts. */
const TYPING_TARGETS = "input, textarea, select, [contenteditable=true]";
/** While a dialog is open, the page behind it takes no shortcuts. */
const OPEN_MODAL = '[aria-modal="true"]:not([hidden])';
const MENU_ITEM_ROLES = new Set(["menuitem", "menuitemcheckbox", "menuitemradio"]);
export const SHORTCUT_LABEL_CLASS = "menu-shortcut";

/**
 * Whether the browser runs on a Mac (or iPhone/iPad), where Cmd takes Ctrl's place.
 * @param {{ platform?: string, userAgentData?: { platform?: string } } | undefined} nav
 */
export function isMacPlatform(nav) {
  const platform = nav?.userAgentData?.platform ?? nav?.platform ?? "";
  return /mac|iphone|ipad/i.test(platform);
}

/**
 * The shortcut a key press means, or null. A letter shortcut takes no modifier; a mod
 * shortcut takes Ctrl (Cmd on Mac) and never the other one.
 * @param {{ key?: string, ctrlKey?: boolean, metaKey?: boolean, shiftKey?: boolean, altKey?: boolean }} event
 * @param {boolean} mac
 * @returns {Shortcut | null}
 */
export function matchShortcut(event, mac) {
  if (event.altKey) return null;
  const mod = (mac ? event.metaKey : event.ctrlKey) === true;
  const otherMod = (mac ? event.ctrlKey : event.metaKey) === true;
  if (otherMod) return null;
  const key = event.key?.toLowerCase();
  const shift = event.shiftKey === true;
  return SHORTCUTS.find((s) => s.key === key && (s.mod === true) === mod && (s.shift === true) === shift) ?? null;
}

/**
 * How a menu item shows its shortcut, e.g. "Ctrl+Shift+S" or "Cmd+S".
 * @param {Shortcut} shortcut
 * @param {boolean} mac
 */
export function shortcutLabel(shortcut, mac) {
  const parts = [];
  if (shortcut.mod) parts.push(mac ? "Cmd" : "Ctrl");
  if (shortcut.shift) parts.push("Shift");
  parts.push(shortcut.key.toUpperCase());
  return parts.join("+");
}

/**
 * The same shortcut in `aria-keyshortcuts` form, e.g. "Control+Shift+S" or "Meta+S".
 * @param {Shortcut} shortcut
 * @param {boolean} mac
 */
function ariaShortcut(shortcut, mac) {
  const parts = [];
  if (shortcut.mod) parts.push(mac ? "Meta" : "Control");
  if (shortcut.shift) parts.push("Shift");
  parts.push(shortcut.key.toUpperCase());
  return parts.join("+");
}

/**
 * Label each shortcut's control and press it on its key. A disabled control is not pressed,
 * but its key is still taken, so Ctrl+S never opens the browser's own Save.
 * @param {Document} root
 * @param {{ platform?: string, userAgentData?: { platform?: string } } | undefined} nav
 */
export function wireShortcuts(root, nav) {
  const mac = isMacPlatform(nav);
  for (const shortcut of SHORTCUTS) {
    const el = root.querySelector(shortcut.target);
    if (!el) continue;
    el.setAttribute("aria-keyshortcuts", ariaShortcut(shortcut, mac));
    if (!MENU_ITEM_ROLES.has(el.getAttribute("role") ?? "")) continue;
    const label = root.createElement("span");
    label.className = SHORTCUT_LABEL_CLASS;
    label.textContent = shortcutLabel(shortcut, mac);
    el.append(label);
  }
  root.addEventListener("keydown", (/** @type {KeyboardEvent} */ event) => {
    if (event.repeat) return;
    const shortcut = matchShortcut(event, mac);
    if (!shortcut) return;
    const target = /** @type {Element | null} */ (event.target);
    if (typeof target?.closest === "function" && target.closest(TYPING_TARGETS)) return;
    if (root.querySelector(OPEN_MODAL)) return;
    event.preventDefault();
    const el = /** @type {HTMLButtonElement | null} */ (root.querySelector(shortcut.target));
    if (el && !el.disabled) el.click();
  });
}
