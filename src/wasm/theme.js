// theme.js — View menu light/dark theme via engine config.

import { applyConfigOutcomeStatus, assertWebBootConfig } from "./shell.js";

const THEME_LIGHT = "light";
const THEME_DARK = "dark";
const THEME_SYSTEM = "system";
const MEDIA_DARK = "(prefers-color-scheme: dark)";

export function themeFromConfig(config) {
  if (config?.theme === THEME_LIGHT) return THEME_LIGHT;
  if (config?.theme === THEME_SYSTEM) return THEME_SYSTEM;
  return THEME_DARK;
}

export function resolveEffectiveTheme(theme, win = globalThis) {
  if (theme === THEME_LIGHT) return THEME_LIGHT;
  if (theme === THEME_SYSTEM) {
    const prefersDark = typeof win?.matchMedia === "function" && win.matchMedia(MEDIA_DARK).matches === true;
    return prefersDark ? THEME_DARK : THEME_LIGHT;
  }
  return THEME_DARK;
}

function publishAndroidSystemBars(effectiveTheme, win = globalThis) {
  const bridge = win?.AndroidFileBridge;
  if (!bridge || typeof bridge.setSystemBars !== "function") return;
  bridge.setSystemBars(effectiveTheme);
}

export function applyTheme(theme, root, win = globalThis) {
  const effectiveTheme = resolveEffectiveTheme(theme, win);
  if (effectiveTheme === THEME_LIGHT) root.dataset.theme = THEME_LIGHT;
  else delete root.dataset.theme;
  publishAndroidSystemBars(effectiveTheme, win);
}

export function applyThemeFromConfig(config, root = document) {
  applyTheme(themeFromConfig(config), root.documentElement, root.defaultView ?? globalThis);
}

/** Host/engine config → `html[data-theme]` before modals (launch New runs before wireThemeMenu). */
export function applyBootTheme(boot, root = document) {
  if (boot?.ok && boot.config) applyThemeFromConfig(boot.config, root);
}

/** page.html boot order: full engine config, then theme on `<html>` before any modal. */
export function primeWebBootChrome(boot, root = document) {
  assertWebBootConfig(boot.config);
  applyBootTheme(boot, root);
}

export function syncThemeMenu(controls, config) {
  const theme = themeFromConfig(config);
  if (controls.viewSystem) {
    const on = theme === THEME_SYSTEM;
    controls.viewSystem.setAttribute("aria-checked", on ? "true" : "false");
    controls.viewSystem.classList.toggle("selected", on);
  }
  if (controls.viewLight) {
    const on = theme === THEME_LIGHT;
    controls.viewLight.setAttribute("aria-checked", on ? "true" : "false");
    controls.viewLight.classList.toggle("selected", on);
  }
  if (controls.viewDark) {
    const on = theme === THEME_DARK;
    controls.viewDark.setAttribute("aria-checked", on ? "true" : "false");
    controls.viewDark.classList.toggle("selected", on);
  }
}

export function wireThemeMenu(
  controls,
  game,
  session,
  { root = document, onChange, onPersist, statusEl } = {},
) {
  const win = root.defaultView ?? globalThis;
  const mediaQuery = typeof win.matchMedia === "function" ? win.matchMedia(MEDIA_DARK) : null;
  const onSystemThemeChanged = () => {
    if (themeFromConfig(session.config) !== THEME_SYSTEM) return;
    applyThemeFromConfig(session.config, root);
  };
  const sync = () => {
    syncThemeMenu(controls, session.config);
    applyThemeFromConfig(session.config, root);
  };

  sync();

  controls.viewSystem?.addEventListener("click", () => {
    void (async () => {
      if (session.config.theme === THEME_SYSTEM) return;
      const result = game.exec({ action: "set_theme", theme: THEME_SYSTEM });
      if (!applyConfigOutcomeStatus(session, game, statusEl, result)) return;
      sync();
      onChange?.();
      if (onPersist) await onPersist(session.config);
    })();
  });

  controls.viewLight?.addEventListener("click", () => {
    void (async () => {
      if (session.config.theme === THEME_LIGHT) return;
      const result = game.exec({ action: "set_theme", theme: THEME_LIGHT });
      if (!applyConfigOutcomeStatus(session, game, statusEl, result)) return;
      sync();
      onChange?.();
      if (onPersist) await onPersist(session.config);
    })();
  });

  controls.viewDark?.addEventListener("click", () => {
    void (async () => {
      if (session.config.theme === THEME_DARK) return;
      const result = game.exec({ action: "set_theme", theme: THEME_DARK });
      if (!applyConfigOutcomeStatus(session, game, statusEl, result)) return;
      sync();
      onChange?.();
      if (onPersist) await onPersist(session.config);
    })();
  });

  mediaQuery?.addEventListener?.("change", onSystemThemeChanged);

  return { sync, getTheme: () => themeFromConfig(session.config) };
}
