// glue.js — the wasm/JS boundary (issue #4 Step 8, slice 8a).
// Browser + node compatible: no fetch, no DOM. The page owns the fetch and
// the presentation; this module only builds the import table and decodes
// the screen text the engine writes through it.
//
// Import surface (module "env") — i32 args are linear-memory offsets:
//   bootstrap_difficulty() → u32
//   page_line_in(buf, cap) → u32            one queued line per call, 0 = EOF
//   page_bytes_out(bytes, len) → void       screen text out → `turns`
//   page_picker(buf, cap) → u32             placeholder (Step 10), 0 = cancelled
//   page_file_write(name, nlen, bytes, blen) → void   placeholder (Step 10)
//   page_file_read(name, nlen, buf, cap) → u32        placeholder (Step 10)
//
// page_line_in protocol: write min(len, cap-1) line bytes + NUL into the
// artifact's memory, return the line length; 0 = EOF (ends the run cleanly).

// .easy — page-origin bootstrap values land on the page side (#4 Step 9).
const BOOTSTRAP_DIFFICULTY = 0;

export async function loadArtifact(wasmBytes) {
  const handles = { turns: [], lines: [] };

  // Instantiated before _start may run; the env fns execute during it.
  // Keep the Memory object, never the buffer — a resize detaches old views.
  let memory;
  const view = (ptr, len) => new Uint8Array(memory.buffer, ptr, len);
  const enc = new TextEncoder();
  const dec = new TextDecoder();

  const env = {
    bootstrap_difficulty: () => BOOTSTRAP_DIFFICULTY,

    page_line_in: (buf, cap) => {
      const line = handles.lines.shift();
      if (line === undefined) return 0; // EOF — ends the run cleanly
      const bytes = enc.encode(line);
      const n = Math.min(bytes.length, cap - 1);
      view(buf, n).set(bytes.subarray(0, n));
      view(buf + n, 1)[0] = 0; // NUL terminator
      return n;
    },

    page_bytes_out: (bytes, len) => {
      handles.turns.push(dec.decode(view(bytes, len)));
    },

    // Step 10 placeholders — picker cancel / file arms inert.
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
      return handles.turns;
    },

    pushLine(str) {
      handles.lines.push(String(str));
    },
  };
}
