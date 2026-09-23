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

    get exports() {
      return exports;
    },
  };
}
