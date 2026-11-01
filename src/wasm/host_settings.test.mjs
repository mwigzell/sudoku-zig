// host_settings.test.mjs — settings menus on a real wasm game: core's command flow decides
// what is persisted and produces the `POST /settings.json` body.

import assert from "node:assert/strict";
import { commandHandlers, runSessionCommand } from "./shell.js";
import { wireThemeMenu } from "./theme.js";
import { wireRegionMenu } from "./region.js";
import { wireSettingsMenu } from "./settings.js";
import { loadGame, settleFlow } from "./test_support.mjs";

const DEFAULT_SETTINGS = {
  difficulty: "easy",
  log_level: "info",
  theme: "dark",
  show_region: false,
  warn_solvability: false,
  auto_restore: false,
  auto_new: false,
  auto_save: false,
};

/** Command flow handlers whose host answers `status`, recording posts and shown errors. */
function recordingCommandFlow(game, session, { status = 204 } = {}) {
  const posts = [];
  const errors = [];
  const fetchFn = async (url, init) => {
    posts.push({ url, method: init.method, body: JSON.parse(init.body) });
    return { ok: status < 400, status };
  };
  const commandFlow = commandHandlers(game, session, { fetchFn, onError: (failed) => errors.push(failed.error) });
  return { posts, errors, commandFlow };
}

/** A real wasm game and the web session over it. */
async function gameAndSession() {
  const game = await loadGame();
  return { game, session: { config: game.getConfig(), legend: game.getLegend(), state: game.getState() } };
}

function clickable() {
  return {
    classList: { toggle() {}, contains: () => false },
    setAttribute() {},
    addEventListener(_, fn) {
      this.click = fn;
    },
  };
}

const themeRoot = {
  documentElement: { dataset: {} },
  defaultView: { matchMedia: () => ({ matches: false, addEventListener() {} }) },
};

// View → Light posts core's settings body once.
{
  const { game, session } = await gameAndSession();
  const { posts, errors, commandFlow } = recordingCommandFlow(game, session);
  const controls = { viewLight: clickable() };
  wireThemeMenu(controls, game, session, { root: themeRoot, commandFlow });
  controls.viewLight.click();
  await settleFlow();
  assert.deepEqual(posts, [{ url: "./settings.json", method: "POST", body: { ...DEFAULT_SETTINGS, theme: "light" } }]);
  assert.deepEqual(errors, []);
}

// View → Region posts show_region.
{
  const { game, session } = await gameAndSession();
  const { posts, commandFlow } = recordingCommandFlow(game, session);
  const controls = { viewRegion: clickable() };
  wireRegionMenu(controls, game, session, { children: [] }, () => null, { commandFlow });
  controls.viewRegion.click();
  await settleFlow();
  assert.equal(posts.length, 1);
  assert.deepEqual(posts[0].body, { ...DEFAULT_SETTINGS, show_region: true });
}

// File → Settings: each control posts the full settings with its change.
{
  const { game, session } = await gameAndSession();
  const { posts, commandFlow } = recordingCommandFlow(game, session);
  const handlers = {};
  const control = (key, extra) => ({
    ...extra,
    addEventListener(type, fn) {
      if (type === "change") handlers[key] = fn;
    },
  });
  const modal = {
    el: { hidden: true },
    checkbox: control("warn", { checked: false }),
    difficultySelect: control("difficulty", { value: "easy" }),
    logLevelSelect: control("log", { value: "info" }),
    autoSaveCheckbox: control("autoSave", { checked: false }),
  };
  wireSettingsMenu({ addEventListener() {} }, game, session, modal, { commandFlow });

  modal.difficultySelect.value = "hard";
  await handlers.difficulty();
  modal.checkbox.checked = true;
  await handlers.warn();
  modal.autoSaveCheckbox.checked = true;
  await handlers.autoSave();

  assert.deepEqual(
    posts.map((p) => p.body),
    [
      { ...DEFAULT_SETTINGS, difficulty: "hard" },
      { ...DEFAULT_SETTINGS, difficulty: "hard", warn_solvability: true },
      { ...DEFAULT_SETTINGS, difficulty: "hard", warn_solvability: true, auto_save: true },
    ],
  );
}

// A host failure is shown as core's sentence.
{
  const { game, session } = await gameAndSession();
  const { posts, errors, commandFlow } = recordingCommandFlow(game, session, { status: 500 });
  const controls = { viewDark: clickable(), viewLight: clickable() };
  wireThemeMenu(controls, game, session, { root: themeRoot, commandFlow });
  controls.viewLight.click();
  await settleFlow();
  assert.equal(posts.length, 1);
  assert.deepEqual(errors, ["Your settings could not be saved (HTTP 500)."]);
}

// Commands that change no setting post nothing.
{
  const { game, session } = await gameAndSession();
  const { posts, commandFlow } = recordingCommandFlow(game, session);
  const outcome = await runSessionCommand(game, { action: "fill", row: 0, col: 0, digit: 4 }, commandFlow);
  assert.deepEqual(outcome, { kind: "done" });
  assert.equal(posts.length, 0);
  assert.equal(session.state.cells[0].value, 4);
}

console.log("host_settings.test.mjs OK");
