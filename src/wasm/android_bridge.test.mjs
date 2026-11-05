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
  const wrote = (step) => (base64, name) => {
    calls.push([step, base64, name]);
    return JSON.stringify({ ok: true, name });
  };
  const native = {
    save: wrote("save"),
    saveAs: wrote("saveAs"),
    autosave: (base64, name) => {
      calls.push(["autosave", base64, name]);
      return JSON.stringify({ ok: false, reason: "taken", name });
    },
    reclaimFile: (base64) => {
      calls.push(["reclaimFile", base64]);
      return JSON.stringify({ ok: true, name: "sudoku.sud" });
    },
    open: () => JSON.stringify({ ok: false, cancelled: true }),
    importPuzzle: () => JSON.stringify({ ok: true, name: "p.txt", base64: "QQ==" }),
    exportPuzzle: wrote("exportPuzzle"),
    currentSudokuFileName: () => null,
    defaultFileExists: (name) => name === "sudoku.sud",
    notifyWebBootReady: () => calls.push(["ready"]),
  };
  const win = runInWindow({ __SudokuAndroidBridge: native });
  const bridge = win.AndroidFileBridge;
  assert.deepEqual(bridge.save("QQ==", "a.sud"), { ok: true, name: "a.sud" });
  assert.deepEqual(bridge.saveAs("QQ==", "b.sud"), { ok: true, name: "b.sud" });
  assert.deepEqual(bridge.autosave("QQ==", "sudoku.sud"), {
    ok: false,
    reason: "taken",
    name: "sudoku.sud",
  });
  assert.deepEqual(bridge.reclaimFile(undefined), { ok: true, name: "sudoku.sud" });
  assert.deepEqual(bridge.open(), { ok: false, cancelled: true });
  assert.deepEqual(bridge.importPuzzle(), { ok: true, name: "p.txt", base64: "QQ==" });
  assert.deepEqual(bridge.exportPuzzle("QQ==", "sudoku.txt"), { ok: true, name: "sudoku.txt" });
  assert.equal(bridge.currentSudokuFileName(), "");
  assert.equal(bridge.defaultFileExists("sudoku.sud"), true);
  assert.equal(bridge.defaultFileExists(undefined), false);
  bridge.notifyWebBootReady();
  assert.deepEqual(calls, [
    ["save", "QQ==", "a.sud"],
    ["saveAs", "QQ==", "b.sud"],
    ["autosave", "QQ==", "sudoku.sud"],
    ["reclaimFile", ""],
    ["exportPuzzle", "QQ==", "sudoku.txt"],
    ["ready"],
  ]);
}

console.log("android_bridge.test.mjs OK");
