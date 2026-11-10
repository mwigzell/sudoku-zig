// shell_fit.test.mjs — measured layout: the shipped shell must fit the viewport without the document scrolling.
// Drives headless Chromium over CDP against a local static server of the real page + wasm artifact.

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, extname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const wasmSrc = dirname(here); // src/wasm
const repoRoot = dirname(dirname(wasmSrc));

/** Viewports the shell must fit, in CSS pixels. `device` is the 720x1280 emulator at dpr 2,
 *  which loses 24px to the status bar and 48px to the navigation bar. */
const VIEWPORTS = [
  { width: 350, height: 720, label: "smallest supported" },
  { width: 393, height: 560, label: "small phone" },
  { width: 360, height: 568, label: "device" },
  { width: 393, height: 700, label: "tall phone" },
  { width: 720, height: 1280, label: "large" },
  { width: 1280, height: 800, label: "desktop" },
];

/** Shell regions that must stay fully visible: menubar, status bar, board and play pad. */
const REGION_SELECTORS = ["#menu-bar", "#status-bar", "#board", "#play-pad"];

/** Regions that share the board's column and must be centred on it. */
const BAR_SELECTORS = ["#status-bar", "#play-pad"];

/** Subpixel slack for layout rounding; anything larger is a real overflow. */
const EDGE_TOLERANCE_PX = 1;

/** Width at or below which the page switches to the phone layout (26rem + 2px in the page's CSS). */
const COMPACT_MAX_WIDTH_PX = 418;

/** Side gutter phones keep between the screen edge and the board, status bar and pad. */
const COMPACT_GUTTER_PX = 8;

/** The status bar sits this close under the board; more reads as a floating bar, not an attached one. */
const STATUS_GUTTER_MAX_PX = 8;

/** How long a resize gets to settle before its page errors are read. */
const RESIZE_SETTLE_MS = 350;

/** How long one browser command or one page boot may take before the gate calls it broken. */
const COMMAND_TIMEOUT_MS = 15_000;

/** The host startup contract the served page boots from (mirrors the serving host's `/host-config.json`). */
const HOST_CONFIG = {
  config: {
    difficulty: "easy",
    log_level: "info",
    theme: "dark",
    show_region: false,
    warn_solvability: false,
    auto_restore: false,
    auto_new: false,
    auto_save: false,
    show_marks: true,
  },
  default_save_filename: "sudoku.sav",
  startup_save_path: null,
};

const CONTENT_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".wasm": "application/wasm",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

/**
 * Find an executable on PATH without shelling out.
 * @param {string} name file name to look for
 * @returns {string | null} absolute path when found and executable
 */
function findOnPath(name) {
  for (const dir of (process.env.PATH ?? "").split(":")) {
    if (!dir) continue;
    const candidate = join(dir, name);
    try {
      if (existsSync(candidate) && (statSync(candidate).mode & 0o111) !== 0) return candidate;
    } catch {
      // Unreadable PATH entry: keep looking.
    }
  }
  return null;
}

/**
 * Resolve the Chromium binary the gate drives. Fails loudly rather than skipping: a missing browser
 * is a broken gate, not a pass. The binary must answer `Emulation.setDeviceMetricsOverride`, which
 * desktop-brand browsers built on their own windowing (Vivaldi) do not — hence plain Chromium/Chrome.
 * @returns {string} absolute path to a Chromium executable
 */
function resolveBrowser() {
  const override = process.env.SUDOKU_TEST_BROWSER;
  if (override) {
    if (!existsSync(override)) {
      throw new Error(`SUDOKU_TEST_BROWSER is set to ${override}, which does not exist`);
    }
    return override;
  }
  const names = ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"];
  for (const name of names) {
    const found = findOnPath(name);
    if (found) return found;
  }
  const cached = chromeForTestingBuild();
  if (cached) return cached;
  throw new Error(
    `no Chromium binary for the measured-layout gate; looked for ${names.join(", ")} on PATH and a ` +
      `Chrome-for-Testing build under ${join(homedir(), ".agent-browser", "browsers")}. ` +
      `Install chromium, or set SUDOKU_TEST_BROWSER to a Chromium executable.`,
  );
}

