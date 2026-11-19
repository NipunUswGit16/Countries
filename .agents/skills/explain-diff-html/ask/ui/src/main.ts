import "./ask.css";
import { bootAskChat } from "./chat";
import { createContextTracker } from "./context";
import { mountAskDom } from "./mount";
import { ASK_UI } from "./strings";
import type { PageMeta } from "./types";

function boot(): void {
  if (window.__explainDiffAsk) return;
  window.__explainDiffAsk = true;

  const dom = mountAskDom(ASK_UI);
  if (!dom) return;

  let pageMeta: PageMeta = {};
  const metaEl = document.getElementById("explain-diff-meta");
  try {
    pageMeta = metaEl ? (JSON.parse(metaEl.textContent || "{}") as PageMeta) : {};
  } catch {
    pageMeta = {};
  }

  const ctx = createContextTracker(dom.contextEl, ASK_UI);
  bootAskChat(dom, pageMeta, ctx);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
