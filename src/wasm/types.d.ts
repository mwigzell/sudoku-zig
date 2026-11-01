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
  | { action: "set_region"; enabled: boolean }
  | { action: "set_warn_solvability"; enabled: boolean }
  | { action: "set_auto_restore"; enabled: boolean }
  | { action: "set_auto_new"; enabled: boolean }
  | { action: "set_auto_save"; enabled: boolean }
  | { action: "set_difficulty"; difficulty: "easy" | "medium" | "hard" }
  | { action: "set_log_level"; log_level: "debug" | "info" | "warn" | "err" | "fatal" };

export type WebSession = ReturnType<typeof import("./shell.js").createWebSessionFromStartup>;
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
export type GeneratingModal = ReturnType<typeof import("./generating.js").wireGeneratingModal>;
export type ErrorModal = ReturnType<typeof import("./shell.js").wireErrorModal>;
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
  | { flow: "save" | "save_as"; name: string }
  | { flow: "autosave"; command: string }
  | { flow: "autosave_flush" }
  | { flow: "startup"; path?: string; name?: string }
  | { flow: "settings"; command: string };

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

/** One core step (wasm `flowStart` / `flowNext` result). */
export type FlowStep =
  | { step: "resolve_default_target" }
  | { step: "check_target" | "write"; name: string }
  | { step: "ask"; title: string; text: string; ok_label: string; cancel_label: string }
  | { step: "read_file"; path: string }
  | { step: "show_game"; text: string | null; file: string | null }
  | { step: "generate"; difficulty: number }
  | { step: "forget_current_file"; path: string; delete: boolean }
  | { step: "persist_settings"; settings: PlayerSettings }
  | { step: "show_status" | "show_error"; text: string }
  | { step: "done" }
  | { ok: false; error: string; step?: undefined };

/** Platform result of a `write` step. */
export type WriteResult = { ok: true; name?: string } | { ok: false; cancelled?: boolean; error?: string };

/** Platform result of a `read_file` step. */
export type ReadResult = { ok: true; bytes: Uint8Array } | { ok: false; error?: string };

/** Platform result of a `persist_settings` step. */
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
  readFile?: (path: string) => ReadResult | Promise<ReadResult>;
  showGame?: (step: { text: string | null; file: string | null }) => void | Promise<void>;
  generate?: (difficulty: number) => GenerateResult | Promise<GenerateResult>;
  forgetCurrentFile?: (forget: { path: string; delete: boolean }) => void | Promise<void>;
  persistSettings?: (settings: PlayerSettings) => PersistResult | Promise<PersistResult>;
  showStatus?: (text: string) => void;
  showError?: (text: string) => void | Promise<void>;
};

/** How a flow ended. */
export type FlowOutcome = { kind: "show_status" | "show_error"; text: string } | { kind: "done" };