/**
 * A Chrome-for-Testing build parked by local browser tooling, used when no Chromium is on PATH.
 * @returns {string | null} executable path
 */
function chromeForTestingBuild() {
  const root = join(homedir(), ".agent-browser", "browsers");
  if (!existsSync(root)) return null;
  const builds = readdirSync(root)
    .filter((entry) => entry.startsWith("chrome-"))
    .sort()
    .reverse();
  for (const build of builds) {
    const executable = join(root, build, "chrome");
    if (existsSync(executable)) return executable;
  }
  return null;
}

/** Every file under `src/wasm`, keyed by base name, for the page's flat URL namespace (`/board.js`, `/menus/menu.js`, …). */
const assetIndex = new Map();

/**
 * Index `src/wasm` recursively so the server can answer the page's flat module URLs.
 * @param {string} dir directory to walk
 */
function indexDir(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      indexDir(full);
      continue;
    }
    const list = assetIndex.get(entry.name) ?? [];
    list.push(full);
    assetIndex.set(entry.name, list);
  }
}

/**
 * Map a request URL path onto a file on disk.
 * @param {string} urlPath request path, e.g. `/flows/steps.js`
 * @returns {string | null} file path, or null when nothing matches
 */
function resolveAsset(urlPath) {
  if (urlPath === "/" || urlPath === "/index.html") return join(here, "page.html");
  const bare = urlPath.replace(/^\/+/, "");
  const direct = [join(wasmSrc, bare), join(here, bare)].find(
    (path) => existsSync(path) && statSync(path).isFile(),
  );
  if (direct) return direct;

  const matches = assetIndex.get(bare.split("/").pop() ?? "") ?? [];
  if (matches.length === 1) return matches[0];
  if (matches.length > 1) {
    throw new Error(`asset ${urlPath} is ambiguous: ${matches.map((m) => relative(repoRoot, m)).join(", ")}`);
  }
  return null;
}

/**
 * Static server for the shell, plus the host startup endpoints the page fetches at boot.
 * @returns {Promise<{ server: import("node:http").Server, port: number }>} listening server and its port
 */
async function startServer() {
  indexDir(wasmSrc);
  const server = createServer((req, res) => {
    const urlPath = (req.url ?? "/").split("?")[0];
    if (urlPath === "/host-config.json" || urlPath === "/build-info.json") {
      const body = urlPath === "/host-config.json" ? HOST_CONFIG : { debug_build: false };
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
      return;
    }
    // The page posts its client log here; a 404 would make it log a console error on every line.
    if (urlPath === "/client-log") {
      res.writeHead(204);
      res.end();
      return;
    }
    let file;
    try {
      file = resolveAsset(urlPath);
    } catch (err) {
      res.writeHead(500, { "content-type": "text/plain" });
      res.end(String(err && err.message ? err.message : err));
      return;
    }
    if (!file) {
      res.writeHead(404, { "content-type": "text/plain" });
      res.end(`not found: ${urlPath}`);
      return;
    }
    res.writeHead(200, { "content-type": CONTENT_TYPES[extname(file)] ?? "application/octet-stream" });
    res.end(readFileSync(file));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, port: server.address().port };
}

/**
 * Minimal CDP client: JSON-RPC over one page-target WebSocket. Every command times out, so a browser
 * that stops answering fails the gate instead of hanging it.
 * @param {string} wsUrl DevTools websocket URL of the page target
 */
async function connectCdp(wsUrl) {
  const socket = new WebSocket(wsUrl);
  const pending = new Map();
  /** Events arrive unsolicited (no id); listeners collect them, e.g. page crashes and console errors. */
  const eventListeners = [];
  let nextId = 1;
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", () => reject(new Error(`CDP socket failed: ${wsUrl}`)), { once: true });
  });
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.method) {
      for (const listener of eventListeners) listener(message);
      return;
    }
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    if (message.error) entry.reject(new Error(`${entry.method}: ${message.error.message}`));
    else entry.resolve(message.result);
  });
  return {
    /**
     * @param {string} method CDP method
     * @param {object} [params] method parameters
     * @returns {Promise<any>} method result
     */
    send(method, params = {}) {
      const id = nextId++;
      const answered = new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject, method });
        socket.send(JSON.stringify({ id, method, params }));
      });
      let timer;
      const timeout = new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`${method} did not answer within ${COMMAND_TIMEOUT_MS}ms`)),
          COMMAND_TIMEOUT_MS,
        );
      });
      // A watchdog, not a wait: clear it so a finished run exits at once.
      return Promise.race([answered, timeout]).finally(() => clearTimeout(timer));
    },
    close() {
      socket.close();
    },
    /**
     * Subscribe to CDP events such as `Runtime.exceptionThrown`.
     * @param {(message: any) => void} listener called for every event
     */
    on(listener) {
      eventListeners.push(listener);
    },
  };
}

