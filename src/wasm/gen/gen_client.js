// gen_client.js — start puzzle gen in a worker; testable via injected Worker mock.

/** Module workers need a secure context (https or localhost). */
export function canUseGenWorker() {
  return typeof Worker !== "undefined" && globalThis.isSecureContext === true;
}

/** Warm the worker module URL in HTTP cache before `new Worker()`. */
export async function prefetchWorkerScript(workerUrl, { fetchFn } = {}) {
  const fetchImpl = fetchFn ?? globalThis.fetch;
  if (!fetchImpl) return { ok: true };
  try {
    const res = await fetchImpl(workerUrl);
    if (!res.ok) return { ok: false, error: "worker failed" };
    await res.arrayBuffer();
    return { ok: true };
  } catch {
    return { ok: false, error: "worker failed" };
  }
}

const CANCEL_TERMINATE_MS = 500;

/** Start one worker generate; `{ promise, cancel }` for abort (cooperative + terminate). */
export function startGenInWorker({
  workerUrl,
  wasmBytes,
  difficulty,
  logLevel,
  onProgress,
  WorkerCtor,
  fetchFn,
}) {
  const WorkerImpl = WorkerCtor ?? globalThis.Worker;
  if (!WorkerImpl) {
    return {
      promise: Promise.resolve({ ok: false, error: "workers unavailable" }),
      cancel() {},
    };
  }

  let settled = false;
  let cancelling = false;
  let worker = null;
  let cancelTimer = null;
  let cancelImpl = () => {
    if (settled) return;
    cancelling = true;
  };

  const finish = (result) => {
    if (settled) return;
    settled = true;
    if (cancelTimer != null) clearTimeout(cancelTimer);
    resolveOuter?.(result);
  };

  let resolveOuter = null;
  const promise = (async () => {
    if (!WorkerCtor) {
      const warm = await prefetchWorkerScript(workerUrl, { fetchFn });
      if (!warm.ok) return warm;
    }
    if (cancelling) return { ok: false, cancelled: true };

    return await new Promise((resolve) => {
      resolveOuter = resolve;

      worker = new WorkerImpl(workerUrl, { type: "module" });

      cancelImpl = () => {
        if (settled) return;
        cancelling = true;
        worker?.postMessage({ type: "cancel" });
        cancelTimer = setTimeout(() => {
          if (!settled) {
            worker?.terminate();
            finish({ ok: false, cancelled: true });
          }
        }, CANCEL_TERMINATE_MS);
      };
      if (cancelling) {
        cancelImpl();
        return;
      }

      worker.onmessage = (event) => {
        const msg = event.data;
        if (msg?.type === "progress") {
          if (cancelling) return;
          onProgress?.(msg.phase, msg.a, msg.b);
          return;
        }
        if (msg?.type === "cancelled") {
          worker.terminate();
          finish({ ok: false, cancelled: true });
          return;
        }
        if (msg?.type === "done") {
          if (cancelling) return;
          worker.terminate();
          finish({ ok: true, line: msg.line });
          return;
        }
        if (msg?.type === "error") {
          if (cancelling) return;
          worker.terminate();
          finish({ ok: false, error: msg.error ?? "generate failed" });
        }
      };

      worker.onerror = (ev) => {
        worker.terminate();
        if (cancelling) finish({ ok: false, cancelled: true });
        else finish({ ok: false, error: ev?.message || "worker failed" });
      };

      worker.postMessage({
        type: "run",
        wasmBytes,
        difficulty,
        logLevel,
      });
    });
  })();

  return { promise, cancel: () => cancelImpl() };
}
