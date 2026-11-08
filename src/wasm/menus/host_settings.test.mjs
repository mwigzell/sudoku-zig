// host_settings.test.mjs — config controls on a real wasm game: core's command flow decides
// what is persisted and produces the `POST /config.json` body.

import assert from "node:assert/strict";
import * as webSteps from "../flows/web_steps.js";
import * as stepRunner from "../flows/step_runner.js";
import * as themeMod from "./theme.js";
import * as region from "./region.js";
import * as marks from "./marks.js";
import * as settings from "./settings.js";
import { configTable, fakeSettingsDialog, loadGame, settleFlow, coreText } from "../test_support.mjs";

const DEFAULT_CONFIG = {
  difficulty: "easy",
  log_level: "info",
  theme: "dark",
  show_region: false,
  warn_solvability: false,
  auto_restore: false,
  auto_new: false,
  auto_save: false,
  show_marks: true,
};

/** Web step handlers whose host answers `status`, recording posts and shown errors. */
function recordingSteps(game, session, { status = 204 } = {}) {
  const posts = [];
  const errors = [];
  const fetchFn = async (url, init) => {
    posts.push({ url, method: init.method, body: JSON.parse(init.body) });
    return { ok: status < 400, status };
  };
  const promptDialog = {
    show: async (step) => {
      errors.push(step.text);
      return step.default;
    },
    dismiss() {},
  };
  const steps = webSteps.webSteps(game, session, { fetchFn, promptDialog });
  return { posts, errors, steps };
}

/** A real wasm game and the web session over it. */
async function gameAndSession() {
  const game = await loadGame();
  return { game, session: { config: game.getConfig(), configTable, legend: game.getLegend(), state: game.getState() } };
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

// View → Light posts core's Config once.
{
  const { game, session } = await gameAndSession();
  const { posts, errors, steps } = recordingSteps(game, session);
  const controls = { viewLight: clickable() };
  themeMod.wireThemeMenu(controls, game, session, { root: themeRoot, steps });
  controls.viewLight.click();
  await settleFlow();
  assert.deepEqual(posts, [{ url: "./config.json", method: "POST", body: { ...DEFAULT_CONFIG, theme: "light" } }]);
  assert.deepEqual(errors, []);
}

// View → Region posts show_region.
{
  const { game, session } = await gameAndSession();
  const { posts, steps } = recordingSteps(game, session);
  const controls = { viewRegion: clickable() };
  const fakeEl = () => ({ classList: { add() {} }, dataset: {}, setAttribute() {}, appendChild() {} });
  const boardEl = { classList: { contains: () => true }, children: [], replaceChildren() {} };
  region.wireRegionMenu(controls, game, session, boardEl, { steps, createElement: fakeEl });
  controls.viewRegion.click();
  await settleFlow();
  assert.equal(posts.length, 1);
  assert.deepEqual(posts[0].body, { ...DEFAULT_CONFIG, show_region: true });
}

// View → Show Pencil Marks posts show_marks.
{
  const { game, session } = await gameAndSession();
  const { posts, steps } = recordingSteps(game, session);
  const controls = { viewMarks: clickable() };
  const fakeEl = () => ({ classList: { add() {} }, dataset: {}, setAttribute() {}, appendChild() {} });
  const boardEl = { classList: { contains: () => true }, children: [], replaceChildren() {} };
  marks.wireMarks(controls, game, session, boardEl, { steps, createElement: fakeEl });
  controls.viewMarks.click();
  await settleFlow();
  assert.equal(posts.length, 1);
  assert.deepEqual(posts[0].body, { ...DEFAULT_CONFIG, show_marks: false });
}

// File → Settings: each control posts the full Config with its change.
{
  const { game, session } = await gameAndSession();
  const { posts, steps } = recordingSteps(game, session);
  const { modal, createElement, field } = fakeSettingsDialog();
  settings.wireSettingsMenu({ addEventListener() {} }, game, session, modal, { steps, createElement });

  field("difficulty").value = "hard";
  await field("difficulty").onchange();
  field("warn_solvability").checked = true;
  await field("warn_solvability").onchange();
  field("auto_save").checked = true;
  await field("auto_save").onchange();

  assert.deepEqual(
    posts.map((p) => p.body),
    [
      { ...DEFAULT_CONFIG, difficulty: "hard" },
      { ...DEFAULT_CONFIG, difficulty: "hard", warn_solvability: true },
      { ...DEFAULT_CONFIG, difficulty: "hard", warn_solvability: true, auto_save: true },
    ],
  );
}

// A host failure is shown as core's sentence.
{
  const { game, session } = await gameAndSession();
  const { posts, errors, steps } = recordingSteps(game, session, { status: 500 });
  const controls = { viewDark: clickable(), viewLight: clickable() };
  themeMod.wireThemeMenu(controls, game, session, { root: themeRoot, steps });
  controls.viewLight.click();
  await settleFlow();
  assert.equal(posts.length, 1);
  assert.deepEqual(errors, [coreText.PERSIST_FAILED_MSG]);
}

// Commands that change no Config post nothing.
{
  const { game, session } = await gameAndSession();
  const { posts, steps } = recordingSteps(game, session);
  const outcome = await stepRunner.runCommand(game, { action: "fill", row: 0, col: 0, digit: 4 }, steps);
  assert.deepEqual(outcome, { kind: "done" });
  assert.equal(posts.length, 0);
  assert.equal(session.state.cells[0].value, 4);
}

console.log("host_settings.test.mjs OK");
