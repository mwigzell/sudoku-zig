// glue.js — minimal wasm/JS loader after REPL retirement (#34).
// Structured exports (init/exec/serialize) arrive in #31; this module only
// instantiates the artifact and runs _start for smoke tests and serve.

export async function loadArtifact(wasmBytes) {
  const { instance } = await WebAssembly.instantiate(wasmBytes, {});

  let started = false;
  return {
    start() {
      if (started) throw new Error("start() called twice");
      started = true;
      instance.exports._start();
    },

    get exports() {
      return instance.exports;
    },
  };
}
