// theme.js — View menu light/dark theme via engine config (#43).

export function themeFromConfig(config) {
  return config?.theme === "light" ? "light" : "dark";
}

export function applyTheme(theme, root) {
  if (theme === "light") root.dataset.theme = "light";
  else delete root.dataset.theme;
}

export function applyThemeFromConfig(config, root = document) {
  applyTheme(themeFromConfig(config), root.documentElement);
}

export function syncThemeMenu(controls, config) {
  const theme = themeFromConfig(config);
  if (controls.viewLight) {
    const on = theme === "light";
    controls.viewLight.setAttribute("aria-checked", on ? "true" : "false");
    controls.viewLight.classList.toggle("selected", on);
  }
  if (controls.viewDark) {
    const on = theme === "dark";
    controls.viewDark.setAttribute("aria-checked", on ? "true" : "false");
    controls.viewDark.classList.toggle("selected", on);
  }
}

export function wireThemeMenu(controls, game, session, { root = document, onChange } = {}) {
  const sync = () => {
    syncThemeMenu(controls, session.config);
    applyThemeFromConfig(session.config, root);
  };

  sync();

  controls.viewLight?.addEventListener("click", () => {
    if (session.config.theme === "light") return;
    const result = game.exec({ action: "set_theme", theme: "light" });
    if (!result.ok) return;
    session.config = game.getConfig();
    sync();
    onChange?.();
  });

  controls.viewDark?.addEventListener("click", () => {
    if (session.config.theme === "dark") return;
    const result = game.exec({ action: "set_theme", theme: "dark" });
    if (!result.ok) return;
    session.config = game.getConfig();
    sync();
    onChange?.();
  });

  return { sync, getTheme: () => themeFromConfig(session.config) };
}
