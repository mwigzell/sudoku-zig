// glue.js — wasm/JS boundary for structured JSON exports.
// Browser + node compatible: no fetch, no DOM. The page owns fetch and
// presentation; this module loads the artifact and marshals JSON through
// linear memory.

const SCRATCH = 4096;
const NAME_SCRATCH = 65536;

// Read NUL-terminated JSON/error payloads emitted by wasm exports.
const readCString = (memory, ptr) => {
  const view = new Uint8Array(memory.buffer);
  let end = ptr;
  while (view[end] !== 0) end += 1;
  return new TextDecoder().decode(view.subarray(ptr, end));
};

// Write request payloads into wasm linear memory scratch space.
const writeBytes = (memory, ptr, bytes) => {
  const view = new Uint8Array(memory.buffer);
  while (memory.buffer.byteLength < ptr + bytes.length) memory.grow(1);
  view.set(bytes, ptr);
};

let genProgressListener = null;

// Core's `logger.Severity` names, in rank order.
/** @type {import("../types").LogLevel[]} */
export const LOG_LEVELS = ["debug", "info", "warn", "err", "fatal"];

function randomSeed32() {
  try {
    const c = globalThis.crypto;
    if (c?.getRandomValues) {
      const a = new Uint32Array(1);
      c.getRandomValues(a);
      return a[0] >>> 0;
    }
  } catch (err) {
    console.info(`expected: crypto unavailable, using a time-based seed (${err?.message ?? String(err)})`);
  }
  const t = Date.now() >>> 0;
  const r = Math.floor(Math.random() * 0x100000000) >>> 0;
  return (t ^ r) >>> 0;
}

