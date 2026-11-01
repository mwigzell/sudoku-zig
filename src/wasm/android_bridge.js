// android_bridge.js — Android WebView only: wraps the Java `__SudokuAndroidBridge` (string results)
// as `window.AndroidFileBridge` (JS objects). Loaded as a classic <head> script so the bridge exists
// before any app code looks for it; does nothing outside Android.
(function (win) {
  const native = win.__SudokuAndroidBridge;
  if (!native) return;
  const text = (value) => String(value || "");

  /** @type {import("./types").AndroidFileBridge} */
  win.AndroidFileBridge = {
    saveSudokuFile: (base64, suggestedName, saveAs) =>
      JSON.parse(native.saveSudokuFile(text(base64), text(suggestedName), !!saveAs)),
    saveSudokuFileToExisting: (base64) => JSON.parse(native.saveSudokuFileToExisting(text(base64))),
    saveCurrentSudokuFile: (base64, suggestedName) =>
      JSON.parse(native.saveCurrentSudokuFile(text(base64), text(suggestedName))),
    currentSudokuFileName: () => text(native.currentSudokuFileName()),
    openSudokuFile: () => JSON.parse(native.openSudokuFile()),
    setSystemBars: (themeName) => native.setSystemBars(String(themeName || "dark")),
    notifyWebBootReady: () => native.notifyWebBootReady(),
  };

  win.addEventListener("error", (e) => {
    native.logJsError(text(e?.message) || "unknown js error", text(e?.filename), Number(e?.lineno || 0), Number(e?.colno || 0));
  });
  win.addEventListener("unhandledrejection", (e) => {
    native.logJsError(e?.reason != null ? String(e.reason) : "unhandled rejection", "promise", 0, 0);
  });
})(globalThis);
