// android_bridge.test.mjs — the head script wraps the Java bridge before app code runs.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("./android_bridge.js", import.meta.url), "utf8");

/** Run the head script against a fake window; returns the window. */
function runInWindow(win) {
  win.addEventListener ??= () => {};
  vm.runInNewContext(source, { globalThis: win, String, Number, JSON });
  return win;
}

// ── No Java bridge (desktop browser): nothing is defined ──
{
  const win = runInWindow({});
  assert.equal(win.AndroidFileBridge, undefined);
}

// ── Java bridge present: AndroidFileBridge exists at once and parses the Java strings ──
{
  const calls = [];
  const native = {
    saveCurrentSudokuFile: (base64, name) => {
      calls.push(["current", base64, name]);
      return JSON.stringify({ ok: false, reason: "default_taken", name, dir: "Download/Sudoku" });
    },
    saveSudokuFile: (base64, name, saveAs) => {
      calls.push(["save", base64, name, saveAs]);
      return JSON.stringify({ ok: true, name });
    },
    saveSudokuFileToExisting: (base64) => {
      calls.push(["existing", base64]);
      return JSON.stringify({ ok: true, name: "sudoku.sud" });
    },
    currentSudokuFileName: () => null,
    openSudokuFile: () => JSON.stringify({ ok: false, cancelled: true }),
    notifyWebBootReady: () => calls.push(["ready"]),
  };
  const win = runInWindow({ __SudokuAndroidBridge: native });
  const bridge = win.AndroidFileBridge;
  assert.deepEqual(bridge.saveCurrentSudokuFile("QQ==", "sudoku.sud"), {
    ok: false,
    reason: "default_taken",
    name: "sudoku.sud",
    dir: "Download/Sudoku",
  });
  assert.deepEqual(bridge.saveSudokuFile("QQ==", "a.sud", 1), { ok: true, name: "a.sud" });
  assert.deepEqual(bridge.saveSudokuFileToExisting(undefined), { ok: true, name: "sudoku.sud" });
  assert.equal(bridge.currentSudokuFileName(), "");
  assert.deepEqual(bridge.openSudokuFile(), { ok: false, cancelled: true });
  bridge.notifyWebBootReady();
  assert.deepEqual(calls, [
    ["current", "QQ==", "sudoku.sud"],
    ["save", "QQ==", "a.sud", true],
    ["existing", ""],
    ["ready"],
  ]);
}

// ── Page errors are reported to the Java log ──
{
  const listeners = {};
  const logged = [];
  runInWindow({
    __SudokuAndroidBridge: { logJsError: (...args) => logged.push(args) },
    addEventListener: (type, fn) => {
      listeners[type] = fn;
    },
  });
  listeners.error({ message: "boom", filename: "app.js", lineno: 3, colno: 7 });
  listeners.unhandledrejection({ reason: "nope" });
  assert.deepEqual(logged, [
    ["boom", "app.js", 3, 7],
    ["nope", "promise", 0, 0],
  ]);
}

console.log("android_bridge.test.mjs OK");
