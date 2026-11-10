import type { AskDom } from "./mount";
import type { ContextTracker } from "./context";
import { highlightAskCode, renderMarkdown } from "./markdown";
import { ASK_UI, DEFAULT_ASK_PORT } from "./strings";
import type {
  BubbleOpts,
  HealthPayload,
  ModelParam,
  PageMeta,
  ServerMessage,
} from "./types";

type AssistantState = { el: HTMLElement; raw: string };
type ThinkingState = { el: HTMLElement; body: HTMLElement; raw: string };

function formatModel(data: {
  model?: string;
  model_params?: ModelParam[];
}): string {
  const id = data?.model ? String(data.model) : "";
  if (!id) return "";
  const params = data.model_params || [];
  const bits: string[] = [];
  params.forEach((p) => {
    if (!p || !p.id) return;
    if (p.id === "effort") bits.push(String(p.value));
    else if (p.id === "fast" && String(p.value) === "true") bits.push("fast");
    else if (p.id === "backend") bits.push(String(p.value) === "ollama" ? "local" : String(p.value));
    else bits.push(p.id + "=" + p.value);
  });
  return bits.length ? id + " · " + bits.join(" · ") : id;
}

type CatalogEntry = {
  key: string;
  backend: string;
  id: string;
  label: string;
  tools?: boolean;
};

