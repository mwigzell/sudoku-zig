// theme.test.mjs — View theme toggle contract.

import assert from "node:assert/strict";
import {
  themeFromConfig,
  applyTheme,
  syncThemeMenu,
  applyThemeFromConfig,
  applyBootTheme,
  wireThemeMenu,
} from "./theme.js";
import { commandHandlers } from "./shell.js";
import { loadGame, settleFlow } from "./test_support.mjs";

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
  applyBootTheme(
    { ok: true, kind: "empty", config: { theme: "light", show_region: false } },
    { documentElement: html },
  );
  assert.equal(html.dataset.theme, "light");
  applyBootTheme({ ok: false }, { documentElement: html });
  assert.equal(html.dataset.theme, "light");
}

{
  const html = { dataset: {} };
  applyTheme("light", html, {});
  assert.equal(html.dataset.theme, "light");
  applyThemeFromConfig({ theme: "light", show_region: false }, { documentElement: html, defaultView: {} });
  assert.equal(html.dataset.theme, "light");
  applyThemeFromConfig({ theme: "dark", show_region: false }, { documentElement: html, defaultView: {} });
  assert.equal(html.dataset.theme, undefined);
  applyThemeFromConfig(
    { theme: "system", show_region: false },
    { documentElement: html, defaultView: { matchMedia: () => ({ matches: false }) } },
  );
  assert.equal(html.dataset.theme, "light");
}

{
  const controls = { viewSystem: makeThemeBtn(), viewLight: makeThemeBtn(), viewDark: makeThemeBtn() };
  syncThemeMenu(controls, { theme: "light", show_region: false });
  assert.equal(controls.viewSystem.attrs["aria-checked"], "false");
  assert.equal(controls.viewLight.attrs["aria-checked"], "true");
  assert.equal(controls.viewDark.attrs["aria-checked"], "false");
}

{
  const html = { dataset: {} };
  const game = await loadGame({ theme: "dark" });
  const session = { config: game.getConfig(), legend: game.getLegend(), state: game.getState() };
  const controls = {
    viewSystem: { ...makeThemeBtn(), addEventListener() {} },
    viewLight: { ...makeThemeBtn(), addEventListener(_, fn) { this.click = fn; } },
    viewDark: { ...makeThemeBtn(), addEventListener() {} },
  };
  const persistCalls = [];
  const commandFlow = commandHandlers(game, session, {
    fetchFn: async (url, init) => {
      persistCalls.push(JSON.parse(init.body));
      return { ok: true, status: 204 };
    },
  });
  wireThemeMenu(controls, game, session, {
    root: {
      documentElement: html,
      defaultView: { matchMedia: () => ({ matches: false, addEventListener() {} }) },
    },
    commandFlow,
  });
  assert.equal(themeFromConfig(session.config), "dark");
  await controls.viewLight.click();
  await settleFlow();
  assert.equal(themeFromConfig(session.config), "light");
  assert.equal(html.dataset.theme, "light");
  assert.equal(persistCalls.length, 1, "core asks to persist after the theme change");
  assert.equal(persistCalls[0].theme, "light");
}

console.log("theme.test.mjs OK");
