// startup.js — web startup: host config into the engine, then core's startup flow (restore / new / idle).

import * as clientLog from "../client_log.js";
import * as hostApi from "../host_api.js";
import * as stepRunner from "./step_runner.js";

/** @typedef {import("../types").GameApi} GameApi */

/**
 * Throw unless `config` carries a value for every row of core's config table.
 * @param {import("../types").Config} config
 * @param {import("../types").ConfigTable} table
 */
export function assertWebBootConfig(config, table, label = "boot.config") {
  if (!config || typeof config !== "object") {
    throw new Error(`${label}: missing config object`);
  }
  for (const row of table.rows) {
    if (config[row.field] === undefined) {
      throw new Error(`${label}: missing ${row.field}`);
    }
  }
}

/** Required keys from `/host-config.json` before engine bootstrap: the config object and the host's file facts. */
export function assertHostStartupConfig(hostCfg, label = "host-config") {
  if (!hostCfg?.config || typeof hostCfg.config !== "object") {
    throw new Error(`${label}: missing config object`);
  }
  if (hostCfg.default_save_filename === undefined) {
    throw new Error(`${label}: missing default_save_filename`);
  }
  if (hostCfg.startup_save_path === undefined) {
    throw new Error(`${label}: missing startup_save_path`);
  }
}

/**
 * Host config bootstrap + startup policy payload from /host-config.json.
 */
/** @param {GameApi} game */
export async function initializeWebSession(game, { fetchFn } = {}) {
  // Phase 1: fetch host startup contract payload and validate required keys.
  const hostCfg = await hostApi.fetchHostStartupConfig(fetchFn);
  assertHostStartupConfig(hostCfg);
  // Phase 2: bootstrap engine config from host contract.
  const boot = game.bootstrapHostConfig(hostCfg.config);
  if (!boot.ok) return boot;
  game.setHostBuildInfo(await hostApi.fetchHostBuildInfo(fetchFn));
  clientLog.useCore(game);

  // Phase 3: return canonical boot/session shape for page entry wiring.
  return {
    ok: true,
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    config_table: game.getConfigTable(),
    msg: boot.msg ?? null,
    default_save_filename: hostCfg.default_save_filename,
    startup_save_path: hostCfg.startup_save_path ?? null,
  };
}

/**
 * Run the core startup flow on the host's current file (if any); `onShown` redraws the view.
 * @param {GameApi} game
 * @param {import("../types").FlowHandlers} steps the platform's step handlers
 * @param {(step: import("../types").FlowStep) => void} [onShown]
 */
export function runStartupFlow(game, boot, steps, onShown) {
  const start = boot.startup_save_path
    ? { flow: stepRunner.FLOW_STARTUP, path: boot.startup_save_path, name: boot.default_save_filename }
    : { flow: stepRunner.FLOW_STARTUP };
  return stepRunner.runFlow(game, start, steps, onShown);
}
