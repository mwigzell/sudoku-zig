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
  | { flow: "startup"; path?: string; name?: string };

/** One core step (wasm `flowStart` / `flowNext` result). */
export type FlowStep =
  | { step: "resolve_default_target" }
  | { step: "check_target" | "write"; name: string }
  | { step: "ask"; title: string; text: string; ok_label: string; cancel_label: string }
  | { step: "read_file"; path: string }
  | { step: "show_game"; text: string | null; file: string | null }
  | { step: "generate"; difficulty: number }
  | { step: "forget_current_file"; path: string; delete: boolean }
  | { step: "show_status" | "show_error"; text: string }
  | { step: "done" }
  | { ok: false; error: string; step?: undefined };

/** Platform result of a `write` step. */
export type WriteResult = { ok: true; name?: string } | { ok: false; cancelled?: boolean; error?: string };

/** Platform result of a `read_file` step. */
export type ReadResult = { ok: true; bytes: Uint8Array } | { ok: false; error?: string };

/** Platform result of a `generate` step. */
export type GenerateResult = { ok: true; line: string } | { ok: false; cancelled?: boolean; error?: string };

/** Platform work for each step kind; handlers report facts and never decide what happens next.
 * A flow only issues the steps its handlers cover (save flows: targets and writes; startup: the rest). */
export type FlowHandlers = {
  resolveDefaultTarget?: () => string | Promise<string>;
  checkTarget?: (name: string) => boolean | Promise<boolean>;
  ask: (step: { title: string; text: string; ok_label: string; cancel_label: string }) => boolean | Promise<boolean>;
  write?: (name: string) => WriteResult | Promise<WriteResult>;
  readFile?: (path: string) => ReadResult | Promise<ReadResult>;
  showGame?: (step: { text: string | null; file: string | null }) => void | Promise<void>;
  generate?: (difficulty: number) => GenerateResult | Promise<GenerateResult>;
  forgetCurrentFile?: (forget: { path: string; delete: boolean }) => void | Promise<void>;
  showStatus?: (text: string) => void;
  showError?: (text: string) => void | Promise<void>;
};

/** How a flow ended. */
export type FlowOutcome = { kind: "show_status" | "show_error"; text: string } | { kind: "done" };
