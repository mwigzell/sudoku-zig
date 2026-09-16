// theme.js — View menu light/dark theme (#43).

export function currentTheme(root) {
  return root?.dataset?.theme === "light" ? "light" : "dark";
}

export function applyTheme(theme, root) {
  if (theme === "light") root.dataset.theme = "light";
  else delete root.dataset.theme;
}

export function syncThemeMenu(controls, theme) {
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

export function wireThemeMenu(controls, { root = document, storage = globalThis.localStorage } = {}) {
  const html = root.documentElement;

  const readStored = () => {
    try {
      const value = storage?.getItem("sudoku-theme");
      if (value === "light" || value === "dark") return value;
    } catch {
      /* private mode / disabled storage */
    }
    return null;
  };

  const save = (theme) => {
    try {
      storage?.setItem("sudoku-theme", theme);
    } catch {
      /* ignore */
    }
  };

  let theme = readStored() ?? currentTheme(html);
  applyTheme(theme, html);
  syncThemeMenu(controls, theme);

  const select = (next) => {
    theme = next;
    applyTheme(theme, html);
    syncThemeMenu(controls, theme);
    save(theme);
  };

  controls.viewLight?.addEventListener("click", () => select("light"));
  controls.viewDark?.addEventListener("click", () => select("dark"));

  return { getTheme: () => theme, setTheme: select };
}
