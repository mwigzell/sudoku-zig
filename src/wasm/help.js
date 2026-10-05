// help.js — Help menu: About dialog from wasm getAbout metadata.

/** Fill and show the About modal from wasm About JSON. */
export function showAboutModal(modal, info) {
  const summaryTop =
    typeof info.name === "string" &&
    typeof info.version === "string" &&
    typeof info.commit === "string"
      ? `${info.name} ${info.version} (${info.commit})`
      : String(info.summary ?? "");
  const buildLine =
    typeof info.build_date === "string" && info.build_date.length > 0 ? `built ${info.build_date}` : "";
  modal.titleEl.textContent = info.name;
  modal.summaryEl.textContent = buildLine.length > 0 ? `${summaryTop}\n${buildLine}` : summaryTop;
  modal.copyrightEl.textContent = `${info.copyright} ${info.licence}`;
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
