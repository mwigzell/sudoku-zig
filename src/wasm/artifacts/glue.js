// glue.js — wasm/JS boundary for structured JSON exports.
// Browser + node compatible: no fetch, no DOM. The page owns fetch and
// presentation; this module loads the artifact and marshals JSON through
// linear memory.

const SCRATCH = 4096;

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

export async function loadArtifact(wasmBytes) {
  const { instance } = await WebAssembly.instantiate(wasmBytes, {});
  const { exports } = instance;
  const memory = exports.memory;

  const readJson = (ptr) => JSON.parse(readCString(memory, ptr));

  return {
    init({ difficulty = 1, logLevel = 1 } = {}) {
      return readJson(exports.init(difficulty, logLevel));
    },

    exec(action) {
      const json = JSON.stringify(action);
      writeBytes(memory, SCRATCH, new TextEncoder().encode(json));
      return readJson(exports.exec(SCRATCH, json.length));
    },

    getLegend() {
      return readJson(exports.getLegend());
    },

    getConfig() {
      return readJson(exports.getConfig());
    },

    getState() {
      return readJson(exports.getState());
    },

    serialize() {
      const len = exports.serialize();
      assertLen(len);
      return new Uint8Array(memory.buffer, exports.outPtr(), len).slice();
    },

    deserialize(bytes) {
      writeBytes(memory, SCRATCH, bytes);
      return readJson(exports.deserialize(SCRATCH, bytes.length));
    },

    get exports() {
      return exports;
    },
  };
}

function assertLen(len) {
  if (!len) throw new Error("serialize returned empty buffer");
}