export function bootAskChat(
  dom: AskDom,
  pageMeta: PageMeta,
  ctx: ContextTracker,
): void {
  const {
    fab,
    panel,
    statusEl,
    modelEl,
    modelPicker,
    transcript,
    activityEl,
    activityText,
    form,
    input,
    sendBtn,
    cancelBtn,
    closeBtn,
  } = dom;

  let askBase: string | null = window.__explainDiffAskBase || null;
  const bootHealth: HealthPayload | null = window.__explainDiffAskHealth || null;
  let askSessionId: string | null = null;
  let askWs: WebSocket | null = null;
  let askBusy = false;
  let askModelLabel = "";
  // Selected catalog key, e.g. "cursor:grok-4.6" or "ollama:qwen3.8:27b-mlx".
  const MODEL_KEY_STORE = "explain-diff-ask-model";
  let selectedModel: string | null = null;
  try {
    selectedModel = localStorage.getItem(MODEL_KEY_STORE);
  } catch (e) {
    selectedModel = null;
  }
  let assistantState: AssistantState | null = null;
  let thinkingState: ThinkingState | null = null;
  let renderQueued = false;
  const toolEls = new Map<string, HTMLElement>();

  function setModelBadge(label: string): void {
    askModelLabel = label || "";
    if (!askModelLabel) {
      modelEl.hidden = true;
      modelEl.textContent = "";
      return;
    }
    modelEl.hidden = false;
    modelEl.textContent = askModelLabel;
  }

  function setActivity(text: string): void {
    if (!text) {
      activityEl.hidden = true;
      activityText.textContent = "";
      activityEl.classList.remove("is-live");
      return;
    }
    activityEl.hidden = false;
    activityEl.classList.add("is-live");
    activityText.textContent = text;
  }

  function appendBubble(
    role: string,
    text: string,
    opts: BubbleOpts = {},
  ): HTMLElement {
    const div = document.createElement("div");
    div.className =
      "ask-bubble ask-" + role + (opts.streaming ? " is-streaming" : "");
    if (opts.markdown) {
      div.innerHTML = renderMarkdown(text || "");
      highlightAskCode(div);
    } else {
      div.textContent = text || "";
    }
    transcript.appendChild(div);
    transcript.scrollTop = transcript.scrollHeight;
    return div;
  }

  /** Finalize current assistant bubble so later text opens a new one (timeline order). */
  function sealAssistant(): void {
    if (!assistantState) return;
    assistantState.el.classList.remove("is-streaming");
    assistantState.el.innerHTML = renderMarkdown(assistantState.raw);
    highlightAskCode(assistantState.el);
    assistantState = null;
    renderQueued = false;
  }

  function sealThinking(): void {
    if (!thinkingState) return;
    thinkingState.el.classList.add("is-done");
    thinkingState = null;
  }

  function ensureAssistantBubble(): AssistantState {
    if (assistantState?.el) return assistantState;
    sealThinking();
    const el = appendBubble("assistant", "", { markdown: true, streaming: true });
    assistantState = { el, raw: "" };
    return assistantState;
  }

  function ensureThinkingBubble(): ThinkingState {
    if (thinkingState?.el) return thinkingState;
    sealAssistant();
    const el = appendBubble("thinking", "", { streaming: true });
    const label = document.createElement("div");
    label.className = "ask-thinking-label";
    label.textContent = "Thinking";
    const body = document.createElement("div");
    body.className = "ask-thinking-body";
    el.appendChild(label);
    el.appendChild(body);
    thinkingState = { el, body, raw: "" };
    return thinkingState;
  }

  function queueAssistantRender(): void {
    if (!assistantState || renderQueued) return;
    renderQueued = true;
    requestAnimationFrame(() => {
      renderQueued = false;
      if (!assistantState) return;
      assistantState.el.innerHTML = renderMarkdown(assistantState.raw);
      highlightAskCode(assistantState.el);
      transcript.scrollTop = transcript.scrollHeight;
    });
  }

  function upsertToolBubble(evnt: {
    id?: string;
    name?: string;
    status?: string;
    args?: unknown;
  }): void {
    sealAssistant();
    sealThinking();
    const name = evnt.name || "tool";
    const status = String(evnt.status || "running").toLowerCase();
    const key = String(evnt.id || name);
    let el = toolEls.get(key);
    if (!el) {
      el = document.createElement("div");
      el.className = "ask-bubble ask-tool";
      el.dataset.toolKey = key;
      transcript.appendChild(el);
      toolEls.set(key, el);
    }
    el.dataset.status = status;
    el.classList.toggle("is-running", status === "running" || status === "in_progress");
    el.classList.toggle("is-done", status === "completed" || status === "done" || status === "success");
    el.classList.toggle("is-error", status === "error" || status === "failed");

    const statusLabel =
      status === "running" || status === "in_progress"
        ? "running"
        : status === "completed" || status === "done" || status === "success"
          ? "done"
          : status;

    let detail = "";
    if (evnt.args != null) {
      try {
        const raw =
          typeof evnt.args === "string" ? evnt.args : JSON.stringify(evnt.args);
        detail = raw.length > 120 ? raw.slice(0, 120) + "\u2026" : raw;
      } catch {
        detail = "";
      }
    }

    el.innerHTML =
      '<span class="ask-tool-name">' +
      escapeText(name) +
      '</span><span class="ask-tool-status">' +
      escapeText(statusLabel) +
      "</span>" +
      (detail
        ? '<span class="ask-tool-detail">' + escapeText(detail) + "</span>"
        : "");
    transcript.scrollTop = transcript.scrollHeight;
  }

  function escapeText(s: string): string {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function setBusy(busy: boolean): void {
    askBusy = busy;
    sendBtn.disabled = busy || !askBase;
    cancelBtn.disabled = !busy;
    input.disabled = false;
    document.body.classList.toggle("ask-busy", busy);
    if (!busy) {
      setActivity("");
      sealAssistant();
      sealThinking();
    }
  }

  function openPanel(open: boolean): void {
    panel.hidden = !open;
    document.body.classList.toggle("ask-open", open);
    fab.hidden = open || !askBase;
    fab.setAttribute("aria-expanded", open ? "true" : "false");
    if (open) input.focus();
  }

  function wsUrl(): string {
    let u = askBase!.replace(/^http/, "ws") + "/api/chat";
    if (askSessionId) u += "?session_id=" + encodeURIComponent(askSessionId);
    return u;
  }

  function handleServerMessage(msg: ServerMessage): void {
    if (msg.type === "ready" && typeof msg.session_id === "string") {
      askSessionId = msg.session_id;
    }

    if (msg.type === "run_start") {
      toolEls.clear();
      setModelBadge(formatModel(msg as HealthPayload) || askModelLabel);
      setActivity("Running" + (askModelLabel ? " · " + askModelLabel : "") + "\u2026");
      statusEl.textContent = askModelLabel ? "Live · " + askModelLabel : "Live";
      return;
    }

    if (msg.type === "event" && msg.event && typeof msg.event === "object") {
      const evnt = msg.event as {
        type?: string;
        text?: string;
        name?: string;
        status?: string;
        id?: string;
        call_id?: string;
        args?: unknown;
        arguments?: unknown;
        usage?: { total_tokens?: number };
      };
      if (evnt.type === "thinking") {
        const th = ensureThinkingBubble();
        th.raw += evnt.text || "";
        th.body.textContent = th.raw;
        setActivity("Thinking\u2026");
        transcript.scrollTop = transcript.scrollHeight;
      } else if (evnt.type === "assistant" && evnt.text) {
        const as = ensureAssistantBubble();
        as.raw += evnt.text;
        queueAssistantRender();
        setActivity("Writing\u2026");
      } else if (evnt.type === "tool_call") {
        upsertToolBubble({
          id: evnt.id || evnt.call_id,
          name: evnt.name,
          status: evnt.status,
          args: evnt.args ?? evnt.arguments,
        });
        setActivity("Tool: " + (evnt.name || "?"));
      } else if (evnt.type === "status" && evnt.status) {
        setActivity(String(evnt.status));
        statusEl.textContent = String(evnt.status);
      } else if (evnt.type === "usage" && evnt.usage) {
        if (evnt.usage.total_tokens != null) {
          setActivity("Tokens · " + evnt.usage.total_tokens);
        }
      }
      return;
    }

    if (msg.type === "run_end") {
      if (!assistantState && msg.result) {
        appendBubble("assistant", String(msg.result), { markdown: true });
      } else if (assistantState) {
        sealAssistant();
      }
      sealThinking();
      setBusy(false);
      statusEl.textContent = askModelLabel
        ? ASK_UI.ready + " · " + askModelLabel
        : ASK_UI.ready;
      return;
    }

    if (msg.type === "error") {
      sealAssistant();
      sealThinking();
      appendBubble("error", (msg.error as string) || "error");
      setBusy(false);
      statusEl.textContent = "Error";
      return;
    }

    if (msg.type === "cancelled") {
      sealAssistant();
      sealThinking();
      appendBubble("tool", "(cancelled)");
      setBusy(false);
      statusEl.textContent = askModelLabel || ASK_UI.ready;
    }
  }

  function ensureWs(): Promise<WebSocket> {
    return new Promise((resolve, reject) => {
      if (askWs && askWs.readyState === 1) {
        resolve(askWs);
        return;
      }
      const ws = new WebSocket(wsUrl());
      askWs = ws;
      ws.onopen = () => resolve(ws);
      ws.onerror = () => reject(new Error("WebSocket error"));
      ws.onclose = () => {
        if (askWs === ws) askWs = null;
      };
      ws.onmessage = (ev) => {
        let parsed: ServerMessage;
        try {
          parsed = JSON.parse(String(ev.data)) as ServerMessage;
        } catch {
          return;
        }
        handleServerMessage(parsed);
      };
    });
  }

  /** Fill the picker from /api/models; hidden when only one model is offered. */
  function loadModelCatalog(): void {
    if (!askBase) return;
    fetch(askBase + "/api/models", { mode: "cors", cache: "no-store" })
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((data: { default?: string; models?: CatalogEntry[] }) => {
        const models = data.models || [];
        if (models.length < 1) {
          modelPicker.hidden = true;
          return;
        }
        const keys = models.map((m) => m.key);
        // A remembered model that is gone (Ollama stopped, tag removed) must
        // not silently pin the session to something the server cannot serve.
        if (!selectedModel || keys.indexOf(selectedModel) < 0) {
          selectedModel = data.default || keys[0];
        }
        modelPicker.innerHTML = "";
        models.forEach((m) => {
          const opt = document.createElement("option");
          opt.value = m.key;
          opt.textContent = m.label || m.id;
          if (m.backend === "ollama") opt.title = "Local model · read-only repo tools";
          modelPicker.appendChild(opt);
        });
        modelPicker.value = selectedModel || "";
        modelPicker.hidden = false;
        syncModelBadge(models);
      })
      .catch(() => {
        modelPicker.hidden = true;
      });
  }

  function syncModelBadge(models: CatalogEntry[]): void {
    const hit = models.filter((m) => m.key === selectedModel)[0];
    if (hit) setModelBadge(hit.label || hit.id);
  }

  modelPicker.addEventListener("change", () => {
    selectedModel = modelPicker.value;
    try {
      localStorage.setItem(MODEL_KEY_STORE, selectedModel);
    } catch (e) {
      /* private mode: selection is just not remembered */
    }
    setModelBadge(modelPicker.options[modelPicker.selectedIndex].textContent || "");
    // The server rebuilds the session on a model change; drop ours too so the
    // transcript and the backend agree on where the conversation starts.
    if (askWs && askWs.readyState === WebSocket.OPEN) {
      askWs.send(JSON.stringify({ type: "dispose" }));
    }
    appendBubble("tool", "Model: " + (selectedModel || ""));
  });

  function applyHealth(data: HealthPayload | null): void {
    const params = new URLSearchParams(location.search || "");
    fab.hidden = document.body.classList.contains("ask-open");
    const canChat = Boolean(
      data?.chat ?? (data?.has_api_key || data?.ollama),
    );
    sendBtn.disabled = !canChat;
    setModelBadge(formatModel(data || {}));
    if (canChat && data?.has_api_key) {
      statusEl.textContent = askModelLabel
        ? ASK_UI.ready + " · " + askModelLabel
        : ASK_UI.ready;
    } else if (canChat) {
      statusEl.textContent = ASK_UI.localOnly;
    } else if (data?.ok) {
      statusEl.textContent = ASK_UI.noBackend;
    } else {
      statusEl.textContent = ASK_UI.idle;
    }
    loadModelCatalog();
    if (params.get("ask") === "1") openPanel(true);
  }

  function probeAsk(): void {
    const params = new URLSearchParams(location.search || "");
    if (askBase && bootHealth) {
      applyHealth(bootHealth);
      return;
    }
    if (askBase) {
      fetch(askBase + "/health", { method: "GET", mode: "cors", cache: "no-store" })
        .then((r) => (r.ok ? r.json() : Promise.reject()))
        .then((data: HealthPayload) => applyHealth(data))
        .catch(() => {
          statusEl.textContent = ASK_UI.idle;
        });
      return;
    }
    let port = parseInt(
      String(params.get("askPort") || pageMeta.ask_port || DEFAULT_ASK_PORT),
      10,
    );
    if (!port) port = DEFAULT_ASK_PORT;
    const candidates: string[] = [];
    if (location.protocol === "http:" || location.protocol === "https:") {
      candidates.push(location.origin);
    }
    candidates.push("http://127.0.0.1:" + port);
    let i = 0;
    function next(): void {
      if (i >= candidates.length) return;
      const base = candidates[i++];
      fetch(base + "/health", { method: "GET", mode: "cors", cache: "no-store" })
        .then((r) => (r.ok ? r.json() : Promise.reject()))
        .then((data: HealthPayload) => {
          if (!data || !data.ok || data.service !== "explain-diff") return next();
          askBase = base;
          window.__explainDiffAskBase = base;
          applyHealth(data);
        })
        .catch(next);
    }
    next();
  }

  fab.addEventListener("click", () => openPanel(true));
  closeBtn.addEventListener("click", () => openPanel(false));
  cancelBtn.addEventListener("click", () => {
    if (!askWs || askWs.readyState !== 1) return;
    askWs.send(JSON.stringify({ type: "cancel" }));
    setActivity("Cancelling\u2026");
  });
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    if (askBusy || !askBase) return;
    const q = String(input.value || "").trim();
    if (!q) return;
    if (panel.hidden) openPanel(true);
    toolEls.clear();
    setBusy(true);
    assistantState = null;
    thinkingState = null;
    setActivity("Starting" + (askModelLabel ? " · " + askModelLabel : "") + "\u2026");
    appendBubble("user", q);
    input.value = "";
    const files = ctx.readMetaFiles();
    const payload = {
      type: "message",
      question: q,
      model: selectedModel || undefined,
      selection: ctx.lastSelection,
      section_id: ctx.visibleSection.id,
      section_title: ctx.visibleSection.title,
      section_text: ctx.visibleSection.text,
      document_text: ctx.readDocumentText(),
      meta: { ...pageMeta, files },
      files,
    };
    ensureWs()
      .then((ws) => ws.send(JSON.stringify(payload)))
      .catch((err: Error) => {
        appendBubble("error", String(err.message || err));
        setBusy(false);
      });
  });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      form.requestSubmit();
    }
  });
  window.addEventListener("beforeunload", () => {
    if (askWs && askWs.readyState === 1) {
      try {
        askWs.send(JSON.stringify({ type: "dispose" }));
      } catch {
        /* ignore */
      }
    }
  });
  probeAsk();
}
