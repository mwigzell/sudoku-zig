// theme.test.mjs — View theme toggle contract (#43).

import assert from "node:assert/strict";
import {
  themeFromConfig,
  applyTheme,
  syncThemeMenu,
  applyThemeFromConfig,
  wireThemeMenu,
} from "./theme.js";

function makeThemeBtn() {
  return {
    className: "",
    attrs: {},
    classList: {
      _set: new Set(),
      toggle(name, on) {
        if (on) this._set.add(name);
        else this._set.delete(name);
      },
      contains(name) {
        return this._set.has(name);
      },
    },
    setAttribute(name, value) {
      this.attrs[name] = value;
    },
    addEventListener() {},
  };
}

{
  const html = { dataset: {} };
  applyTheme("light", html);
  assert.equal(html.dataset.theme, "light");
  applyThemeFromConfig({ theme: "light", show_region: false }, { documentElement: html });
  assert.equal(html.dataset.theme, "light");
  applyThemeFromConfig({ theme: "dark", show_region: false }, { documentElement: html });
  assert.equal(html.dataset.theme, undefined);
}

{
  const controls = { viewLight: makeThemeBtn(), viewDark: makeThemeBtn() };
  syncThemeMenu(controls, { theme: "light", show_region: false });
  assert.equal(controls.viewLight.attrs["aria-checked"], "true");
  assert.equal(controls.viewDark.attrs["aria-checked"], "false");
}

{
  const html = { dataset: {} };
  const session = {
    config: { theme: "dark", show_region: false },
  };
  const game = {
    exec(action) {
      if (action.action === "set_theme" && action.theme === "light") {
        session.config = { theme: "light", show_region: false };
        return { ok: true };
      }
      return { ok: false };
    },
    getConfig() {
      return session.config;
    },
  };
  const controls = {
    viewLight: { ...makeThemeBtn(), addEventListener(_, fn) { this.click = fn; } },
    viewDark: { ...makeThemeBtn(), addEventListener() {} },
  };
  wireThemeMenu(controls, game, session, { root: { documentElement: html } });
  assert.equal(themeFromConfig(session.config), "dark");
  controls.viewLight.click();
  assert.equal(themeFromConfig(session.config), "light");
  assert.equal(html.dataset.theme, "light");
}

console.log("theme.test.mjs OK");
