export type GameApi = Awaited<ReturnType<typeof import("./artifacts/glue.js").loadArtifact>>;

/** Core's log severities (`logger.Severity`), in rank order. */
export type LogLevel = "debug" | "info" | "warn" | "err" | "fatal";

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
  | { action: "set_log_level"; log_level: LogLevel }
  | { action: "new"; difficulty?: "easy" | "medium" | "hard" }
  | { action: "open" | "import" | "paste" }
  | { action: "save" | "save_as" | "export" | "copy" };

export type WebSession = ReturnType<typeof import("./flows/session.js").createWebSessionFromStartup>;
/** Menubar item elements resolved from the page shell. */
export type MenuBarControls = ReturnType<typeof import("./menus/menu_bar.js").collectMenuBarControls>;
/** Wired menubar: `sync()` re-applies legend/config enablement and labels; `closeAll()` closes open dropdowns. */
export type MenuBar = ReturnType<typeof import("./menus/menu_bar.js").wireMenuBar>;
/** Board cell selection: `getSelection()`, `deselect()`. */
export type BoardSelection = ReturnType<typeof import("./board.js").wireSelection>;
/** File menu items `wireFileMenu` wires; a missing item is skipped. */
export type FileMenuControls = Partial<
  Pick<MenuBarControls, "new" | "open" | "import" | "export" | "save" | "saveAs" | "autoSave">
>;
/** What each File item's wiring needs: the game and session, the views it refreshes, and the platform's step handlers. */
export type FileMenuWiring = {
  game: GameApi;
  boardEl: HTMLElement;
  selection: BoardSelection;
  statusEl: HTMLElement;
  session: WebSession;
  menuBar: MenuBar;
  createElement?: (tag: string) => HTMLElement;
  onViewRefresh?: () => void;
  steps: FlowHandlers;
};
/** What a platform's step handlers are built with; unset hooks take the browser's. */
export type StepsOptions = {
  win?: Window & typeof globalThis;
  doc?: Document;
  fetchFn?: typeof fetch;
  statusEl?: HTMLElement | null;
  promptDialog?: PromptDialog | null;
  generatingModal?: GeneratingModal;
  genWorker?: GenWorker;
  clipboard?: Pick<Clipboard, "readText" | "writeText">;
  download?: (bytes: Uint8Array, filename: string) => unknown;
  pick?: (session: WebSession, options?: Parameters<typeof import("./files.js").pickBytes>[2]) => Promise<PickResult>;
  exportText?: typeof import("./files.js").persistPuzzleText;
};
/** `StepsOptions` with every hook resolved, as the handlers use it. */
export type StepContext = Required<Omit<StepsOptions, "generatingModal" | "genWorker">> & {
  game: GameApi;
  session: WebSession;
  generatingModal?: GeneratingModal;
  genWorker?: GenWorker;
};
export type GeneratingModal = ReturnType<typeof import("./dialogs/generating.js").wireGeneratingModal>;
/** Core's `prompt_message` step: `default` is the rightmost button; `dismiss` is what dismissing answers, or null when it does nothing. */
export type PromptStep = {
  step: "prompt_message";
  type: "information" | "warning" | "error";
  title: string;
  text: string;
  buttons: string[];
  default: number;
  dismiss: number | null;
};
/** The shared prompt dialog; `show` resolves with the index of the button pressed. */
export type PromptDialog = {
  show: (step: PromptStep) => Promise<number>;
  dismiss: () => void;
};
export type PromptDialogElements = {
  el: HTMLElement;
  iconEl: HTMLElement;
  titleEl: HTMLElement;
  textEl: HTMLElement;
  buttonsEl: HTMLElement;
  doc: Document;
  onOpenChange?: (open: boolean) => void;
};
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

/** Generating dialog text from core (`getGenText`): title, overall state and the carving method's label. */
export type GenText = { title: string; busy: string; done: string; cancelling: string; fast_strip: string; dig_hole: string };

/** Board snapshot as wasm `getState` and `show_game` report it. */
export type GameState = { cells: Array<{ value: number; given: boolean; conflict: boolean }> };

