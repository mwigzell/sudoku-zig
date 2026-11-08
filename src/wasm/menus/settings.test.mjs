// settings.test.mjs — Settings dialog generated from core's config table, and the set_config actions.

import assert from "node:assert/strict";
import * as settings from "./settings.js";
import * as webSteps from "../flows/web_steps.js";
import { configTable, coreText, fakeSettingsDialog, loadGame } from "../test_support.mjs";

// ── the actions every Config control sends ──
{
  assert.deepEqual(settings.setConfigAction("theme", "dark"), { action: "set_config", field: "theme", value: "dark" });
  assert.deepEqual(settings.toggleConfigAction({ show_region: true }, "show_region"), { action: "set_config", field: "show_region", value: false });
  assert.deepEqual(settings.toggleConfigAction({ show_region: false }, "show_region"), { action: "set_config", field: "show_region", value: true });
  assert.throws(() => settings.configRow(configTable, "no_such_field"), /no row for no_such_field/);
  assert.throws(() => settings.choiceLabel(configTable, "theme", "plaid"), /no choice plaid/);
}

// ── one control per table row: a checkbox for on/off, a select of the row's choices ──
{
  const { modal, createElement, field } = fakeSettingsDialog();
  const controls = settings.buildSettingsFields(modal, configTable, createElement);
  assert.deepEqual(Object.keys(controls), configTable.rows.map((r) => r.field), "Settings order is the table's");
  assert.equal(modal.fieldsEl.children.length, configTable.rows.length);
  for (const row of configTable.rows) {
    const input = field(row.field);
    if (row.choices) {
      assert.equal(input.tagName, "SELECT");
      assert.deepEqual(input.children.map((o) => [o.value, o.textContent]), row.choices.map((c) => [c.name, c.label]));
    } else {
      assert.equal(input.type, "checkbox");
    }
  }

  const config = { ...Object.fromEntries(configTable.rows.map((r) => [r.field, r.choices ? r.choices[0].name : true])) };
  config.difficulty = "hard";
  settings.syncSettingsFields(controls, config);
  assert.equal(field("difficulty").value, "hard");
  assert.equal(field("warn_solvability").checked, true);
}

// ── the dialog is generic over the table's rows: any row gets its control and sends set_config for its field ──
{
  const extra = "extra_field";
  const onOffRow = configTable.rows.find((r) => r.choices === null);
  const table = { ...configTable, rows: [...configTable.rows, { ...onOffRow, field: extra, label: "extra row" }] };
  const sent = [];
  const game = { commandStart: (action) => (sent.push(action), { step: "done" }) };
  const session = { config: { [extra]: false }, configTable: table };
  const { modal, createElement, field } = fakeSettingsDialog();
  settings.wireSettingsMenu(createElement("button"), game, session, modal, { steps: {}, createElement });
  assert.equal(modal.fieldsEl.children.length, table.rows.length);
  field(extra).checked = true;
  await field(extra).onchange();
  assert.deepEqual(sent, [settings.setConfigAction(extra, true)]);
}

/** Real wasm game, its session, and web step handlers that record every config write and shown error. */
async function settingsHarness() {
  const game = await loadGame();
  const session = { config: game.getConfig(), configTable, legend: game.getLegend(), state: game.getState() };
  const persisted = [];
  const errors = [];
  const steps = webSteps.webSteps(game, session, {
    fetchFn: async (url, init) => {
      persisted.push(JSON.parse(init.body));
      return { ok: true, status: 204 };
    },
    promptDialog: {
      show: async (step) => {
        errors.push(step.text);
        return step.default;
      },
      dismiss() {},
    },
  });
  const dialog = fakeSettingsDialog();
  const btn = dialog.createElement("button");
  settings.wireSettingsMenu(btn, game, session, dialog.modal, { steps, createElement: dialog.createElement });
  return { game, session, persisted, errors, btn, ...dialog };
}

// ── open, change a checkbox, dismiss ──
{
  const { session, persisted, btn, modal, field } = await settingsHarness();
  btn.onclick();
  assert.equal(modal.el.hidden, false);
  assert.equal(field("warn_solvability").checked, false, "opening syncs from the session's Config");

  field("warn_solvability").checked = true;
  await field("warn_solvability").onchange();
  assert.equal(session.config.warn_solvability, true);
  assert.equal(field("warn_solvability").checked, true);
  assert.equal(persisted.length, 1, "core asks to persist after the change");
  assert.equal(persisted[0].warn_solvability, true);

  modal.dismissEl.onclick();
  assert.equal(modal.el.hidden, true);
}

// ── a select sends the picked choice by name ──
{
  const { session, persisted, field } = await settingsHarness();
  field("difficulty").value = "hard";
  await field("difficulty").onchange();
  assert.equal(session.config.difficulty, "hard");
  assert.equal(field("difficulty").value, "hard");
  assert.equal(persisted.at(-1).difficulty, "hard");
}

// ── a value core refuses shows core's text and the control returns to the session's value ──
{
  const { session, persisted, errors, field } = await settingsHarness();
  field("theme").value = "plaid";
  await field("theme").onchange();
  assert.deepEqual(errors, [coreText.BAD_VALUE_MSG]);
  assert.equal(persisted.length, 0, "a refused change writes nothing");
  assert.equal(field("theme").value, session.config.theme);
}

console.log("settings.test.mjs OK");
