// startup.js — web startup: host config into the engine, then core's startup flow (restore / new / idle).

import * as clientLog from "../client_log.js";
import * as hostApi from "../host_api.js";
import * as stepRunner from "./step_runner.js";

/** @typedef {import("../types").GameApi} GameApi */

/** Keys the web shell requires on `boot.config` after `initializeWebSession`. */
export const REQUIRED_WEB_BOOT_CONFIG_KEYS = [
  "difficulty",
  "log_level",
  "theme",
  "show_region",
  "warn_solvability",
  "auto_restore",
  "auto_new",
  "auto_save",
];

/** Throw unless `config` carries every key in `REQUIRED_WEB_BOOT_CONFIG_KEYS`. */
export function assertWebBootConfig(config, label = "boot.config") {
  if (!config || typeof config !== "object") {
    throw new Error(`${label}: missing config object`);
  }
  for (const key of REQUIRED_WEB_BOOT_CONFIG_KEYS) {
    if (config[key] === undefined) {
      throw new Error(`${label}: missing ${key}`);
    }
  }
}

/** Required keys from `/host-config.json` before engine bootstrap. */
export function assertHostStartupConfig(config, label = "host-config") {
  assertWebBootConfig(config, label);
  if (config.default_save_filename === undefined) {
    throw new Error(`${label}: missing default_save_filename`);
  }
  if (config.startup_save_path === undefined) {
    throw new Error(`${label}: missing startup_save_path`);
  }
}

/** Bridge host config JSON to wasm bootstrap wire names and booleans. */
/** @param {GameApi} game */
function bootstrapEngineFromHostConfig(game, hostCfg) {
  return game.bootstrapHostConfig({
    difficulty: hostCfg.difficulty,
    logLevel: hostCfg.log_level,
    theme: hostCfg.theme,
    show_region: hostCfg.show_region,
    warn_solvability: hostCfg.warn_solvability === true,
    auto_restore: hostCfg.auto_restore === true,
    auto_new: hostCfg.auto_new === true,
    auto_save: hostCfg.auto_save === true,
  });
}

/**
 * Host config bootstrap + startup policy payload from /host-config.json.
 */
/** @param {GameApi} game */
export async function initializeWebSession(game, { fetchFn } = {}) {
  // Phase 1: fetch host startup contract payload and validate required keys.
  const hostCfg = await hostApi.fetchHostStartupConfig(fetchFn);
  assertHostStartupConfig(hostCfg);
  clientLog.setClientLogLevel(hostCfg.log_level);
  // Phase 2: bootstrap engine config from host contract (difficulty/theme/flags).
  const boot = bootstrapEngineFromHostConfig(game, hostCfg);
  if (!boot.ok) return boot;
  game.setHostBuildInfo(await hostApi.fetchHostBuildInfo(fetchFn));

  // Phase 3: return canonical boot/session shape for page entry wiring.
  return {
    ok: true,
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
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
