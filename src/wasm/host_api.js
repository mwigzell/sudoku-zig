// host_api.js — HTTP calls to the serving host: startup config, build facts, settings and the current file.

/** @typedef {import("./types").PlayerSettings} PlayerSettings */
/** @typedef {import("./types").PersistResult} PersistResult */
/** @typedef {import("./types").HostBuildInfo} HostBuildInfo */

const HOST_CONFIG_PATH = "./host-config.json";
const HOST_SETTINGS_PATH = "./settings.json";
const CURRENT_FILE_PATH = "./current-file";
const BUILD_INFO_PATH = "./build-info.json";
const CURRENT_FILE_EXISTS_PATH = "./current-file-exists";
const FILENAME_HEADER = "X-Sudoku-Filename";
const RESTORE_COPY_HEADER = "X-Sudoku-Restore-Copy";
const DELETE_FILE_HEADER = "X-Sudoku-Delete-File";

/** The host's startup config: player settings, default save name and the current file to restore. */
export async function fetchHostStartupConfig(fetchFn = globalThis.fetch) {
  const res = await fetchFn(HOST_CONFIG_PATH);
  if (!res.ok) throw new Error(`host-config fetch failed: ${res.status}`);
  return res.json();
}

/**
 * The serving host's build facts, kept apart from player config.
 * @returns {Promise<HostBuildInfo>}
 */
export async function fetchHostBuildInfo(fetchFn = globalThis.fetch) {
  const res = await fetchFn(BUILD_INFO_PATH);
  if (!res.ok) throw new Error(`build-info fetch failed: ${res.status}`);
  const body = await res.json();
  return { debug_build: body.debug_build === true };
}

/** Read the host's current file for a startup `restore` step. */
export async function fetchStartupSaveBytes(path, fetchFn = globalThis.fetch) {
  const res = await fetchFn(path);
  if (!res.ok) return { ok: false, error: `fetch failed: ${res.status}` };
  return { ok: true, bytes: new Uint8Array(await res.arrayBuffer()) };
}

/** Stop the host restoring its current file at startup; `deleteFile` removes the file too. */
export async function forgetHostCurrentFile(deleteFile, fetchFn = globalThis.fetch) {
  const headers = {};
  if (deleteFile === true) headers[DELETE_FILE_HEADER] = "true";
  const res = await fetchFn(CURRENT_FILE_PATH, { method: "DELETE", headers });
  if (!res.ok) throw new Error(`current-file forget failed: ${res.status}`);
}

/**
 * Hand core's player settings to the host, which stores them in `settings.json`.
 * @param {PlayerSettings} settings
 * @returns {Promise<PersistResult>}
 */
export async function postHostSettings(settings, fetchFn) {
  const res = await fetchFn(HOST_SETTINGS_PATH, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(settings),
  });
  if (!res.ok) return { ok: false, error: `HTTP ${res.status}` };
  return { ok: true };
}

/** Write SUD0 bytes as the host copy (`/current-file`); `restoreCopy` keeps it out of the visible folder. */
export async function persistCurrentFileBytes(
  bytes,
  fetchFn = globalThis.fetch,
  saveName = null,
  { restoreCopy = false } = {},
) {
  const headers = { "Content-Type": "application/octet-stream" };
  if (typeof saveName === "string" && saveName.length > 0) headers[FILENAME_HEADER] = saveName;
  if (restoreCopy === true) headers[RESTORE_COPY_HEADER] = "true";
  const res = await fetchFn(CURRENT_FILE_PATH, {
    method: "POST",
    headers,
    body: bytes,
  });
  if (!res.ok) return { ok: false, error: `current-file persist failed: ${res.status}` };
  return { ok: true };
}

/** Whether the host's write of `saveName` would land on an existing file the user can see. */
export async function hostCurrentFileExists(saveName, fetchFn = globalThis.fetch) {
  const headers = {};
  if (typeof saveName === "string" && saveName.length > 0) headers[FILENAME_HEADER] = saveName;
  const res = await fetchFn(CURRENT_FILE_EXISTS_PATH, { headers });
  if (!res.ok) throw new Error(`current-file check failed: ${res.status}`);
  const payload = await res.json();
  return payload?.exists === true;
}
