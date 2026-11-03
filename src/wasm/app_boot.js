// app_boot.js — startup phases for web shell, delegates UI wiring to app_wire.js.

import * as glue from "./glue.js";
import * as autosave from "./flows/autosave.js";
import * as clientLog from "./client_log.js";
import * as sessionMod from "./flows/session.js";
import * as startupMod from "./flows/startup.js";
import * as genClient from "./gen/gen_client.js";
import * as generating from "./dialogs/generating.js";
import * as board from "./board.js";
import * as theme from "./menus/theme.js";
import * as appWire from "./app_wire.js";

/**
 * After boot an uncaught error is a bug, not a failed start: log it, show nothing.
 * @param {Window & typeof globalThis} win
 */
function logUncaughtErrors(win) {
  const log = (reason) =>
    clientLog.clientLog("page", "err", "uncaught", { error: reason?.message ?? String(reason) });
  win.addEventListener("error", (ev) => log(ev.error ?? ev.message));
  win.addEventListener("unhandledrejection", (ev) => log(ev.reason));
}

/**
 * Entry point used by `page.html` module script.
 * @param {Document} root
 * @returns {Promise<void>}
 */
export async function bootSudokuWebApp(root = document) {
  // Leave client diagnostics opt-in; release paths should not force debug telemetry.
  if (globalThis.__SUDOKU_LOG !== true) globalThis.__SUDOKU_LOG = false;
  if (globalThis.__SUDOKU_LOG_POST !== true) globalThis.__SUDOKU_LOG_POST = false;

  const boardEl = root.getElementById("board");
  const errorModal = appWire.createErrorModal(root);

  try {
    clientLog.clientLog("startup", "debug", "module_start");
    // Boot phase 1: ensure first paint/splash is visible before wasm/network work.
    await new Promise((resolve) => requestAnimationFrame(resolve));
    clientLog.clientLog("startup", "debug", "after_first_paint");

    // Boot phase 2: fetch + instantiate wasm artifact.
    const res = await fetch("./artifact.wasm");
    clientLog.clientLog("startup", "debug", "artifact_fetch_response", { status: res.status });
    if (!res.ok) throw new Error(`fetch failed: ${res.status} ${res.statusText}`);
    const bytes = new Uint8Array(await res.arrayBuffer());
    clientLog.clientLog("startup", "debug", "artifact_bytes", { bytes: bytes.length });

    const game = await glue.loadArtifact(bytes);
    clientLog.clientLog("startup", "debug", "wasm_loaded");

    // Boot phase 3: wire generation modal and optional worker generation context.
    const generatingModal = generating.wireGeneratingModal({
      genText: game.getGenText(),
      el: root.getElementById("generating-modal"),
      continueBtn: root.getElementById("generating-modal-continue"),
      cancelBtn: root.getElementById("generating-modal-cancel"),
      spinnerEl: root.getElementById("generating-spinner"),
      msgEl: root.getElementById("generating-modal-msg"),
      progressRowsEl: root.getElementById("generating-progress-rows"),
    });
    const genWorker = genClient.canUseGenWorker()
      ? { workerUrl: new URL("./gen_worker.js", import.meta.url).href, wasmBytes: bytes }
      : undefined;

    // Boot phase 4: fetch host startup contract + bootstrap engine config.
    const boot = await startupMod.initializeWebSession(game);
    clientLog.clientLog("startup", "info", "host_config_loaded", { log_level: boot?.config?.log_level ?? null });
    if (!boot.ok) throw new Error(boot.error ?? "session init failed");
    theme.primeWebBootChrome(boot, root);

    // Boot phase 5: wire the UI around the idle session.
    const session = sessionMod.createWebSessionFromStartup(boot);
    sessionMod.syncCurrentFileLabels(session, root);
    board.renderBoard(boardEl, session.state);
    const app = appWire.wireSudokuApp({
      game,
      session,
      generatingModal,
      genWorker,
      errorModal,
      root,
    });
    autosave.wireFlushOnClose(game, app.steps);

    await globalThis.__hideSudokuBootSplash?.();
    globalThis.__sudokuSignalAndroidBootReady?.();
    logUncaughtErrors(globalThis);
    clientLog.clientLog("startup", "info", "ready");

    // Boot phase 6: core startup flow decides restore / new / idle; its dialogs need the splash gone.
    const outcome = await startupMod.runStartupFlow(game, boot, app.steps, app.showGame);
    clientLog.clientLog("startup", "info", "startup_flow_complete", { kind: outcome.kind });
  } catch (err) {
    const errorText = err && err.message ? err.message : String(err);
    clientLog.clientLog("startup", "err", "boot_failed", { error: errorText });
    globalThis.__sudokuSignalAndroidBootReady?.();
    globalThis.__sudokuShowBootFailure?.();
  }
}
