// Shared web startup orchestrator: applies host startup action contract and
// returns a normalized startup outcome for thin adapters to render.

/**
 * Normalize current game snapshot for startup fallback responses.
 */
function emptyOutcome(game, boot, msg, extras = {}) {
  return {
    ok: true,
    kind: "empty",
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    msg,
    default_save_filename: boot.default_save_filename,
    startup_context_event: boot.startup_context_event,
    write_context_events: boot.write_context_events,
    ...extras,
  };
}

/**
 * Apply host startup contract (`restore`/`new`/`idle`) using adapter-provided
 * operations. Keeps decision semantics centralized outside page wiring.
 */
export async function applyWebStartupAction(
  game,
  boot,
  {
    fetchStartupSaveBytes,
    openFromSaveBytes,
    startNewGame,
  },
) {
  if (!boot.ok) return boot;
  if (boot.kind !== "empty") return boot;

  if (boot.startup_action === "restore") {
    const restorePath = boot.startup_save_path;
    if (!restorePath) {
      return emptyOutcome(game, boot, "startup restore path missing; startup remains manual");
    }
    const fetched = await fetchStartupSaveBytes(restorePath);
    if (!fetched.ok) {
      return emptyOutcome(game, boot, `${fetched.error}; startup remains manual`);
    }
    const restored = openFromSaveBytes(fetched.bytes, restorePath);
    if (!restored.ok) {
      return emptyOutcome(game, boot, `${restored.error ?? "startup restore failed"}; startup remains manual`);
    }
    return {
      ok: true,
      kind: "restore",
      state: restored.state,
      legend: game.getLegend(),
      config: game.getConfig(),
      msg: restored.msg ?? "restored game",
      default_save_filename: boot.default_save_filename,
      startup_context_event: boot.startup_context_event,
      write_context_events: boot.write_context_events,
    };
  }

  if (boot.startup_action === "idle") {
    return {
      ...boot,
      msg: boot.startup_status ?? null,
    };
  }

  const started = await startNewGame(boot.config ?? {});
  if (!started.ok && !started.cancelled) {
    return { ok: false, error: started.error ?? "New game failed", kind: "empty" };
  }
  if (started.cancelled) {
    return emptyOutcome(game, boot, null, { cancelled: true });
  }
  return {
    ok: true,
    kind: "new",
    state: started.state,
    legend: started.legend,
    config: started.config,
    msg: started.msg,
    default_save_filename: boot.default_save_filename,
    startup_context_event: boot.startup_context_event,
    write_context_events: boot.write_context_events,
  };
}
