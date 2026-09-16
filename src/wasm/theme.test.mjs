// theme.test.mjs — View theme toggle contract (#43).

import assert from "node:assert/strict";
import { currentTheme, applyTheme, syncThemeMenu, wireThemeMenu } from "./theme.js";

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
  assert.equal(currentTheme(html), "dark");
  applyTheme("light", html);
  assert.equal(html.dataset.theme, "light");
  assert.equal(currentTheme(html), "light");
  applyTheme("dark", html);
  assert.equal(html.dataset.theme, undefined);
}

{
  const controls = { viewLight: makeThemeBtn(), viewDark: makeThemeBtn() };
  syncThemeMenu(controls, "light");
  assert.equal(controls.viewLight.attrs["aria-checked"], "true");
  assert.equal(controls.viewDark.attrs["aria-checked"], "false");
  assert.ok(controls.viewLight.classList.contains("selected"));
  assert.ok(!controls.viewDark.classList.contains("selected"));
}

{
  const html = { dataset: {} };
  const controls = {
    viewLight: { ...makeThemeBtn(), addEventListener(_, fn) { this.click = fn; } },
    viewDark: { ...makeThemeBtn(), addEventListener(_, fn) { this.click = fn; } },
  };
  const storage = new Map();
  wireThemeMenu(controls, {
    root: { documentElement: html },
    storage: {
      getItem: (k) => storage.get(k) ?? null,
      setItem: (k, v) => storage.set(k, v),
    },
  });
  assert.equal(html.dataset.theme, undefined);
  controls.viewLight.click();
  assert.equal(html.dataset.theme, "light");
  assert.equal(storage.get("sudoku-theme"), "light");
  controls.viewDark.click();
  assert.equal(html.dataset.theme, undefined);
  assert.equal(storage.get("sudoku-theme"), "dark");
}

console.log("theme.test.mjs OK");
