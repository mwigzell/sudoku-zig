// host_settings.test.mjs — settings.json authority: host fetch in, menu POST out.

import assert from "node:assert/strict";
import {
  bootstrapEngineFromHostConfig,
  fetchHostStartupConfig,
  hostViewPrefsForPersist,
  initializeWebSession,
  persistHostSettings,
} from "./shell.js";
import { wireThemeMenu } from "./theme.js";
import { wireRegionMenu } from "./region.js";
import { assertWebBootConfig } from "./shell.js";
import { primeWebBootChrome } from "./theme.js";

/** Test double: bootstrap args mirror wasm getConfig() after host bootstrap. */
function makeHostLinkedGame() {
  let live = null;
  return {
    bootstrapHostConfig(args) {
      live = {
        difficulty: args.difficulty,
        log_level: args.logLevel,
        theme: args.theme === "light" ? "light" : "dark",
        show_region: args.show_region === true,
        warn_solvability: args.warn_solvability === true,
      };
      return { ok: true, msg: "engine ready" };
    },
    getState() {
      return { cells: [] };
    },
    getLegend() {
      return {};
    },
    getConfig() {
      return live ? { ...live } : {};
    },
    deserialize() {
      return { ok: false };
    },
  };
}

// Host /host-config.json (from disk on serve) drives wasm bootstrap — not glue defaults.
{
  const hostFromFile = {
    difficulty: 2,
    log_level: 0,
    theme: "light",
    show_region: true,
    warn_solvability: true,
  };
  const game = makeHostLinkedGame();

  const hostCfg = await fetchHostStartupConfig(async () => ({
    ok: true,
    json: async () => hostFromFile,
  }));
  assert.deepEqual(hostCfg, hostFromFile);

  bootstrapEngineFromHostConfig(game, hostCfg);
  assertWebBootConfig(game.getConfig(), "engine after bootstrap");

  const boot = await initializeWebSession(game, {
    fetchFn: async () => ({ ok: true, json: async () => hostFromFile }),
  });
  assert.equal(boot.ok, true);
  assertWebBootConfig(boot.config);
  assert.equal(boot.config.difficulty, 2);
  assert.equal(boot.config.log_level, 0);
  assert.equal(boot.config.theme, "light");
  assert.equal(boot.hostCfg, undefined);
}

{
  const hostFromFile = {
    difficulty: 2,
    log_level: 0,
    theme: "light",
    show_region: true,
    warn_solvability: true,
  };
  const game = makeHostLinkedGame();
  const boot = await initializeWebSession(game, {
    fetchFn: async () => ({ ok: true, json: async () => hostFromFile }),
  });
  const html = { dataset: {} };
  primeWebBootChrome(boot, { documentElement: html });
  assert.equal(html.dataset.theme, "light");
}

// View menu persist POST writes the same shape the host merges into settings.json.
{
  const posts = [];
  const fetchMock = async (url, init) => {
    posts.push({ url, init, body: JSON.parse(init.body) });
    return { ok: true };
  };

  await persistHostSettings(
    { theme: "light", show_region: true, warn_solvability: false },
    fetchMock,
  );
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, "./settings.json");
  assert.equal(posts[0].init.method, "POST");
  assert.deepEqual(posts[0].body, {
    theme: "light",
    show_region: true,
    warn_solvability: false,
  });
  assert.deepEqual(
    hostViewPrefsForPersist({ theme: "dark", show_region: false, warn_solvability: true }),
    { theme: "dark", show_region: false, warn_solvability: true },
  );
}

// Theme menu change triggers POST payload derived from engine getConfig().
{
  const posts = [];
  const session = { config: { theme: "dark", show_region: false } };
  const game = {
    exec(action) {
      if (action.action === "set_theme" && action.theme === "light") {
        session.config = { theme: "light", show_region: false, warn_solvability: true };
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
    theme: "light",
    show_region: false,
    warn_solvability: true,
  });
}

// Region menu toggle POSTs show_region to settings.json.
{
  const posts = [];
  const session = { config: { theme: "dark", show_region: false } };
  const game = {
    exec(action) {
      if (action.action === "set_region") {
        session.config = { theme: "dark", show_region: action.enabled };
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
    theme: "dark",
    show_region: true,
    warn_solvability: false,
  });
}

console.log("host_settings.test.mjs OK");
