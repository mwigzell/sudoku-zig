export type GameApi = Awaited<ReturnType<typeof import("./artifacts/glue.js").loadArtifact>>;

export type ExecAction =
  | { action: "fill"; row: number; col: number; digit: number }
  | { action: "clear"; row: number; col: number }
  | { action: "undo" }
  | { action: "redo" }
  | { action: "quit" }
  | { action: "solve" }
  | { action: "hint"; row?: number; col?: number }
  | { action: "set_theme"; theme: "light" | "dark" | "system" }
  | { action: "toggle_region" | "toggle_warn_solvability" | "toggle_auto_restore" | "toggle_auto_new" | "toggle_auto_save" }
  | { action: "set_difficulty"; difficulty: "easy" | "medium" | "hard" }
  | { action: "set_log_level"; log_level: "debug" | "info" | "warn" | "err" | "fatal" }
  | { action: "new"; difficulty?: "easy" | "medium" | "hard" }
  | { action: "open" | "import" | "paste" }
  | { action: "save" | "save_as" | "export" | "copy" };

export type WebSession = ReturnType<typeof import("./session.js").createWebSessionFromStartup>;
/** Menubar item elements resolved from the page shell. */
export type MenuBarControls = ReturnType<typeof import("./menu_bar.js").collectMenuBarControls>;
/** Wired menubar: `sync()` re-applies legend/config enablement and labels; `closeAll()` closes open dropdowns. */
export type MenuBar = ReturnType<typeof import("./menu_bar.js").wireMenuBar>;
/** Board cell selection: `getSelection()`, `deselect()`. */
export type BoardSelection = ReturnType<typeof import("./board.js").wireSelection>;
/** File menu items `wireFileMenu` wires; a missing item is skipped. */
export type FileMenuControls = Partial<
  Pick<MenuBarControls, "new" | "open" | "import" | "export" | "save" | "saveAs" | "autoSave">
>;
/** What each File item's wiring needs: the game and session, the views it refreshes, and the file APIs it writes through. */
export type FileMenuWiring = {
  game: GameApi;
  boardEl: HTMLElement;
  selection: BoardSelection;
  statusEl: HTMLElement;
  errorModal: ErrorModal;
  session: WebSession;
  menuBar: MenuBar;
  download: typeof import("./file_menu.js").downloadBytes;
  pick: (session: WebSession, options?: Parameters<typeof import("./file_menu.js").pickBytes>[2]) => ReturnType<typeof import("./file_menu.js").pickBytes>;
  exportText: typeof import("./file_menu.js").persistPuzzleText;
  createElement?: (tag: string) => HTMLElement;
  onViewRefresh?: () => void;
  commandFlow?: FlowHandlers;
};
export type GeneratingModal = ReturnType<typeof import("./generating.js").wireGeneratingModal>;
export type ErrorModal = ReturnType<typeof import("./error_modal.js").wireErrorModal>;
export type GenWorker =
  | {
      workerUrl: string;
      wasmBytes: Uint8Array;
      WorkerCtor?: typeof Worker;
      fetchFn?: typeof fetch;
    }
  | undefined;

/** `flowStart` payload: which core flow to run. */
export type FlowStart =
  | { flow: "autosave_flush" }
  | { flow: "startup"; path?: string; name?: string };

/** Board snapshot as wasm `getState` and `show_game` report it. */
export type GameState = { cells: Array<{ value: number; given: boolean; conflict: boolean }> };

/** Player settings as core writes them to `settings.json` (no renderer choice, no current file). */
export type PlayerSettings = {
  difficulty: "easy" | "medium" | "hard" | "default";
  log_level: "debug" | "info" | "warn" | "err" | "fatal";
  theme: "light" | "dark" | "system";
  show_region: boolean;
  warn_solvability: boolean;
  auto_restore: boolean;
  auto_new: boolean;
  auto_save: boolean;
};

/** The serving host's build facts (`/build-info.json`), separate from player settings. */
export type HostBuildInfo = {
  debug_build: boolean;
};

/** One core step (wasm `flowStart` / `flowNext` result). */
export type FlowStep =
  | { step: "resolve_default_target" }
  | { step: "check_target" | "write" | "pick_new"; name: string }
  | { step: "pick_existing" | "copy_line" }
  | { step: "ask"; title: string; text: string; ok_label: string; cancel_label: string }
  | { step: "read_file"; path: string }
  | { step: "pick_open"; kind: "game" | "puzzle"; path: string | null }
  | { step: "read_clipboard" }
  | {
      step: "show_game";
      text: string | null;
      file: string | null;
      state: GameState;
      legend: Record<string, boolean>;
      config: Record<string, unknown>;
      cell?: { row: number; col: number };
      loaded?: true;
    }
  | { step: "generate"; difficulty: number }
  | { step: "forget_current_file"; path: string; delete: boolean }
  | { step: "persist_settings"; settings: PlayerSettings }
  | { step: "show_status" | "show_error"; text: string }
  | { step: "done" }
  | { ok: false; error: string; step?: undefined };

