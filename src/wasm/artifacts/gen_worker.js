// gen_worker.js — puzzle generation in a Web Worker (same wasm + glue as the page).

import * as glue from "./glue.js";

let game = null;

self.onmessage = async (event) => {
  const msg = event.data;
  if (msg?.type === "cancel") {
    game?.requestGenAbort?.();
    return;
  }
  if (msg?.type !== "run") return;

  try {
    if (!game) {
      game = await glue.loadArtifact(msg.wasmBytes);
      game.setLogListener((level, scope, text) => self.postMessage({ type: "log", level, scope, text }));
    }
    game.setGenProgressListener((phase, text) => {
      self.postMessage({ type: "progress", phase, text });
    });
    const result = game.generatePuzzle({
      difficulty: msg.difficulty ?? 1,
      logLevel: msg.logLevel ?? 1,
    });
    game.setGenProgressListener(null);
    if (result.error === "cancelled") {
      self.postMessage({ type: "cancelled" });
      return;
    }
    if (!result.ok) {
      self.postMessage({ type: "error", error: result.error ?? "generate failed" });
      return;
    }
    self.postMessage({ type: "done", line: result.line });
  } catch (err) {
    game?.setGenProgressListener(null);
    self.postMessage({ type: "error", error: err?.message ?? String(err) });
  }
};
