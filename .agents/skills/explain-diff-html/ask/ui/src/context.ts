import type { AskUiStrings, VisibleSection } from "./types";
import { ASK_UI, clip } from "./strings";

export type ContextTracker = {
  lastSelection: string;
  visibleSection: VisibleSection;
  readMetaFiles: () => string[];
  readDocumentText: () => string;
};

export function createContextTracker(
  contextEl: HTMLElement,
  ui: AskUiStrings = ASK_UI,
): ContextTracker {
  const tracker: ContextTracker = {
    lastSelection: "",
    visibleSection: { id: "", title: "", text: "" },
    readMetaFiles,
    readDocumentText,
  };

  function updateContextChip(): void {
    const bits: string[] = [];
    if (tracker.lastSelection) {
      bits.push(ui.selection + ": " + clip(tracker.lastSelection, 80));
    }
    if (tracker.visibleSection.id || tracker.visibleSection.title) {
      bits.push(
        ui.section +
          ": " +
          (tracker.visibleSection.title || tracker.visibleSection.id),
      );
    }
    if (!bits.length) {
      contextEl.hidden = true;
      contextEl.textContent = "";
      return;
    }
    contextEl.hidden = false;
    contextEl.textContent = bits.join(" · ");
  }

  function stashSelection(): void {
    const sel = window.getSelection?.();
    if (!sel || sel.isCollapsed) return;
    const text = String(sel.toString() || "").trim();
    if (!text) return;
    tracker.lastSelection = text;
    let node: Node | null = sel.anchorNode;
    let el: Element | null =
      node && node.nodeType === 3
        ? (node as Text).parentElement
        : (node as Element | null);
    while (el && el !== document.body) {
      if (el.tagName === "SECTION" && el.id) {
        const h = el.querySelector("h2, h3");
        tracker.visibleSection = {
          id: el.id,
          title: h ? String(h.textContent || "").trim() : el.id,
          text: clip((el as HTMLElement).innerText || "", 4000),
        };
        break;
      }
      el = el.parentElement;
    }
    updateContextChip();
  }

  document.addEventListener("mouseup", stashSelection);
  document.addEventListener("keyup", (e) => {
    if (e.key === "Shift" || e.key.indexOf("Arrow") === 0) stashSelection();
  });

  if ("IntersectionObserver" in window) {
    let best = { id: "", title: "", text: "", ratio: 0 };
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          const el = entry.target as HTMLElement;
          if (entry.intersectionRatio >= best.ratio) {
            const h = el.querySelector("h2, h3");
            best = {
              id: el.id || "",
              title: h ? String(h.textContent || "").trim() : el.id || "",
              text: clip(el.innerText || "", 4000),
              ratio: entry.intersectionRatio,
            };
            tracker.visibleSection = {
              id: best.id,
              title: best.title,
              text: best.text,
            };
            updateContextChip();
          }
        });
      },
      { threshold: [0.15, 0.35, 0.55, 0.75] },
    );
    document.querySelectorAll("section[id]").forEach((sec) => io.observe(sec));
  }

  function readMetaFiles(): string[] {
    const files: string[] = [];
    document.querySelectorAll("a.editor-link").forEach((a) => {
      const t = (a.textContent || "").trim();
      if (t && files.indexOf(t) < 0) files.push(t);
    });
    return files.slice(0, 24);
  }

  /** Whole article text. The visible section alone is not enough to answer
   *  questions that span sections, and a tool-less backend has no way to go
   *  and fetch the rest. Sent once per session; the server caps it again. */
  function readDocumentText(): string {
    const main =
      document.querySelector(".main") ||
      document.querySelector("main") ||
      document.body;
    return clip((main as HTMLElement).innerText || "", 120000);
  }

  return tracker;
}
