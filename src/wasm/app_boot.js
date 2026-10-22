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
  // Enable structured client diagnostics (console + host bridge).
  globalThis.__SUDOKU_LOG = true;
  globalThis.__SUDOKU_LOG_POST = true;

  const statusBar = root.getElementById("status-bar");
  const boardEl = root.getElementById("board");
  const errorModal = createErrorModal(root);

  try {
    console.log("boot: module start");
    // Boot phase 1: ensure first paint/splash is visible before wasm/network work.
    await new Promise((resolve) => requestAnimationFrame(resolve));
    console.log("boot: after first paint");

    // Boot phase 2: fetch + instantiate wasm artifact.
    const res = await fetch("./artifact.wasm");
    console.log("boot: artifact fetch response", res.status);
    if (!res.ok) throw new Error(`fetch failed: ${res.status} ${res.statusText}`);
    const bytes = new Uint8Array(await res.arrayBuffer());
    console.log("boot: artifact bytes", bytes.length);

    const game = await loadArtifact(bytes);
    console.log("boot: wasm loaded");

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
    console.log("boot: host config loaded");
    if (!boot.ok) throw new Error(boot.error ?? "session init failed");
    primeWebBootChrome(boot, root);

    // Boot phase 5: apply startup action contract (`restore`/`new`/`idle`).
    const ready = await offerInitialNewGame(game, boot, generatingModal, {
      genWorker,
      startupAutoContinue: true,
    });
    console.log("boot: startup action complete", ready.kind);
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
    console.log("boot: ready");
  } catch (err) {
    console.error("boot: failed", err);
    await globalThis.__hideSudokuBootSplash?.();
    globalThis.__sudokuSignalAndroidBootReady?.();
    const msg = `failed to load wasm: ${err && err.message ? err.message : err}`;
    setStatus(statusBar, msg, { error: true });
    showErrorModal(errorModal, msg);
  }
}
