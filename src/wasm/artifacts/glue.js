// glue.js — wasm/JS boundary for structured JSON exports.
// Browser + node compatible: no fetch, no DOM. The page owns fetch and
// presentation; this module loads the artifact and marshals JSON through
// linear memory.

const SCRATCH = 4096;
const NAME_SCRATCH = 65536;

const readCString = (memory, ptr) => {
  const view = new Uint8Array(memory.buffer);
  let end = ptr;
  while (view[end] !== 0) end += 1;
  return new TextDecoder().decode(view.subarray(ptr, end));
};

const writeBytes = (memory, ptr, bytes) => {
  const view = new Uint8Array(memory.buffer);
  while (memory.buffer.byteLength < ptr + bytes.length) memory.grow(1);
  view.set(bytes, ptr);
};

let genProgressListener = null;

function randomSeed32() {
  try {
    const c = globalThis.crypto;
    if (c?.getRandomValues) {
      const a = new Uint32Array(1);
      c.getRandomValues(a);
      return a[0] >>> 0;
    }
  } catch {
    // Fall through to time-based fallback if crypto is unavailable.
  }
  const t = Date.now() >>> 0;
  const r = Math.floor(Math.random() * 0x100000000) >>> 0;
  return (t ^ r) >>> 0;
}

export async function loadArtifact(wasmBytes) {
  const imports = {
    env: {
      sudoku_gen_progress(phase, a, b) {
        genProgressListener?.(phase, a, b);
      },
    },
  };
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  const { exports } = instance;
  const memory = exports.memory;

  const readJson = (ptr) => JSON.parse(readCString(memory, ptr));

  return {
    setGenProgressListener(fn) {
      genProgressListener = fn ?? null;
    },

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
      const themeWire = theme === "light" ? 1 : 0;
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

    /** Run `generateForPlay` in this instance; returns `{ ok, line }` JSON for worker handoff. */
    generatePuzzle({ difficulty = 1, logLevel = 1, seed } = {}) {
      const entropy = Number.isInteger(seed) ? (seed >>> 0) : randomSeed32();
      return readJson(exports.generatePuzzle(difficulty, logLevel, entropy));
    },

    /** Ask in-flight `generatePuzzle` to stop at the next progress boundary. */
    requestGenAbort() {
      exports.requestGenAbort?.();
    },

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

    getConfig() {
      return readJson(exports.getConfig());
    },

    getState() {
      return readJson(exports.getState());
    },

    serialize() {
      const ret = exports.serialize();
      const base = exports.outPtr();
      if (ret === base) return readJson(base);
      return { ok: true, bytes: new Uint8Array(memory.buffer, base, ret).slice() };
    },

    deserialize(bytes, { name } = {}) {
      writeBytes(memory, SCRATCH, bytes);
      if (name) {
        const nameBytes = new TextEncoder().encode(name);
        writeBytes(memory, NAME_SCRATCH, nameBytes);
        return readJson(exports.deserialize(SCRATCH, bytes.length, NAME_SCRATCH, nameBytes.length));
      }
      return readJson(exports.deserialize(SCRATCH, bytes.length, 0, 0));
    },

    importPuzzle(text) {
      const bytes = new TextEncoder().encode(text);
      writeBytes(memory, SCRATCH, bytes);
      return readJson(exports.importPuzzle(SCRATCH, bytes.length));
    },

    importPuzzleNewGame(text, difficulty) {
      const bytes = new TextEncoder().encode(text);
      writeBytes(memory, SCRATCH, bytes);
      return readJson(exports.importPuzzleNewGame(SCRATCH, bytes.length, difficulty));
    },

    exportPuzzle() {
      const ret = exports.exportPuzzle();
      const base = exports.outPtr();
      if (ret === base) return readJson(base);
      return { ok: true, bytes: new Uint8Array(memory.buffer, base, ret).slice() };
    },

    get exports() {
      return exports;
    },
  };
}
