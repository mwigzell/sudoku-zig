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
export type StartupReady = Awaited<ReturnType<typeof import("./shell.js").offerInitialNewGame>>;
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
  | { flow: "autosave_flush" };

/** One core step (wasm `flowStart` / `flowNext` result). */
export type FlowStep =
  | { step: "resolve_default_target" }
  | { step: "check_target" | "write"; name: string }
  | { step: "ask"; title: string; text: string; ok_label: string; cancel_label: string }
  | { step: "show_status" | "show_error"; text: string }
  | { step: "done" }
  | { ok: false; error: string; step?: undefined };

/** Platform result of a `write` step. */
export type WriteResult = { ok: true; name?: string } | { ok: false; cancelled?: boolean; error?: string };

/** Platform work for each step kind; handlers report facts and never decide what happens next. */
export type FlowHandlers = {
  resolveDefaultTarget?: () => string | Promise<string>;
  checkTarget: (name: string) => boolean | Promise<boolean>;
  ask: (step: { title: string; text: string; ok_label: string; cancel_label: string }) => boolean | Promise<boolean>;
  write: (name: string) => WriteResult | Promise<WriteResult>;
  showStatus?: (text: string) => void;
  showError?: (text: string) => void;
};

/** How a flow ended. */
export type FlowOutcome = { kind: "show_status" | "show_error"; text: string } | { kind: "done" };
