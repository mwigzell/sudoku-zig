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

    /** Empty-grid engine only (no generation); main thread before worker handoff. */
    bootstrap({ difficulty = 1, logLevel = 1 } = {}) {
      return readJson(exports.bootstrap(difficulty, logLevel));
    },

    /** Run `generateForPlay` in this instance; returns `{ ok, line }` JSON for worker handoff. */
    generatePuzzle({ difficulty = 1, logLevel = 1 } = {}) {
      return readJson(exports.generatePuzzle(difficulty, logLevel));
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
