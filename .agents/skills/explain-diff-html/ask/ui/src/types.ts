export type AskUiStrings = {
  idle: string;
  ready: string;
  noKey: string;
  localOnly: string;
  noBackend: string;
  selection: string;
  section: string;
};

export type PageMeta = {
  title?: string;
  repo_root?: string;
  archive_name?: string;
  ask_port?: number;
  service?: string;
  lang?: string;
  files?: string[];
  [key: string]: unknown;
};

export type ModelParam = { id?: string; value?: string | number | boolean };

export type HealthPayload = {
  ok?: boolean;
  service?: string;
  has_api_key?: boolean;
  sdk?: boolean;
  ollama?: boolean;
  chat?: boolean;
  model?: string;
  model_params?: ModelParam[];
};

export type VisibleSection = {
  id: string;
  title: string;
  text: string;
};

export type ServerMessage =
  | { type: "ready"; session_id?: string }
  | {
      type: "run_start";
      session_id?: string;
      agent_id?: string;
      model?: string;
      model_params?: ModelParam[];
    }
  | { type: "event"; event: StreamEvent }
  | {
      type: "run_end";
      status?: string;
      result?: string | null;
      agent_id?: string;
    }
  | { type: "error"; error?: string; detail?: string }
  | { type: "cancelled" }
  | { type: "disposed"; session_id?: string }
  | { type: "pong" }
  | { type: string; [key: string]: unknown };

export type StreamEvent =
  | { type: "thinking"; text?: string }
  | { type: "assistant"; text?: string }
  | { type: "tool_call"; name?: string; status?: string }
  | { type: "status"; status?: string }
  | { type: "usage"; usage?: { total_tokens?: number } }
  | { type: string; [key: string]: unknown };

export type BubbleOpts = {
  markdown?: boolean;
  streaming?: boolean;
};

declare global {
  interface Window {
    __explainDiffAsk?: boolean;
    __explainDiffAskBase?: string;
    __explainDiffAskHealth?: HealthPayload;
    __explainDiffAskLoader?: boolean;
    Prism?: {
      highlightElement: (el: Element) => void;
      manual?: boolean;
    };
  }
}

export {};