/**
 * Start a headless browser and attach to a fresh page target.
 * @param {string} binary Chromium executable
 * @returns {Promise<{ cdp: Awaited<ReturnType<typeof connectCdp>>, child: import("node:child_process").ChildProcess, profile: string }>}
 */
async function launchBrowser(binary) {
  const profile = mkdtempSync(join(tmpdir(), "sudoku-shell-fit-"));
  const child = spawn(
    binary,
    [
      "--headless",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-gpu",
      "--disable-extensions",
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += String(chunk);
  });

  const portFile = join(profile, "DevToolsActivePort");
  const deadline = Date.now() + 30_000;
  while (!existsSync(portFile)) {
    if (child.exitCode !== null) throw new Error(`browser exited (${child.exitCode}) before CDP was ready:\n${stderr}`);
    if (Date.now() > deadline) throw new Error(`browser did not open CDP on ${portFile}:\n${stderr}`);
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const port = readFileSync(portFile, "utf8").split("\n")[0];
  // A page target of our own: the browser's first window may be its own UI, not an empty page.
  const target = await (
    await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })
  ).json();
  const cdp = await connectCdp(target.webSocketDebuggerUrl);
  return { cdp, child, profile };
}

/**
 * Evaluate an expression in the page and return its value.
 * @param {Awaited<ReturnType<typeof connectCdp>>} cdp client
 * @param {string} expression JavaScript expression
 * @returns {Promise<any>} evaluated value
 */
async function evaluate(cdp, expression) {
  const result = await cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) {
    throw new Error(`page evaluation failed: ${result.exceptionDetails.text} ${expression}`);
  }
  return result.result.value;
}

/**
 * Load the shell at one viewport and wait until the grid has rendered.
 * @param {Awaited<ReturnType<typeof connectCdp>>} cdp client
 * @param {string} url page URL
 * @param {{ width: number, height: number, label: string }} viewport target viewport in CSS pixels
 */
