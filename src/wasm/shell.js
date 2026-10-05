// wasm/shell.js — web app shell: session UX + Event presentation.
// Event.ok.msg → status bar; Event.error_msg → acknowledgement modal (ADR-0010).

import { runWithGeneratingDialog } from "./generating.js";
import { canUseGenWorker, startGenInWorker } from "./gen_client.js";
import { createGenProgressModalSink } from "./gen_progress_rows.js";

/** Apply `.ok.msg` to the status bar. */
export function applyOkStatus(statusEl, result) {
  if (!result.ok) return;
  const msg = result.msg;
  if (typeof msg === "string" && msg.length > 0) {
    statusEl.textContent = msg;
    statusEl.className = "";
    return;
  }
  statusEl.textContent = "";
  statusEl.className = "";
}

/** Update the status bar from a successful exec result only. */
export function applyEventStatus(statusEl, result) {
  applyOkStatus(statusEl, result);
}

/** Clear the status bar (same as a successful exec with no message). */
export function clearEventStatus(statusEl) {
  applyEventStatus(statusEl, { ok: true, msg: null });
}

/** Show an Event.error_msg in the blocking error modal. */
export function showErrorModal(modal, message) {
  modal.msgEl.textContent = message;
  modal.el.hidden = false;
}

/** Wire dismiss on the error modal (click-to-dismiss, native showError analogue). */
export function wireErrorModal(el, msgEl, dismissEl) {
  const close = () => {
    el.hidden = true;
  };
  dismissEl.addEventListener("click", close);
  return { el, msgEl, close };
}

/** Route one exec result to status bar or error modal; never invent copy. */
export function applyExecResult(statusEl, errorModal, result) {
  if (!result.ok) {
    if (result.error) showErrorModal(errorModal, result.error);
    return;
  }
  applyEventStatus(statusEl, result);
}

/** Hint exec → status bar only; `.ok.msg` hint semantics never use the error modal. */
export function applyHintExecStatus(statusEl, errorModal, result) {
  if (!result.ok) {
    applyExecResult(statusEl, errorModal, result);
    return;
  }
  if (typeof result.msg === "string" && result.msg.length > 0) {
    applyEventStatus(statusEl, result);
  }
}

/** Save current game — returns opaque SUD0 bytes or `{ ok: false, error }`. */
export function save(game) {
  return game.serialize();
}

/** Save-as is the same bytes path until a picker supplies a target name. */
export function saveAs(game) {
  return game.serialize();
}

/** Restore game state from opaque SUD0 bytes. */
export function open(game, bytes, { name } = {}) {
  const result = name ? game.deserialize(bytes, { name }) : game.deserialize(bytes);
  if (!result.ok) return result;
  return { ok: true, state: result.state, msg: result.msg ?? null };
}

export { formatGenProgress } from "./gen_progress_format.js";
import { formatGenProgress } from "./gen_progress_format.js";

function mergeGenProgressHandlers(onProgressWire, onGenProgress) {
  if (!onProgressWire && !onGenProgress) return undefined;
  return (phase, a, b) => {
    onProgressWire?.(phase, a, b);
    onGenProgress?.(formatGenProgress(phase, a, b));
  };
}

/** Yield so the status bar can paint before a blocking wasm `init`. */
export function waitForStatusPaint() {
  if (typeof requestAnimationFrame !== "function") return Promise.resolve();
  return new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  });
}

/** Start a fresh game at the given difficulty (PlayerDifficulty wire values). */
export function newGame(game, { difficulty = 1, logLevel = 1, onGenProgress } = {}) {
  game.setGenProgressListener?.(
    onGenProgress ? (phase, a, b) => onGenProgress(formatGenProgress(phase, a, b)) : null,
  );
  try {
    const result = game.init({ difficulty, logLevel });
    if (!result.ok) return result;
    return {
      ok: true,
      state: game.getState(),
      legend: game.getLegend(),
      config: game.getConfig(),
      msg: result.msg ?? NEW_GAME_STARTED_MSG,
    };
  } finally {
    game.setGenProgressListener?.(null);
  }
}

/** Status copy for wasm `init` / File → New (matches engine `Event.ok.msg`). */
export const NEW_GAME_STARTED_MSG = "new game started";

/** Load a one-line puzzle via `importPuzzle` (paste, file import, export round-trip). */
export function applyImportedLine(game, line) {
  const result = game.importPuzzle(line);
  if (!result.ok) return result;
  return {
    ok: true,
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    msg: result.msg ?? "import: puzzle loaded",
  };
}

