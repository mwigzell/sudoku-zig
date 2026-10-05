// host_settings.test.mjs — settings.json authority: host fetch in, menu POST out.

import assert from "node:assert/strict";
import {
  hostViewPrefsForPersist,
  persistHostSettings,
} from "./shell.js";
import { wireThemeMenu } from "./theme.js";
import { wireRegionMenu } from "./region.js";

// View menu persist POST writes the same shape the host merges into settings.json.
{
  const posts = [];
  const fetchMock = async (url, init) => {
    posts.push({ url, init, body: JSON.parse(init.body) });
    return { ok: true };
  };

  await persistHostSettings(
    { theme: "light", show_region: true, warn_solvability: false, auto_restore: true, auto_new: true, auto_save: true },
    fetchMock,
  );
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, "./settings.json");
  assert.equal(posts[0].init.method, "POST");
  assert.deepEqual(posts[0].body, {
    difficulty: "easy",
    log_level: "info",
    theme: "light",
    show_region: true,
    warn_solvability: false,
    auto_restore: true,
    auto_new: true,
    auto_save: true,
  });
  assert.deepEqual(
    hostViewPrefsForPersist({ theme: "dark", show_region: false, warn_solvability: true, auto_restore: false, auto_new: false, auto_save: false }),
    {
      difficulty: "easy",
      log_level: "info",
      theme: "dark",
      show_region: false,
      warn_solvability: true,
      auto_restore: false,
      auto_new: false,
      auto_save: false,
    },
  );
}

// Theme menu change triggers POST payload derived from engine getConfig().
{
  const posts = [];
  const session = { config: { theme: "dark", show_region: false, auto_restore: false, auto_new: false, auto_save: false } };
  const game = {
    exec(action) {
      if (action.action === "set_theme" && action.theme === "light") {
        session.config = { theme: "light", show_region: false, warn_solvability: true, auto_restore: false, auto_new: false, auto_save: false };
        return { ok: true };
      }
      return { ok: false };
    },
    getConfig() {
      return session.config;
    },
  };
  const btn = {
    attrs: {},
    classList: { _set: new Set(), toggle() {}, contains: () => false },
    setAttribute() {},
    addEventListener(_, fn) {
      this.click = fn;
    },
  };
  wireThemeMenu(
    { viewLight: btn, viewDark: { ...btn, addEventListener() {} } },
    game,
    session,
    {
      root: { documentElement: { dataset: {} } },
      onPersist: (cfg) => persistHostSettings(cfg, async (url, init) => {
        posts.push(JSON.parse(init.body));
        return { ok: true };
      }),
    },
  );
  btn.click();
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(posts[0], {
    difficulty: "easy",
    log_level: "info",
    theme: "light",
    show_region: false,
    warn_solvability: true,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
  });
}

// Region menu toggle POSTs show_region to settings.json.
{
  const posts = [];
  const session = { config: { theme: "dark", show_region: false, auto_restore: false, auto_new: false, auto_save: false } };
  const game = {
    exec(action) {
      if (action.action === "set_region") {
        session.config = { theme: "dark", show_region: action.enabled, auto_restore: false, auto_new: false, auto_save: false };
        return { ok: true };
      }
      return { ok: false };
    },
    getConfig() {
      return session.config;
    },
  };
  const btn = {
    attrs: {},
    classList: { _set: new Set(), toggle() {}, contains: () => false },
    setAttribute() {},
    addEventListener(_, fn) {
      this.click = fn;
    },
  };
  wireRegionMenu(
    { viewRegion: btn },
    game,
    session,
    { children: [] },
    () => null,
    {
      onPersist: (cfg) => persistHostSettings(cfg, async (_url, init) => {
        posts.push(JSON.parse(init.body));
        return { ok: true };
      }),
    },
  );
  btn.click();
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(posts[0], {
    difficulty: "easy",
    log_level: "info",
    theme: "dark",
    show_region: true,
    warn_solvability: false,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
  });
}

console.log("host_settings.test.mjs OK");
