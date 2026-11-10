import type { AskUiStrings } from "./types";
import { ASK_UI } from "./strings";

export type AskDom = {
  fab: HTMLButtonElement;
  panel: HTMLElement;
  statusEl: HTMLElement;
  modelEl: HTMLElement;
  modelPicker: HTMLSelectElement;
  transcript: HTMLElement;
  contextEl: HTMLElement;
  activityEl: HTMLElement;
  activityText: HTMLElement;
  form: HTMLFormElement;
  input: HTMLTextAreaElement;
  sendBtn: HTMLButtonElement;
  cancelBtn: HTMLButtonElement;
  closeBtn: HTMLButtonElement;
};

export function mountAskDom(ui: AskUiStrings = ASK_UI): AskDom | null {
  if (!document.getElementById("ask-panel")) {
    const fab = document.createElement("button");
    fab.type = "button";
    fab.id = "ask-fab";
    fab.className = "ask-fab";
    fab.hidden = true;
    fab.setAttribute("aria-controls", "ask-panel");
    fab.setAttribute("aria-expanded", "false");
    fab.setAttribute("aria-label", "Ask about this document");
    fab.textContent = "Ask";

    const aside = document.createElement("aside");
    aside.id = "ask-panel";
    aside.className = "ask-panel";
    aside.hidden = true;
    aside.setAttribute("aria-label", "Ask about this document");
    aside.innerHTML =
      '<div class="ask-header">' +
      '  <div class="ask-header-main">' +
      "    <strong>Ask</strong>" +
      '    <span id="ask-model" class="ask-model" hidden></span>' +
      '    <select id="ask-model-picker" class="ask-model-picker" ' +
      '            aria-label="Model" title="Model" hidden></select>' +
      "  </div>" +
      '  <span id="ask-status" class="ask-status">' +
      (ui.idle || "") +
      "</span>" +
      '  <button type="button" id="ask-close" class="ask-icon-btn" aria-label="Close">\u00d7</button>' +
      "</div>" +
      '<div id="ask-context" class="ask-context" hidden></div>' +
      '<div id="ask-activity" class="ask-activity" hidden>' +
      '  <span class="ask-activity-dot" aria-hidden="true"></span>' +
      '  <span id="ask-activity-text" class="ask-activity-text"></span>' +
      "</div>" +
      '<div id="ask-transcript" class="ask-transcript" aria-live="polite"></div>' +
      '<form id="ask-form" class="ask-form">' +
      '  <textarea id="ask-input" class="ask-input" rows="3" placeholder="Ask about the selection or this page\u2026"></textarea>' +
      '  <div class="ask-actions">' +
      '    <button type="button" id="ask-cancel" class="ask-btn ask-btn-muted" disabled>Cancel</button>' +
      '    <button type="submit" id="ask-send" class="ask-btn" disabled>Send</button>' +
      "  </div>" +
      "</form>";

    document.body.appendChild(fab);
    document.body.appendChild(aside);
  }

  const fab = document.getElementById("ask-fab") as HTMLButtonElement | null;
  const panel = document.getElementById("ask-panel");
  const statusEl = document.getElementById("ask-status");
  const modelEl = document.getElementById("ask-model");
  const modelPicker = document.getElementById("ask-model-picker");
  const transcript = document.getElementById("ask-transcript");
  const contextEl = document.getElementById("ask-context");
  const activityEl = document.getElementById("ask-activity");
  const activityText = document.getElementById("ask-activity-text");
  const form = document.getElementById("ask-form") as HTMLFormElement | null;
  const input = document.getElementById("ask-input") as HTMLTextAreaElement | null;
  const sendBtn = document.getElementById("ask-send") as HTMLButtonElement | null;
  const cancelBtn = document.getElementById("ask-cancel") as HTMLButtonElement | null;
  const closeBtn = document.getElementById("ask-close") as HTMLButtonElement | null;

  if (
    !fab ||
    !panel ||
    !statusEl ||
    !modelEl ||
    !modelPicker ||
    !transcript ||
    !contextEl ||
    !activityEl ||
    !activityText ||
    !form ||
    !input ||
    !sendBtn ||
    !cancelBtn ||
    !closeBtn
  ) {
    return null;
  }

  return {
    fab,
    panel,
    statusEl,
    modelEl,
    modelPicker: modelPicker as HTMLSelectElement,
    transcript,
    contextEl,
    activityEl,
    activityText,
    form,
    input,
    sendBtn,
    cancelBtn,
    closeBtn,
  };
}