/** Worker/sync gen handoff: same codec as import; status reflects New, not Import. */
export function applyGeneratedLineAsNewGame(game, line, { difficulty } = {}) {
  const result =
    difficulty != null && typeof game.importPuzzleNewGame === "function"
      ? (() => {
          const importResult = game.importPuzzleNewGame(line, difficulty);
          if (!importResult.ok) return importResult;
          return {
            ok: true,
            state: game.getState(),
            legend: game.getLegend(),
            config: game.getConfig(),
            msg: importResult.msg ?? "import: puzzle loaded",
          };
        })()
      : applyImportedLine(game, line);
  if (!result.ok) return result;
  return { ...result, msg: NEW_GAME_STARTED_MSG };
}

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
  if (config.startup_status === undefined) {
    throw new Error(`${label}: missing startup_status`);
  }
}

export async function fetchHostStartupConfig(fetchFn = globalThis.fetch) {
  const res = await fetchFn("./host-config.json");
  if (!res.ok) throw new Error(`host-config fetch failed: ${res.status}`);
  return res.json();
}

async function fetchStartupSaveBytes(path, fetchFn = globalThis.fetch) {
  const res = await fetchFn(path);
  if (!res.ok) return { ok: false, error: `startup restore fetch failed: ${res.status}` };
  return { ok: true, bytes: new Uint8Array(await res.arrayBuffer()) };
}

export function bootstrapEngineFromHostConfig(game, hostCfg) {
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

const DIFFICULTY_WIRE = { 1: "easy", 2: "medium", 3: "hard" };
const LOG_WIRE = ["debug", "info", "warn", "err", "fatal"];

export function difficultyName(config) {
  if (typeof config.difficulty === "string") return config.difficulty;
  return DIFFICULTY_WIRE[config.difficulty] ?? "easy";
}

export function logLevelName(config) {
  if (typeof config.log_level === "string") return config.log_level;
  return LOG_WIRE[config.log_level] ?? "info";
}

/** User-editable settings.json fields (excludes renderer choice). */
export function hostSettingsForPersist(config) {
  return {
    difficulty: difficultyName(config),
    log_level: logLevelName(config),
    theme: config.theme === "light" ? "light" : "dark",
    show_region: config.show_region === true,
    warn_solvability: config.warn_solvability === true,
    auto_restore: config.auto_restore === true,
    auto_new: config.auto_new === true,
    auto_save: config.auto_save === true,
  };
}

/** @deprecated use hostSettingsForPersist */
export function hostViewPrefsForPersist(config) {
  return hostSettingsForPersist(config);
}

/** Persist player prefs to host settings.json (web serve POST). */
export async function persistHostSettings(config, fetchFn = globalThis.fetch) {
  const res = await fetchFn("./settings.json", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(hostSettingsForPersist(config)),
  });
  if (!res.ok) throw new Error(`settings persist failed: ${res.status}`);
}

/** Persist current SUD0 snapshot for startup restore (`/current-file`). */
export async function persistCurrentFileSnapshot(game, fetchFn = globalThis.fetch) {
  const saved = game.serialize();
  if (!saved.ok) return saved;
  const res = await fetchFn("./current-file", {
    method: "POST",
    headers: { "Content-Type": "application/octet-stream" },
    body: saved.bytes,
  });
  if (!res.ok) return { ok: false, error: `current-file persist failed: ${res.status}` };
  return { ok: true };
}

/**
 * Host config bootstrap + startup policy payload from /host-config.json.
 */
export async function initializeWebSession(game, { fetchFn } = {}) {
  const hostCfg = await fetchHostStartupConfig(fetchFn);
  assertHostStartupConfig(hostCfg);
  const boot = bootstrapEngineFromHostConfig(game, hostCfg);
  if (!boot.ok) return boot;

  return {
    ok: true,
    kind: "empty",
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    msg: boot.msg ?? null,
    default_save_filename: hostCfg.default_save_filename,
    startup_action: hostCfg.startup_action ?? "idle",
    startup_status: hostCfg.startup_status ?? null,
    startup_save_path: hostCfg.startup_save_path ?? null,
  };
}

