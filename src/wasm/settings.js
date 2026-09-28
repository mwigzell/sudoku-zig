// settings.js — File → Settings: warn, default difficulty, log level.

import { difficultyName, logLevelName } from "./shell.js";

/** Sync controls from wasm getConfig(). */
export function syncSettingsModal(modal, config) {
  if (modal.checkbox) modal.checkbox.checked = config.warn_solvability === true;
  if (modal.difficultySelect) modal.difficultySelect.value = difficultyName(config);
  if (modal.logLevelSelect) modal.logLevelSelect.value = logLevelName(config);
}

/** Open the settings dialog with current config. */
export function showSettingsModal(modal, config) {
  syncSettingsModal(modal, config);
  modal.el.hidden = false;
}

async function applySettingChange(game, session, modal, onPersist, execFn) {
  const result = execFn();
  if (!result.ok) {
    syncSettingsModal(modal, session.config ?? game.getConfig());
    return;
  }
  session.config = game.getConfig();
  if (onPersist) await onPersist(session.config);
}

/** File → Settings: prefs and persist via host. */
export function wireSettingsMenu(
  settingsBtn,
  game,
  session,
  modal,
  { onPersist, onDismiss, closeMenus } = {},
) {
  if (!settingsBtn || !modal?.el) return;
  settingsBtn.addEventListener("click", () => {
    closeMenus?.();
    showSettingsModal(modal, session.config ?? game.getConfig());
  });

  modal.checkbox?.addEventListener("change", async () => {
    const enabled = modal.checkbox.checked;
    await applySettingChange(game, session, modal, onPersist, () =>
      game.exec({ action: "set_warn_solvability", enabled }),
    );
  });

  modal.difficultySelect?.addEventListener("change", async () => {
    const difficulty = modal.difficultySelect.value;
    await applySettingChange(game, session, modal, onPersist, () =>
      game.exec({ action: "set_difficulty", difficulty }),
    );
  });

  modal.logLevelSelect?.addEventListener("change", async () => {
    const log_level = modal.logLevelSelect.value;
    await applySettingChange(game, session, modal, onPersist, () =>
      game.exec({ action: "set_log_level", log_level }),
    );
  });

  modal.dismissEl?.addEventListener("click", () => {
    modal.el.hidden = true;
    onDismiss?.();
  });
}
