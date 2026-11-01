// gen_progress_format.js — `(phase, a, b)` progress strings for gen UI (wasm wire sync).

/** Wire encoding from wasm `encodeProgressWire` / Zig `GenProgressEvent`. */
export function formatGenProgress(phase, a, b) {
  switch (phase) {
    case 0:
      return "Generating: new attempt…";
    case 1:
      return "Generating: carving clues…";
    case 2:
      return `Generating: try ${a}/${b}`;
    case 3:
      return `Generating: ${a} givens (target ≤${b})`;
    case 4:
      return `Generating: ${a} givens → ≤${b}`;
    case 5:
      return `Generating: checking uniqueness (${a} givens)…`;
    default:
      return "Generating…";
  }
}
