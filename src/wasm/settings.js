// settings.js — File → Settings: solvability warning toggle.

/** Sync checkbox from wasm getConfig(). */
export function syncSettingsModal(modal, config) {
  modal.checkbox.checked = config.warn_solvability === true;
}

/** Open the settings dialog with current config. */
export function showSettingsModal(modal, config) {
  syncSettingsModal(modal, config);
  modal.el.hidden = false;
}

/** File → Settings: toggle warn_solvability and persist via host. */
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
    const result = game.exec({ action: "set_warn_solvability", enabled });
    if (!result.ok) {
      modal.checkbox.checked = !enabled;
      return;
    }
    session.config = game.getConfig();
    if (onPersist) await onPersist(session.config);
  });

  modal.dismissEl?.addEventListener("click", () => {
    modal.el.hidden = true;
    onDismiss?.();
  });
}