/** Platform result of a `write` or pick step; `taken` means the file belongs to an earlier install. */
export type WriteResult =
  | { ok: true; name?: string }
  | { ok: false; cancelled?: boolean; taken?: { name: string; dir: string }; error?: string };

/** Platform result of a `read_file` step. */
export type ReadResult = { ok: true; bytes: Uint8Array } | { ok: false; error?: string };

/** Platform result of a `pick_open` step; `handle` / `binding` let later saves write the picked file. */
export type PickResult =
  | { ok: true; bytes: Uint8Array; name: string; handle?: unknown; binding?: unknown }
  | { ok: false; cancelled?: boolean; error?: string };

/** Platform result of a `read_clipboard` step. */
export type ClipboardResult = { ok: true; text: string } | { ok: false; error?: string };

/** Platform result of a `persist_settings` or `copy_line` step. */
export type PersistResult = { ok: true } | { ok: false; error?: string };

/** Platform result of a `generate` step. */
export type GenerateResult = { ok: true; line: string } | { ok: false; cancelled?: boolean; error?: string };

/** Platform work for each step kind; handlers report facts and never decide what happens next.
 * A flow only issues the steps its handlers cover (save flows: targets and writes; startup: reads,
 * generation and questions; settings: `persistSettings`). */
export type FlowHandlers = {
  resolveDefaultTarget?: () => string | Promise<string>;
  checkTarget?: (name: string) => boolean | Promise<boolean>;
  ask?: (step: { title: string; text: string; ok_label: string; cancel_label: string }) => boolean | Promise<boolean>;
  write?: (name: string) => WriteResult | Promise<WriteResult>;
  pickExisting?: () => WriteResult | Promise<WriteResult>;
  pickNew?: (name: string) => WriteResult | Promise<WriteResult>;
  copyLine?: () => PersistResult | Promise<PersistResult>;
  readFile?: (path: string) => ReadResult | Promise<ReadResult>;
  pickOpen?: (step: { kind: "game" | "puzzle"; path: string | null }) => PickResult | Promise<PickResult>;
  readClipboard?: () => ClipboardResult | Promise<ClipboardResult>;
  showGame?: (step: { text: string | null; file: string | null }) => void | Promise<void>;
  generate?: (difficulty: number) => GenerateResult | Promise<GenerateResult>;
  forgetCurrentFile?: (forget: { path: string; delete: boolean }) => void | Promise<void>;
  persistSettings?: (settings: PlayerSettings) => PersistResult | Promise<PersistResult>;
  showStatus?: (text: string) => void;
  showError?: (text: string) => void | Promise<void>;
};

/** How a flow ended. */
export type FlowOutcome = { kind: "show_status" | "show_error"; text: string } | { kind: "done" };

/** What an Android bridge save or open reports; `default_taken` means the default file belongs to an earlier install. */
export type AndroidBridgeResult =
  | { ok: true; name?: string; base64?: string }
  | { ok: false; cancelled?: boolean; reason?: "cancelled" | "default_taken"; name?: string; dir?: string; error?: string };

/** Android WebView file bridge (`android_bridge.js` over the Java `__SudokuAndroidBridge`); absent elsewhere. */
export type AndroidFileBridge = {
  /** Save via the create-document picker when `saveAs`, else to the bound file. */
  saveSudokuFile: (base64: string, suggestedName: string, saveAs: boolean) => AndroidBridgeResult;
  /** Pick an existing file and write to it. */
  saveSudokuFileToExisting: (base64: string) => AndroidBridgeResult;
  /** Write the bound file, or the default visible file when none is bound. */
  saveCurrentSudokuFile: (base64: string, suggestedName: string) => AndroidBridgeResult;
  /** Bound file name, or "" when none. */
  currentSudokuFileName: () => string;
  openSudokuFile: () => AndroidBridgeResult;
  setSystemBars: (themeName: string) => void;
  notifyWebBootReady: () => void;
};

declare global {
  interface Window {
    AndroidFileBridge?: AndroidFileBridge;
  }
}
