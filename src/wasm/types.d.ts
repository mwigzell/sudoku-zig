export type GameApi = Awaited<ReturnType<typeof import("./artifacts/glue.js").loadArtifact>>;

export type ExecAction =
  | { action: "fill"; row: number; col: number; digit: number }
  | { action: "clear"; row: number; col: number }
  | { action: "undo" }
  | { action: "redo" }
  | { action: "quit" }
  | { action: "solve" }
  | { action: "hint"; row?: number; col?: number }
  | { action: "set_theme"; theme: "light" | "dark" }
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