export async function loadArtifact(wasmBytes) {
  /** @type {WebAssembly.Exports} */
  let exports;
  /** @type {((level: import("../types").LogLevel, scope: string, text: string) => void) | null} */
  let logListener = null;
  const decodeText = (ptr, len) => new TextDecoder().decode(new Uint8Array(exports.memory.buffer, ptr, len));
  const imports = {
    env: {
      sudoku_gen_progress(phase, textPtr, textLen) {
        genProgressListener?.(phase, decodeText(textPtr, textLen));
      },
      sudoku_log(level, scopePtr, scopeLen, textPtr, textLen) {
        logListener?.(LOG_LEVELS[level] ?? LOG_LEVELS[LOG_LEVELS.length - 1], decodeText(scopePtr, scopeLen), decodeText(textPtr, textLen));
      },
    },
  };
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  exports = instance.exports;
  const memory = exports.memory;

  // Most wasm exports return an out-pointer to a JSON string response.
  const readJson = (ptr) => JSON.parse(readCString(memory, ptr));
  // JSON payload in at SCRATCH, JSON out.
  const callJsonPayload = (fn, payload) => {
    const bytes = new TextEncoder().encode(JSON.stringify(payload));
    writeBytes(memory, SCRATCH, bytes);
    return readJson(fn(SCRATCH, bytes.length));
  };

  return {
    // Worker and main-thread generators share one progress callback contract.
    setGenProgressListener(fn) {
      genProgressListener = fn ?? null;
    },

    /**
     * Where core's log lines go; core has already filtered them.
     * @param {((level: import("../types").LogLevel, scope: string, text: string) => void) | null} fn
     */
    setLogListener(fn) {
      logListener = fn ?? null;
    },

    /**
     * Whether core emits a line at `level` (its log level and the host's build mode decide).
     * @param {import("../types").LogLevel} level
     */
    logEnabled(level) {
      const rank = LOG_LEVELS.indexOf(level);
      return rank >= 0 && exports.logEnabled(rank) !== 0;
    },

    // Engine startup entry (same semantics as native new-game init).
    init({ difficulty = 1, logLevel = 1 } = {}) {
      return readJson(exports.init(difficulty, logLevel));
    },

    /** Host-resolved startup config (native disk+CLI analogue). All fields required — no glue defaults. */
    bootstrapHostConfig({
      difficulty,
      logLevel,
      theme,
      show_region,
      warn_solvability,
      auto_restore,
      auto_new,
      auto_save,
    }) {
      const themeWire = theme === "light" ? 1 : (theme === "system" ? 2 : 0);
      const regionWire = show_region ? 1 : 0;
      const warnWire = warn_solvability ? 1 : 0;
      const autoRestoreWire = auto_restore ? 1 : 0;
      const autoNewWire = auto_new ? 1 : 0;
      const autoSaveWire = auto_save ? 1 : 0;
      return readJson(
        exports.bootstrapHostConfig(
          difficulty,
          logLevel,
          themeWire,
          regionWire,
          warnWire,
          autoRestoreWire,
          autoNewWire,
          autoSaveWire,
        ),
      );
    },

    /**
     * The serving host's build facts; About marks the version when the host is a Debug build.
     * @param {import("../types").HostBuildInfo} info
     */
    setHostBuildInfo({ debug_build }) {
      exports.setHostBuildInfo(debug_build ? 1 : 0);
    },

    /** Run `generateForPlay` in this instance; returns `{ ok, line }` JSON for worker handoff. */
    generatePuzzle({ difficulty = 1, logLevel = 1, seed } = {}) {
      const entropy = Number.isInteger(seed) ? (seed >>> 0) : randomSeed32();
      return readJson(exports.generatePuzzle(difficulty, logLevel, entropy));
    },

    /** Ask in-flight `generatePuzzle` to stop at the next progress boundary. */
    requestGenAbort() {
      exports.requestGenAbort?.();
    },

    /**
     * Generic command bridge: JSON action in, JSON event out.
     * @param {import("../types").ExecAction} action
     */
    exec(action) {
      const json = JSON.stringify(action);
      writeBytes(memory, SCRATCH, new TextEncoder().encode(json));
      return readJson(exports.exec(SCRATCH, json.length));
    },

    getLegend() {
      return readJson(exports.getLegend());
    },

    getAbout() {
      return readJson(exports.getAbout());
    },

    /** @returns {import("../types").GenText} */
    getGenText() {
      return readJson(exports.getGenText());
    },

    /** @returns {Record<string, string>} */
    getCoreText() {
      return readJson(exports.getCoreText());
    },

    getConfig() {
      return readJson(exports.getConfig());
    },

    getState() {
      return readJson(exports.getState());
    },

    // SUD0 snapshot path: either JSON error (pointer unchanged) or raw bytes.
    toSaveFormat() {
      const ret = exports.toSaveFormat();
      const base = exports.outPtr();
      if (ret === base) return readJson(base);
      return { ok: true, bytes: new Uint8Array(memory.buffer, base, ret).slice() };
    },

    // One-line export path used by copy/export UI actions.
    toPuzzle() {
      const ret = exports.toPuzzle();
      const base = exports.outPtr();
      if (ret === base) return readJson(base);
      return { ok: true, bytes: new Uint8Array(memory.buffer, base, ret).slice() };
    },

    /** Start a core flow; returns its first step. */
    flowStart(start) {
      return callJsonPayload(exports.flowStart, start);
    },

    /** Run one player command end to end (same action JSON as `exec`); returns the first step. */
    commandStart(action) {
      return callJsonPayload(exports.commandStart, action);
    },

    /** Report one step result to the running flow; returns the next step. */
    flowNext(input) {
      return callJsonPayload(exports.flowNext, input);
    },

    /** End the running flow because the web side could not carry it on; core logs `reason` and returns its error step. */
    flowFail(reason) {
      const bytes = new TextEncoder().encode(reason ?? "");
      writeBytes(memory, SCRATCH, bytes);
      return readJson(exports.flowFail(SCRATCH, bytes.length));
    },

    /** Answer a reading step with what was read and, for a chosen file, its name; returns the next step. */
    flowRead(bytes, name) {
      writeBytes(memory, SCRATCH, bytes);
      const nameBytes = new TextEncoder().encode(name ?? "");
      writeBytes(memory, NAME_SCRATCH, nameBytes);
      return readJson(exports.flowRead(SCRATCH, bytes.length, NAME_SCRATCH, nameBytes.length));
    },
    get exports() {
      return exports;
    },
  };
}