async function openShell(cdp, url, viewport) {
  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: viewport.width,
    height: viewport.height,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await cdp.send("Page.navigate", { url });

  const deadline = Date.now() + 30_000;
  for (;;) {
    const ready = await evaluate(
      cdp,
      "({ done: document.readyState === 'complete', cells: document.querySelectorAll('#board [role=\"gridcell\"]').length })",
    );
    if (ready.done && ready.cells === 81) break;
    if (Date.now() > deadline) {
      throw new Error(
        `${url} did not finish booting at ${viewport.width}x${viewport.height}: ` +
          `readyState complete=${ready.done}, grid cells=${ready.cells} (expected 81)`,
      );
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  await evaluate(cdp, "document.fonts.ready.then(() => true)");
}

/**
 * Measure the shell in the loaded page.
 * @param {Awaited<ReturnType<typeof connectCdp>>} cdp client
 * @returns {Promise<{ scrollHeight: number, scrollWidth: number, innerWidth: number, innerHeight: number, regions: Record<string, { top: number, left: number, bottom: number, right: number, width: number, height: number } | null> }>}
 */
async function measure(cdp) {
  const expression = `(() => {
    const scrolling = document.scrollingElement || document.documentElement;
    const regions = {};
    for (const selector of ${JSON.stringify(REGION_SELECTORS)}) {
      const el = document.querySelector(selector);
      if (!el) { regions[selector] = null; continue; }
      const r = el.getBoundingClientRect();
      regions[selector] = { top: r.top, left: r.left, bottom: r.bottom, right: r.right, width: r.width, height: r.height };
    }
    return {
      scrollHeight: scrolling.scrollHeight,
      scrollWidth: scrolling.scrollWidth,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      regions,
    };
  })()`;
  return evaluate(cdp, expression);
}

/**
 * Scroll the document and report where it came to rest.
 * @param {Awaited<ReturnType<typeof connectCdp>>} cdp client
 * @returns {Promise<number>} `window.scrollY` after scrolling down 40px
 */
async function scrollDownAndRead(cdp) {
  return evaluate(
    cdp,
    `new Promise((resolve) => {
      window.scrollTo(0, 40);
      requestAnimationFrame(() => requestAnimationFrame(() => resolve(window.scrollY)));
    })`,
  );
}

/**
 * Read the board's CSS floor and its drawn width, so the two can be compared.
 * @param {Awaited<ReturnType<typeof connectCdp>>} cdp client
 * @returns {Promise<{ width: number, floor: number }>} board width in px and its min-width
 */
async function measureBoardFloor(cdp) {
  return evaluate(
    cdp,
    `(() => {
      const board = document.getElementById("board");
      const style = getComputedStyle(board);
      return { width: board.getBoundingClientRect().width, floor: parseFloat(style.minWidth) || 0 };
    })()`
  );
}

/**
 * Report every way the shell fails to fit one viewport — empty means it fits.
 * @param {Awaited<ReturnType<typeof measure>>} layout measured layout
 * @param {number} scrollY document scroll offset after a downward scroll
 * @returns {string[]} human-readable failures
 */
function fitFailures(layout, scrollY) {
  const failures = [];
  const { innerWidth, innerHeight } = layout;
  if (layout.scrollHeight > innerHeight + EDGE_TOLERANCE_PX) {
    failures.push(`document scrolls vertically (scrollHeight ${layout.scrollHeight} > innerHeight ${innerHeight})`);
  }
  if (layout.scrollWidth > innerWidth + EDGE_TOLERANCE_PX) {
    failures.push(`document scrolls horizontally (scrollWidth ${layout.scrollWidth} > innerWidth ${innerWidth})`);
  }
  for (const selector of REGION_SELECTORS) {
    if (innerWidth <= COMPACT_MAX_WIDTH_PX && selector === "#menu-bar") {
      const bar = layout.regions[selector];
      if (bar && (bar.left > EDGE_TOLERANCE_PX || innerWidth - bar.right > EDGE_TOLERANCE_PX)) {
        failures.push(`menubar is not full width on a phone (left ${bar.left.toFixed(1)}, right gap ${(innerWidth - bar.right).toFixed(1)})`);
      }
    }
    if (innerWidth <= COMPACT_MAX_WIDTH_PX && selector !== "#menu-bar") {
      const inset = layout.regions[selector];
      if (inset && inset.left < COMPACT_GUTTER_PX - EDGE_TOLERANCE_PX) {
        failures.push(`${selector} touches the screen edge on a phone (left ${inset.left.toFixed(1)})`);
      }
      if (inset && innerWidth - inset.right < COMPACT_GUTTER_PX - EDGE_TOLERANCE_PX) {
        failures.push(`${selector} touches the screen edge on a phone (right gap ${(innerWidth - inset.right).toFixed(1)})`);
      }
    }
    const rect = layout.regions[selector];
    if (!rect) {
      failures.push(`${selector} is missing from the page`);
      continue;
    }
    if (rect.height <= 0 || rect.width <= 0) {
      failures.push(`${selector} has no rendered size (${rect.width}x${rect.height})`);
      continue;
    }
    if (rect.top < -EDGE_TOLERANCE_PX) failures.push(`${selector} starts above the viewport (top ${rect.top})`);
    if (rect.bottom > innerHeight + EDGE_TOLERANCE_PX) {
      failures.push(`${selector} runs past the viewport bottom (bottom ${rect.bottom} > ${innerHeight})`);
    }
    if (rect.left < -EDGE_TOLERANCE_PX) failures.push(`${selector} starts left of the viewport (left ${rect.left})`);
    if (rect.right > innerWidth + EDGE_TOLERANCE_PX) {
      failures.push(`${selector} runs past the viewport right (right ${rect.right} > ${innerWidth})`);
    }
  }
  if (scrollY !== 0) failures.push(`document scrolls on demand (scrollY ${scrollY} after scrollTo(0, 40))`);
  // The board hugs the menubar: nothing sits between them except the bar's own border.
  // Below the board the status bar owns the space: it is centred on it, and centred on the board's column.
  const board = layout.regions["#board"];
  if (board) {
    const above = board.top - layout.regions["#menu-bar"].bottom;
    if (above > EDGE_TOLERANCE_PX) {
      failures.push(`gutter above the board is ${above.toFixed(1)}px; it must hug the menubar`);
    }
    for (const selector of BAR_SELECTORS) {
      const rect = layout.regions[selector];
      if (!rect) continue;
      const leftGap = rect.left - board.left;
      const rightGap = board.right - rect.right;
      if (Math.abs(leftGap) > EDGE_TOLERANCE_PX || Math.abs(rightGap) > EDGE_TOLERANCE_PX) {
        failures.push(`${selector} is not centred on the board (left gap ${leftGap}, right gap ${rightGap})`);
      }
    }
    // The status bar is attached to the board: a small gutter, never a floating gap.
    const status = layout.regions["#status-bar"];
    const gutter = status.top - board.bottom;
    if (gutter > STATUS_GUTTER_MAX_PX + EDGE_TOLERANCE_PX) {
      failures.push(`status bar floats ${gutter.toFixed(1)}px below the board; it must stay attached`);
    }
    if (gutter < -EDGE_TOLERANCE_PX) {
      failures.push(`status bar overlaps the board (top ${gutter.toFixed(1)}px above its bottom edge)`);
    }
    const pad = layout.regions["#play-pad"];
    const padGutter = pad.top - status.bottom;
    if (padGutter > STATUS_GUTTER_MAX_PX + EDGE_TOLERANCE_PX) {
      failures.push(`play pad floats ${padGutter.toFixed(1)}px below the status bar; the fixture must stay together`);
    }
    if (padGutter < -EDGE_TOLERANCE_PX) {
      failures.push(`play pad overlaps the status bar by ${(status.bottom - pad.top).toFixed(1)}px`);
    }
  }
  return failures;
}

/**
 * Resize a live page instead of reloading it: a fit loop between observer and layout shows up here.
 * @param {Awaited<ReturnType<typeof connectCdp>>} cdp client
 * @param {string} url shell page url
 * @returns {Promise<string[]>} human-readable failures
 */
async function resizeFailures(cdp, url) {
  const failures = [];
  const sizes = [[1100, 760], [900, 700], [1280, 800], [1600, 900]];
  drainPageErrors();
  await openShell(cdp, url, { width: 1280, height: 800, label: "desktop" });
  for (const [width, height] of sizes) {
    await cdp.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
    await new Promise((resolve) => setTimeout(resolve, RESIZE_SETTLE_MS));
  }
  for (const error of drainPageErrors()) failures.push(`page error while resizing: ${error}`);
  return failures;
}

async function boardFloorFailures(cdp, url) {
  const failures = [];
  const sizes = [
    { width: 700, height: 560, label: "roomy" },
    { width: 520, height: 420, label: "cramped" },
    { width: 420, height: 340, label: "tiny" },
    { width: 1100, height: 760, label: "wide again" },
  ];
  const widths = [];
  let floor = 0;
  for (const size of sizes) {
    await openShell(cdp, url, size);
    const board = await measureBoardFloor(cdp);
    floor = board.floor;
    widths.push({ label: size.label, width: board.width });
  }
  const [roomy, cramped, tiny, wide] = widths;
  if (!(floor > 0)) failures.push("the board declares no minimum size; it can shrink into nothing");
  if (tiny.width < floor - EDGE_TOLERANCE_PX) {
    failures.push(`board shrank to ${tiny.width.toFixed(0)}px, below its ${floor.toFixed(0)}px minimum`);
  }
  if (Math.abs(cramped.width - tiny.width) > EDGE_TOLERANCE_PX) {
    failures.push(`board keeps shrinking past its minimum (${cramped.width.toFixed(0)}px then ${tiny.width.toFixed(0)}px)`);
  }
  if (!(wide.width > tiny.width + EDGE_TOLERANCE_PX)) {
    failures.push(`board does not grow back with the window (${tiny.width.toFixed(0)}px stayed ${wide.width.toFixed(0)}px)`);
  }
  if (!(roomy.width >= floor - EDGE_TOLERANCE_PX)) {
    failures.push(`board drew ${roomy.width.toFixed(0)}px in a roomy window, below its minimum`);
  }
  return failures;
}

const browserPath = resolveBrowser();
const { server, port } = await startServer();
const url = `http://127.0.0.1:${port}/`;
const { cdp, child, profile } = await launchBrowser(browserPath);

/** Page errors raised since the last drain: a broken page is as much a failure as a scrolling one. */
const pageErrors = [];
cdp.on((message) => {
  if (message.method === "Runtime.exceptionThrown") {
    const details = message.params?.exceptionDetails ?? {};
    const text = details.exception?.description ?? details.text ?? "uncaught page error";
    pageErrors.push(text.split("\n")[0].trim());
    return;
  }
  // The page handles window error events itself, so a swallowed error still has to fail the gate.
  if (message.method === "Runtime.consoleAPICalled" && message.params?.type === "error") {
    const said = (message.params.args ?? []).map((arg) => arg.value ?? arg.description ?? arg.type).join(" ");
    pageErrors.push(said.split("\n")[0].trim());
  }
});

/**
 * Take the page errors seen so far, deduplicated, and clear the buffer.
 * @returns {string[]} distinct error messages
 */
function drainPageErrors() {
  const seen = [...new Set(pageErrors)];
  pageErrors.length = 0;
  return seen;
}

/** Per-viewport outcome lines, printed together so one run shows every broken size. */
const report = [];
let failedViewports = 0;
try {
  for (const viewport of VIEWPORTS) {
    drainPageErrors();
    await openShell(cdp, url, viewport);
    const layout = await measure(cdp);
    const scrollY = await scrollDownAndRead(cdp);
    const failures = fitFailures(layout, scrollY);
    for (const error of drainPageErrors()) failures.push(`page error: ${error}`);
    const name = `${viewport.width}x${viewport.height} (${viewport.label})`;
    if (failures.length > 0) failedViewports += 1;
    report.push(`${name}: ${failures.length === 0 ? "fits" : "FAILS"}`);
    for (const failure of failures) report.push(`  - ${failure}`);
  }
  for (const failure of await resizeFailures(cdp, url)) {
    failedViewports += 1;
    report.push(`  - ${failure}`);
  }
  for (const failure of await boardFloorFailures(cdp, url)) {
    failedViewports += 1;
    report.push(`  - ${failure}`);
  }
} finally {
  cdp.close();
  child.kill("SIGKILL");
  server.close();
  rmSync(profile, { recursive: true, force: true });
}

console.log(report.join("\n"));
assert.equal(
  failedViewports,
  0,
  `the shell does not fit ${failedViewports} of ${VIEWPORTS.length} viewports (see the report above) with ${browserPath}`,
);

console.log("shell_fit.test.mjs OK");