/** Applies host startup policy: restore/new/idle on the host-resolved startup contract. */
export async function offerInitialNewGame(
  game,
  boot,
  generatingModal,
  { genWorker, fetchFn } = {},
) {
  if (!boot.ok) return boot;
  if (boot.kind !== "empty") return boot;

  if (boot.startup_action === "restore") {
    const restorePath = boot.startup_save_path;
    if (!restorePath) {
      return {
        ok: true,
        kind: "empty",
        state: game.getState(),
        legend: game.getLegend(),
        config: game.getConfig(),
        msg: "startup restore path missing; startup remains manual",
      };
    }
    const fetched = await fetchStartupSaveBytes(restorePath, fetchFn);
    if (!fetched.ok) {
      return {
        ok: true,
        kind: "empty",
        state: game.getState(),
        legend: game.getLegend(),
        config: game.getConfig(),
        msg: `${fetched.error}; startup remains manual`,
      };
    }
    const restored = open(game, fetched.bytes, { name: restorePath });
    if (!restored.ok) {
      return {
        ok: true,
        kind: "empty",
        state: game.getState(),
        legend: game.getLegend(),
        config: game.getConfig(),
        msg: `${restored.error ?? "startup restore failed"}; startup remains manual`,
      };
    }
    return {
      ok: true,
      kind: "restore",
      state: restored.state,
      legend: game.getLegend(),
      config: game.getConfig(),
      msg: restored.msg ?? "restored game",
    };
  }
  if (boot.startup_action === "idle") {
    return {
      ...boot,
      msg: boot.startup_status ?? null,
    };
  }

  const { difficulty, log_level: logLevel } = boot.config ?? {};
  if (difficulty == null || logLevel == null) {
    return { ok: false, error: "missing engine config after host bootstrap", kind: "empty" };
  }
  const started = await newGameWithGeneratingModal(game, generatingModal, {
    difficulty,
    logLevel,
    genWorker,
  });
  if (!started.ok && !started.cancelled) {
    return { ok: false, error: started.error ?? "New game failed", kind: "empty" };
  }
  if (started.cancelled) {
    return {
      ok: true,
      kind: "empty",
      state: game.getState(),
      legend: game.getLegend(),
      config: game.getConfig(),
      msg: null,
      cancelled: true,
    };
  }
  return {
    ok: true,
    kind: "new",
    state: started.state,
    legend: started.legend,
    config: started.config,
    msg: started.msg,
  };
}

function genWireFromEngine(game, options) {
  const cfg = game.getConfig();
  return {
    difficulty: options.difficulty ?? cfg.difficulty,
    logLevel: options.logLevel ?? cfg.log_level,
  };
}

/** Worker gen → import on main; modal + optional Cancel. */
export async function newGameWithWorkerGen(
  game,
  modal,
  { difficulty, logLevel, genWorker, onGenProgress, onProgressWire } = {},
) {
  const wire = genWireFromEngine(game, { difficulty, logLevel });
  const onProgress = mergeGenProgressHandlers(onProgressWire, onGenProgress);
  return runWithGeneratingDialog(modal, async (cancelRef) => {
    const { promise, cancel } = startGenInWorker({
      workerUrl: genWorker.workerUrl,
      wasmBytes: genWorker.wasmBytes,
      difficulty: wire.difficulty,
      logLevel: wire.logLevel,
      onProgress,
      WorkerCtor: genWorker.WorkerCtor,
      fetchFn: genWorker.fetchFn,
    });
    cancelRef.fn = cancel;
    const gen = await promise;
    if (gen.cancelled || !gen.ok) return gen;
    return applyGeneratedLineAsNewGame(game, gen.line, { difficulty: wire.difficulty });
  });
}

/** Main-thread `generatePuzzle` + import (modal spinner; blocks main thread). */
export async function newGameWithSyncGenerate(
  game,
  modal,
  { difficulty, logLevel, onGenProgress, onProgressWire } = {},
) {
  const wire = genWireFromEngine(game, { difficulty, logLevel });
  const onProgress = mergeGenProgressHandlers(onProgressWire, onGenProgress);
  return runWithGeneratingDialog(modal, async (cancelRef) => {
    cancelRef.fn = () => game.requestGenAbort?.();
    game.setGenProgressListener?.(onProgress ?? null);
    try {
      if (typeof game.generatePuzzle !== "function") {
        return newGame(game, { difficulty: wire.difficulty, logLevel: wire.logLevel });
      }
      const gen = game.generatePuzzle({ difficulty: wire.difficulty, logLevel: wire.logLevel });
      if (!gen.ok) {
        if (gen.error === "cancelled") return { ok: false, cancelled: true };
        return gen;
      }
      return applyGeneratedLineAsNewGame(game, gen.line, { difficulty: wire.difficulty });
    } finally {
      game.setGenProgressListener?.(null);
    }
  });
}

function shouldFallbackFromWorker(result) {
  if (result.ok || result.cancelled) return false;
  const err = result.error ?? "";
  // Only when Workers are missing — sync gen blocks the main thread (Cancel cannot run).
  return err === "workers unavailable";
}

