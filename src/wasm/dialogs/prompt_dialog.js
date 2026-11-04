// prompt_dialog.js — the one dialog for core's `prompt_message` step on web and Android: type icon,
// title, text and core's buttons; the answer is the index of the button pressed.

/** @typedef {import("../types").PromptStep} PromptStep */
/** @typedef {import("../types").PromptDialog} PromptDialog */
/** @typedef {import("../types").PromptDialogElements} PromptDialogElements */

/** The icon shown top left for each message type. */
export const TYPE_ICONS = Object.freeze({ information: "ℹ", warning: "⚠", error: "✖" });
/** Id prefix of the n-th button, left to right. */
export const BUTTON_ID_PREFIX = "prompt-dialog-button-";
/** Class of the default (rightmost) button. */
export const DEFAULT_BUTTON_CLASS = "prompt-default";

/**
 * Wire the dialog; `onOpenChange` tells the platform when a prompt opens or closes (Android routes Back to it).
 * @param {PromptDialogElements} els
 * @returns {PromptDialog}
 */
export function wirePromptDialog({ el, iconEl, titleEl, textEl, buttonsEl, doc, onOpenChange }) {
  /** @type {{ step: PromptStep, resolve: (index: number) => void } | null} */
  let open = null;

  const answer = (index) => {
    if (!open) return;
    const { resolve } = open;
    open = null;
    el.hidden = true;
    buttonsEl.replaceChildren();
    onOpenChange?.(false);
    resolve(index);
  };

  const dismiss = () => {
    if (open && open.step.dismiss != null) answer(open.step.dismiss);
  };

  el.addEventListener("click", (event) => {
    if (event.target === el) dismiss();
  });
  el.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    event.stopPropagation();
    event.preventDefault();
    dismiss();
  });

  return {
    show(step) {
      return new Promise((resolve) => {
        open = { step, resolve };
        el.dataset.type = step.type;
        iconEl.textContent = TYPE_ICONS[step.type] ?? "";
        titleEl.textContent = step.title;
        textEl.textContent = step.text;
        const buttons = step.buttons.map((label, index) => {
          const button = doc.createElement("button");
          button.type = "button";
          button.id = `${BUTTON_ID_PREFIX}${index}`;
          button.textContent = label;
          if (index === step.default) button.className = DEFAULT_BUTTON_CLASS;
          button.addEventListener("click", () => answer(index));
          return button;
        });
        buttonsEl.replaceChildren(...buttons);
        el.hidden = false;
        onOpenChange?.(true);
        buttons[step.default]?.focus();
      });
    },
    dismiss,
  };
}
