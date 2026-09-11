// glue.js — the wasm/JS boundary.
// Browser + node compatible: no fetch, no DOM. The page owns the fetch and
// the presentation; this module only builds the import table, hands each
// page line to the step export, and drains the screen text the engine
// writes back through page_bytes_out.
//
// Import surface (module "env") — i32 args are linear-memory offsets:
//   bootstrap_difficulty() → u32
//   page_line_in(buf, cap) → u32            fallback reader, 0 = EOF
//   page_bytes_out(bytes, len) → void       screen text out → `turns`
//   page_picker(buf, cap) → u32             placeholder (open/save), 0 = cancelled
//   page_file_write(name, nlen, bytes, blen) → void   placeholder (open/save)
//   page_file_read(name, nlen, buf, cap) → u32        placeholder (open/save)
//
// step(line) protocol: the line bytes go into a scratch page of the
// artifact's exported memory, the step export runs one command turn, and
// the return byte is the done flag (1 = session over). The page never
// feeds a line to the wasm side any other way.

const BOOTSTRAP_DIFFICULTY = 0;
const SCRATCH = 16 * 1024 * 1024; // inbound-line page, well above the module's own data

export async function loadArtifact(wasmBytes) {
  const screen = [];

  // Instantiated before _start may run; the env fns execute during it.
  // Keep the Memory object, never the buffer — a resize detaches old views.
  let memory;
  const view = (ptr, len) => new Uint8Array(memory.buffer, ptr, len);
  const enc = new TextEncoder();
  const dec = new TextDecoder();

  const env = {
    bootstrap_difficulty: () => BOOTSTRAP_DIFFICULTY,

    // The page feeds lines through step(); this only answers a stray read
    // on the wasm side with EOF so the run ends cleanly.
    page_line_in: () => 0,

    page_bytes_out: (bytes, len) => {
      screen.push(dec.decode(view(bytes, len)));
    },

    // open/save placeholders — picker cancel / file arms inert.
    page_picker: () => 0,
    page_file_write: () => {},
    page_file_read: () => 0,
  };

  const { instance } = await WebAssembly.instantiate(wasmBytes, { env });
  memory = instance.exports.memory;

  let started = false;
  return {
    start() {
      if (started) throw new Error("start() called twice");
      started = true;
      instance.exports._start();
    },

    get turns() {
      return screen;
    },

    // One command turn: the line in, the resulting screen text and the
    // done flag out.
    step(line) {
      const bytes = enc.encode(String(line));
      while (memory.buffer.byteLength < SCRATCH + bytes.length) memory.grow(1);
      const before = screen.length;
      view(SCRATCH, bytes.length).set(bytes);
      const done = instance.exports.step(SCRATCH, bytes.length) === 1;
      return { text: screen.slice(before).join("\n"), done };
    },
  };
}
