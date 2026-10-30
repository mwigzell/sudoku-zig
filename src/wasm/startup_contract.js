// Web startup contract executor: applies host-resolved startup action and
// orchestrates adapter capabilities without redefining host policy authority.

/** Required boot fields every startup outcome must preserve for later session wiring. */
function withBootFields(boot, payload) {
  return {
    default_save_filename: boot.default_save_filename,
    autosave_trigger_commands: boot.autosave_trigger_commands,
    startup_context_event: boot.startup_context_event,
    write_context_events: boot.write_context_events,
    ...payload,
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
 * Execute host startup contract (`restore`/`new`/`idle`) using adapter-provided
 * capabilities. Contract values come from shared startup seams.
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
    const restoreOutcome = withBootFields(boot, {
      ok: true,
      kind: "restore",
      state: restored.state,
      legend: game.getLegend(),
      config: game.getConfig(),
      msg: restored.msg ?? null,
      startup_prompt_new_game: restored.startup_prompt_new_game === true,
    });
    return restoreOutcome;
  }

  if (boot.startup_action === "idle") {
    return withBootFields(boot, {
      ...boot,
      msg: boot.startup_status ?? null,
    });
  }

  const started = await startNewGame(boot.config ?? {}, { autoContinue: false });
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
