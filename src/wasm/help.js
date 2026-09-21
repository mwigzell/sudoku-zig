// help.js — Help menu: About dialog from wasm getAbout metadata.

/** Fill and show the About modal from wasm About JSON. */
export function showAboutModal(modal, info) {
  modal.titleEl.textContent = info.name;
  modal.logoEl.textContent = info.logo.join("\n");
  modal.summaryEl.textContent = info.summary;
  modal.copyrightEl.textContent = info.copyright;
  modal.licenceEl.textContent = info.licence;
  modal.el.hidden = false;
}

/** Wire Help → About to fetch metadata and open the modal. */
export function wireHelpAbout(aboutBtn, game, modal) {
  if (!aboutBtn) return;
  aboutBtn.addEventListener("click", () => {
    const info = game.getAbout();
    showAboutModal(modal, info);
  });
}

/** Bind dismiss control on the About modal. */
export function wireAboutModal(el, dismissEl) {
  const close = () => {
    el.hidden = true;
  };
  dismissEl.addEventListener("click", close);
  return { el, close };
}
