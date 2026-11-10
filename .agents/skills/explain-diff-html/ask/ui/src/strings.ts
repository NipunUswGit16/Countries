import type { AskUiStrings } from "./types";

export const DEFAULT_ASK_PORT = 7432;

export const ASK_UI: AskUiStrings = {
  idle: "Start explain-diff serve to chat with this page.",
  ready: "Connected. Selection + visible section are sent with your question.",
  noKey: "Cursor harness needs CURSOR_API_KEY. Local Ollama models still work.",
  localOnly: "Connected via Ollama. Set CURSOR_API_KEY for the Cursor agent.",
  noBackend: "No chat backend: set CURSOR_API_KEY or start Ollama.",
  selection: "Selection",
  section: "Section",
};

export function clip(s: string, n: number): string {
  const text = String(s || "");
  return text.length > n ? text.slice(0, n) + "\u2026" : text;
}

export function escapeHtml(s: string): string {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
