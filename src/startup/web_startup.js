// Shared web startup orchestrator: applies host startup action contract and
// returns a normalized startup outcome for thin adapters to render.

/** Required boot fields every startup outcome must preserve for later session wiring. */
function withBootFields(boot, payload) {
  return {
    ...payload,
    default_save_filename: boot.default_save_filename,
    autosave_trigger_commands: boot.autosave_trigger_commands,
    startup_context_event: boot.startup_context_event,
    write_context_events: boot.write_context_events,
  };
}

/** Normalize current game snapshot for startup fallback responses. */
function emptyOutcome(game, boot, msg, extras = {}) {
  return withBootFields(boot, {
    ok: true,
    kind: "empty",
    state: game.getState(),
    legend: game.getLegend(),
    config: game.getConfig(),
    msg,
    ...extras,
  });
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
  // Non-empty outcomes are already resolved upstream (e.g., tests injecting
  // precomputed startup responses); pass through unchanged.
  if (!boot.ok) return boot;
  if (boot.kind !== "empty") return boot;

  if (boot.startup_action === "restore") {
    // Restore flow: fetch bytes from host-selected startup path, then hydrate
    // engine through the same open codec used by File -> Open.
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
    return withBootFields(boot, {
      ok: true,
      kind: "restore",
      state: restored.state,
      legend: game.getLegend(),
      config: game.getConfig(),
      msg: restored.msg ?? "restored game",
    });
  }

  if (boot.startup_action === "idle") {
    // Idle flow: keep existing board snapshot from bootstrap and surface host
    // startup status message (if any).
    return withBootFields(boot, {
      ...boot,
      msg: boot.startup_status ?? null,
    });
  }

  // New flow: host requested a startup new-game action. Adapter provides the
  // generation runner, while this function owns startup decision semantics.
  const started = await startNewGame(boot.config ?? {});
  if (!started.ok && !started.cancelled) {
    return { ok: false, error: started.error ?? "New game failed", kind: "empty" };
  }
  if (started.cancelled) {
    return emptyOutcome(game, boot, null, { cancelled: true });
  }
  return withBootFields(boot, {
    ok: true,
    kind: "new",
    state: started.state,
    legend: started.legend,
    config: started.config,
    msg: started.msg,
  });
}
