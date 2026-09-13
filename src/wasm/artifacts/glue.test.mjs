// glue.test.mjs — wasm artifact smoke test after REPL retirement (#34).
// Full JSON contract tests land in #31.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { loadArtifact } from "./glue.js";

const here = dirname(fileURLToPath(import.meta.url));
const wasmBytes = readFileSync(join(here, "artifact.wasm"));

assert.ok(wasmBytes.length > 8, "artifact.wasm missing or empty");
assert.equal(
  String.fromCharCode(...wasmBytes.subarray(0, 4)),
  "\0asm",
  "artifact.wasm magic header",
);

const game = await loadArtifact(wasmBytes);
game.start();

assert.ok(game.exports.memory, "wasm memory export expected");
assert.equal(game.exports.step, undefined, "REPL step export must be gone");

console.log("glue.test.mjs OK");
