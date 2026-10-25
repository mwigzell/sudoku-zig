// app_boot.js — startup phases for web shell, delegates UI wiring to app_wire.js.

import { loadArtifact } from "./glue.js";
import {
  canUseGenWorker,
  createWebSessionFromStartup,
  initializeWebSession,
  offerInitialNewGame,
  showErrorModal,
  startStartupContextPublish,
  syncCurrentFileLabels,
  wireFinalSnapshotOnPageHide,
  clientLog,
} from "./shell.js";
import { wireGeneratingModal } from "./generating.js";
import { renderBoard, setStatus } from "./board.js";
import { primeWebBootChrome } from "./theme.js";
import { createErrorModal, wireSudokuApp } from "./app_wire.js";

/**
 * Entry point used by `page.html` module script.
 * @param {Document} root
 * @returns {Promise<void>}
 */
export async function bootSudokuWebApp(root = document) {
  // Leave client diagnostics opt-in; release paths should not force debug telemetry.
  if (globalThis.__SUDOKU_LOG !== true) globalThis.__SUDOKU_LOG = false;
  if (globalThis.__SUDOKU_LOG_POST !== true) globalThis.__SUDOKU_LOG_POST = false;

  const statusBar = root.getElementById("status-bar");
  const boardEl = root.getElementById("board");
  const errorModal = createErrorModal(root);

  try {
    clientLog("startup", "debug", "module_start");
    // Boot phase 1: ensure first paint/splash is visible before wasm/network work.
    await new Promise((resolve) => requestAnimationFrame(resolve));
    clientLog("startup", "debug", "after_first_paint");

    // Boot phase 2: fetch + instantiate wasm artifact.
    const res = await fetch("./artifact.wasm");
    clientLog("startup", "debug", "artifact_fetch_response", { status: res.status });
    if (!res.ok) throw new Error(`fetch failed: ${res.status} ${res.statusText}`);
    const bytes = new Uint8Array(await res.arrayBuffer());
    clientLog("startup", "debug", "artifact_bytes", { bytes: bytes.length });

    const game = await loadArtifact(bytes);
    clientLog("startup", "debug", "wasm_loaded");

    // Boot phase 3: wire generation modal and optional worker generation context.
    const generatingModal = wireGeneratingModal({
      el: root.getElementById("generating-modal"),
      continueBtn: root.getElementById("generating-modal-continue"),
      cancelBtn: root.getElementById("generating-modal-cancel"),
      spinnerEl: root.getElementById("generating-spinner"),
      msgEl: root.getElementById("generating-modal-msg"),
      progressRowsEl: root.getElementById("generating-progress-rows"),
    });
    const genWorker = canUseGenWorker()
      ? { workerUrl: new URL("./gen_worker.js", import.meta.url).href, wasmBytes: bytes }
      : undefined;

    // Boot phase 4: fetch host startup contract + bootstrap engine config.
    const boot = await initializeWebSession(game);
    clientLog("startup", "info", "host_config_loaded", { log_level: boot?.config?.log_level ?? null });
    if (!boot.ok) throw new Error(boot.error ?? "session init failed");
    primeWebBootChrome(boot, root);

    // Boot phase 5: apply startup action contract (`restore`/`new`/`idle`).
    const ready = await offerInitialNewGame(game, boot, generatingModal, {
      genWorker,
      startupAutoContinue: true,
    });
    clientLog("startup", "info", "startup_action_complete", { kind: ready.kind });
    if (!ready.ok) throw new Error(ready.error ?? "New game failed");

    // Boot phase 6: build canonical session object + publish startup context lane.
    const session = createWebSessionFromStartup(ready);
    startStartupContextPublish(session, ready.startup_context_event);
    wireFinalSnapshotOnPageHide(game, session);
    syncCurrentFileLabels(session, root);
    renderBoard(boardEl, session.state);

    // Boot phase 7: wire UI modules around shared session object.
    wireSudokuApp({
      game,
      session,
      ready,
      generatingModal,
      genWorker,
      errorModal,
      root,
    });

    await globalThis.__hideSudokuBootSplash?.();
    globalThis.__sudokuSignalAndroidBootReady?.();
    clientLog("startup", "info", "ready");
  } catch (err) {
    const errorText = err && err.message ? err.message : String(err);
    clientLog("startup", "err", "boot_failed", { error: errorText });
    await globalThis.__hideSudokuBootSplash?.();
    globalThis.__sudokuSignalAndroidBootReady?.();
    const msg = `failed to load wasm: ${err && err.message ? err.message : err}`;
    setStatus(statusBar, msg, { error: true });
    showErrorModal(errorModal, msg);
  }
}