/** First load / New: prefer worker gen; fall back to main-thread generate or legacy `init`. */
export async function newGameWithGeneratingModal(game, modal, options = {}) {
  const { genWorker, onGenProgress } = options;
  const wire = genWireFromEngine(game, options);
  const rowSink =
    typeof modal?.renderProgressRows === "function" ? createGenProgressModalSink(modal) : null;
  const onProgressWire = rowSink ? (phase, a, b) => rowSink.push(phase, a, b) : undefined;
  const genProgress = { onGenProgress, onProgressWire };
  if (genWorker && canUseGenWorker()) {
    const workerResult = await newGameWithWorkerGen(game, modal, {
      difficulty: wire.difficulty,
      logLevel: wire.logLevel,
      genWorker,
      ...genProgress,
    });
    if (!shouldFallbackFromWorker(workerResult)) return workerResult;
    return newGameWithSyncGenerate(game, modal, {
      difficulty: wire.difficulty,
      logLevel: wire.logLevel,
      ...genProgress,
    });
  }
  if (typeof game.generatePuzzle === "function") {
    return newGameWithSyncGenerate(game, modal, {
      difficulty: wire.difficulty,
      logLevel: wire.logLevel,
      ...genProgress,
    });
  }
  return runWithGeneratingDialog(modal, () =>
    Promise.resolve(newGame(game, { difficulty: wire.difficulty, logLevel: wire.logLevel })),
  );
}

export { canUseGenWorker };

/** Export the current grid as an 81-byte one-line puzzle string. */
export function exportPuzzle(game) {
  return game.exportPuzzle();
}

/** Fallback when Async Clipboard API is missing or denied (needs user-gesture select). */
export function copyTextWithExecCommand(text, doc) {
  if (!doc) return false;
  const ta = doc.createElement("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.position = "fixed";
  ta.style.left = "-9999px";
  doc.body.appendChild(ta);
  ta.select();
  try {
    return doc.execCommand("copy");
  } finally {
    doc.body.removeChild(ta);
  }
}

export const CLIPBOARD_READ_DENIED_MSG = "paste: clipboard read denied";

export async function readClipboardText({ clipboard = globalThis.navigator?.clipboard } = {}) {
  if (!clipboard?.readText) return { ok: false, error: CLIPBOARD_READ_DENIED_MSG };
  try {
    const text = await clipboard.readText();
    return { ok: true, text };
  } catch {
    return { ok: false, error: CLIPBOARD_READ_DENIED_MSG };
  }
}

export async function writeClipboardText(text, { clipboard = globalThis.navigator?.clipboard, doc } = {}) {
  const document = doc ?? globalThis.document;
  if (!document) return { ok: false, error: "copy: clipboard write denied" };
  if (clipboard?.writeText) {
    try {
      await clipboard.writeText(text);
      return { ok: true };
    } catch {
      // fall through to execCommand
    }
  }
  if (copyTextWithExecCommand(text, document)) return { ok: true };
  return { ok: false, error: "copy: clipboard write denied" };
}

/** One-line puzzle string from wasm, or an error result. */
export function puzzleLineForCopy(game) {
  const exported = exportPuzzle(game);
  if (!exported.ok) return exported;
  return { ok: true, text: new TextDecoder().decode(exported.bytes) };
}

/**
 * Copy current grid via `exportPuzzle`. Prefer `startCopyPuzzleOnClick` in UI handlers
 * so `writeText` runs in the same turn as the user click (activation).
 */
export async function copyPuzzleToClipboard(game, options = {}) {
  const line = puzzleLineForCopy(game);
  if (!line.ok) return line;
  return writeClipboardText(line.text, options);
}

/** Start clipboard write in the click turn; returns a Promise for tests. */
export function startCopyPuzzleOnClick(game, { clipboard = globalThis.navigator?.clipboard, doc } = {}) {
  const document = doc ?? globalThis.document;
  const line = puzzleLineForCopy(game);
  if (!line.ok) return Promise.resolve(line);
  const pending = clipboard?.writeText?.(line.text);
  if (pending) {
    return pending
      .then(() => ({ ok: true }))
      .catch(() => writeClipboardText(line.text, { clipboard: null, doc: document }));
  }
  return writeClipboardText(line.text, { clipboard: null, doc: document });
}

/** Import a one-line puzzle from page-read file text; engine owns the codec. */
export function importPuzzle(game, text) {
  const result = game.importPuzzle(text);
  if (!result.ok) return result;
  return {
    ok: true,
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    msg: result.msg ?? null,
  };
}
