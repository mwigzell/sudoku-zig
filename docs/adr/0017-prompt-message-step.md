# ADR-0017 — One typed prompt for every message the player must answer

Status: accepted
Date: 2026-11-03

## Context

Core had two ways to stop and wait for the player: `show_error` (one message, one OK) and `ask` (a title, a question, an OK and a Cancel label). The terminal facade mirrored them with `showError` and `ask`. Web drew them in two different modals, and Android inherited both. Neither carried what kind of message it was, so nothing could show an error differently from a question, and a question with more than two answers had no shape at all.

## Decision

- **One step, `prompt_message`,** replaces `show_error` and `ask`. It carries a type (`information`, `warning`, `error`), a title, the text, the buttons left to right and, optionally, which button is the cancel button.
- **The answer is `pressed`:** the index of the button the player pressed. Core reads the index; adapters never map it to yes or no.
- **The rightmost button is the default:** focused, chosen by Enter, drawn as the primary button.
- **Dismissing** (Escape, Android Back, a tap outside the dialog) answers the cancel button when core named one. With a single button it answers that button. With no cancel button named, dismissing does nothing.
- **Core resolves default and dismiss.** The wasm boundary sends both indices with the step, so web and Android draw and dismiss without deciding anything.
- **Errors are prompts too.** A flow that fails ends with an error prompt; the flow finishes when the player answers it. Only `show_status` and `done` end a flow.
- **The facade has one method, `promptMessage`,** replacing `showError` and `ask` (ADR-0009 seam).
- **Each platform draws the same thing:** web and Android share one dialog with the type icon (ℹ ⚠ ✖) top left and the title centred beside it; the terminal prints the type symbol and title, the text, and numbered buttons when there is more than one, and a bare Enter picks the default. The terminal has no dismiss.

## Consequences

- Every message core shows has a type, chosen where the message is written.
- A question with three or more answers needs no new step or facade method.
- The old error and confirm modals are gone; the boot-failure message, which the page shows before wasm loads, uses the same dialog.
- On Android, Back closes an open prompt instead of leaving the app; with no prompt open it still leaves.