/** Player settings as core writes them to `settings.json` (no renderer choice, no current file). */
export type PlayerSettings = {
  difficulty: "easy" | "medium" | "hard" | "default";
  log_level: LogLevel;
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

/** A game write step's target: the file, and whether a file already there may be replaced. */
export type GameWrite = { name: string; replace: boolean };

/** One core step (wasm `flowStart` / `flowNext` result). */
export type FlowStep =
  | { step: "resolve_default_target" | "reclaim_file" | "copy_puzzle" | "paste_puzzle" }
  | ({ step: "save" | "save_as" | "autosave" } & GameWrite)
  | { step: "flush" | "export_puzzle"; name: string }
  | PromptStep
  | { step: "restore"; path: string }
  | { step: "open" | "import_puzzle"; path: string | null }
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
  | { step: "generate_game"; difficulty: number }
  | { step: "forget_current_file"; path: string; delete: boolean }
  | { step: "persist_settings"; settings: PlayerSettings }
  | { step: "show_status"; text: string }
  | { step: "done" }
  | { ok: false; error: string; step?: undefined };

/** Platform result of a write step; `exists` means a fixed file is there and was left alone,
 * `taken` that this install may not write the file. */
export type WriteResult =
  | { ok: true; name?: string }
  | { ok: false; exists?: boolean; cancelled?: boolean; taken?: { name: string }; error?: string };

/** Platform result of a reading step (`restore`, `open`, `import_puzzle`, `paste_puzzle`); a browser
 * pick also carries the file's handle so a saved game can be bound. */
export type PickResult =
  | { ok: true; bytes: Uint8Array; name?: string; handle?: FileSystemFileHandle }
  | { ok: false; cancelled?: boolean; error?: string };

/** Platform result of a `persist_settings` or `copy_puzzle` step. */
export type PersistResult = { ok: true } | { ok: false; error?: string };

/** Platform result of a `generate_game` step. */
export type GenerateResult = { ok: true; line: string } | { ok: false; cancelled?: boolean; error?: string };

/** The platform's handler for each step, used by every flow; handlers report facts and never decide what happens next. */
export type FlowHandlers = {
  resolveDefaultTarget: () => string | Promise<string>;
  promptMessage: (step: PromptStep) => number | Promise<number>;
  save: (target: GameWrite) => WriteResult | Promise<WriteResult>;
  saveAs: (target: GameWrite) => WriteResult | Promise<WriteResult>;
  autosave: (target: GameWrite) => WriteResult | Promise<WriteResult>;
  flush: (name: string) => WriteResult | Promise<WriteResult>;
  exportPuzzle: (name: string) => WriteResult | Promise<WriteResult>;
  reclaimFile: () => WriteResult | Promise<WriteResult>;
  copyPuzzle: () => PersistResult | Promise<PersistResult>;
  pastePuzzle: () => PickResult | Promise<PickResult>;
  restore: (path: string) => PickResult | Promise<PickResult>;
  open: (path: string | null) => PickResult | Promise<PickResult>;
  importPuzzle: (path: string | null) => PickResult | Promise<PickResult>;
  showGame: (step: Extract<FlowStep, { step: "show_game" }>) => void | Promise<void>;
  generateGame: (difficulty: number) => GenerateResult | Promise<GenerateResult>;
  forgetCurrentFile: (forget: { path: string; delete: boolean }) => void | Promise<void>;
  persistSettings: (settings: PlayerSettings) => PersistResult | Promise<PersistResult>;
  showStatus: (text: string) => void;
};

/** How a flow ended. */
export type FlowOutcome = { kind: "show_status"; text: string } | { kind: "done" };

/** What an Android bridge save or open reports; `taken` means this install may not write the file (an earlier
 * install created it, or its permission is gone). */
export type AndroidBridgeResult =
  | { ok: true; name?: string; base64?: string }
  | { ok: false; cancelled?: boolean; reason?: "cancelled" | "taken"; name?: string; error?: string };

/** Android WebView file bridge (`android_bridge.js` over the Java `__SudokuAndroidBridge`); absent elsewhere. */
export type AndroidFileBridge = {
  /** Write the bound file, else a new file the player names. */
  save: (base64: string, suggestedName: string) => AndroidBridgeResult;
  /** Write a new file the player names. */
  saveAs: (base64: string, suggestedName: string) => AndroidBridgeResult;
  /** Write the bound file, or the default visible file when none is bound. */
  autosave: (base64: string, suggestedName: string) => AndroidBridgeResult;
  /** Pick an existing file and write to it. */
  reclaimFile: (base64: string) => AndroidBridgeResult;
  /** Pick a saved game and read it; the picked file becomes the bound file. */
  open: () => AndroidBridgeResult;
  /** Pick a puzzle text file and read it; the bound file is unchanged. */
  importPuzzle: () => AndroidBridgeResult;
  /** Write the puzzle to a new text file the player names; the bound file is unchanged. */
  exportPuzzle: (base64: string, suggestedName: string) => AndroidBridgeResult;
  /** Bound file name, or "" when none. */
  currentSudokuFileName: () => string;
  setSystemBars: (themeName: string) => void;
  notifyWebBootReady: () => void;
};

declare global {
  interface Window {
    AndroidFileBridge?: AndroidFileBridge;
  }
}
