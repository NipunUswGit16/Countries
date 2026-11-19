#!/usr/bin/env python3
"""Localhost Ask sidecar for explain-diff HTML pages (Cursor SDK + WebSocket)."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import traceback
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import unquote

import ollama_backend

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 7432
DEFAULT_MODEL = "grok-4.6"
DEFAULT_EFFORT = "high"
DEFAULT_FAST = "true"
SELECTION_CAP = 12_000
SECTION_CAP = 4_000
DOCUMENT_CAP = 60_000
FILES_CAP = 24

ASK_DIR = Path(__file__).resolve().parent
SKILL_DIR = ASK_DIR.parent
ASK_ASSET_DIR = ASK_DIR / "static"
ASK_ASSETS = frozenset({"ask.css", "ask.js", "ask-loader.js"})


# Pack copy and this checkout: VERSION / .venv / .env live next to the skill.
REPO_ROOT = SKILL_DIR


def _load_version() -> str:
    for path in (SKILL_DIR / "VERSION", REPO_ROOT / "VERSION"):
        if path.is_file():
            text = path.read_text(encoding="utf-8").strip()
            if text:
                return text
    return "0.0.0-dev"


VERSION = _load_version()


def _apply_env_file(env_path: Path) -> None:
    if not env_path.is_file():
        return
    for raw in env_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if key and key not in os.environ:
            os.environ[key] = value


def load_dotenv(path: Path | None = None) -> None:
    """Load KEY=VALUE from .env into os.environ (do not override existing)."""
    if path is not None:
        _apply_env_file(path)
        return
    _apply_env_file(SKILL_DIR / ".env")
    _apply_env_file(REPO_ROOT / ".env")
    try:
        import subprocess

        top = subprocess.check_output(
            ["git", "-C", str(SKILL_DIR), "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if top:
            _apply_env_file(Path(top) / ".env")
    except Exception:
        pass


def _api_key() -> str | None:
    key = (os.environ.get("CURSOR_API_KEY") or "").strip()
    return key or None


def _sdk_available() -> bool:
    try:
        import cursor_sdk  # noqa: F401

        return True
    except ImportError:
        return False


def _cursor_ready() -> bool:
    """Cursor harness needs both the SDK and an API key. Ollama needs neither."""
    return bool(_api_key()) and _sdk_available()


def resolve_cursor_model(model_id: str | None = None) -> Any | None:
    """Build SDK model selection; grok models default to effort=high, fast=true.

    Matched on the `grok-` prefix rather than an exact id: the defaults used to
    be keyed to the literal "grok-4.5", so bumping the version silently dropped
    effort/fast. grok-4.6 also accepts effort=xhigh, which callers can select
    through EXPLAIN_DIFF_MODEL_EFFORT.
    Returns None when cursor-sdk is not installed — Ollama-only mode.
    """
    if not _sdk_available():
        return None
    from cursor_sdk import ModelParameterValue, ModelSelection

    mid = (model_id or os.environ.get("EXPLAIN_DIFF_MODEL") or DEFAULT_MODEL).strip()
    effort = (os.environ.get("EXPLAIN_DIFF_MODEL_EFFORT") or "").strip()
    fast = (os.environ.get("EXPLAIN_DIFF_MODEL_FAST") or "").strip()

    is_grok = mid.startswith("grok-")
    params: list[Any] = []
    if is_grok or effort or fast:
        if is_grok:
            effort = effort or DEFAULT_EFFORT
            fast = fast or DEFAULT_FAST
        if effort:
            params.append(ModelParameterValue(id="effort", value=effort))
        if fast:
            params.append(ModelParameterValue(id="fast", value=fast))
    return ModelSelection(id=mid, params=params)


def cursor_model_entry(model: Any) -> dict[str, Any]:
    """Catalog entry for the configured Cursor model."""
    mid = getattr(model, "id", None) or str(model)
    bits: list[str] = []
    for p in getattr(model, "params", None) or ():
        # Boolean params read better as the flag name ("fast") than as "true";
        # a disabled flag is just omitted.
        if str(p.value).lower() == "true":
            bits.append(str(p.id))
        elif str(p.value).lower() != "false" and p.value:
            bits.append(str(p.value))
    suffix = " · " + " · ".join(bits) if bits else ""
    return {
        "key": f"cursor:{mid}",
        "backend": "cursor",
        "id": mid,
        "label": f"{mid}{suffix}",
        "capabilities": ["tools", "repo"],
        "tools": True,
    }


async def model_catalog(model: Any) -> dict[str, Any]:
    """Selectable models that can actually answer.

    Cursor is listed only when the SDK + API key are present (the harness
    cannot run without both). Ollama tags appear when the daemon is up.
    Default prefers an explicit EXPLAIN_DIFF_DEFAULT_MODEL, then Cursor if
    ready, then the first local model.
    """
    entries: list[dict[str, Any]] = []
    if model is not None and _cursor_ready():
        entries.append(cursor_model_entry(model))
    try:
        entries.extend(await ollama_backend.list_models())
    except Exception:
        pass

    default_key = (os.environ.get("EXPLAIN_DIFF_DEFAULT_MODEL") or "").strip()
    keys = {e["key"] for e in entries}
    if default_key not in keys:
        default_key = entries[0]["key"] if entries else ""
    return {"default": default_key, "models": entries}


def split_model_key(key: str) -> tuple[str, str]:
    """`cursor:grok-4.6` / `ollama:qwen3.8:27b-mlx` -> (backend, model id).

    Only the first colon is a separator: Ollama tags contain colons themselves.
    """
    backend, _, mid = (key or "").partition(":")
    if backend not in ("cursor", "ollama") or not mid:
        return "cursor", ""
    return backend, mid


def build_prompt(
    payload: dict[str, Any], tools: bool = True, include_document: bool = False
) -> str:
    """Assemble the harness prompt from client context + question.

    `tools=False` drops the "you may inspect the repo" closing line: the Ollama
    backend has no tool loop, and telling a model it can read files it cannot
    reach is how you get confidently invented file contents.
    """
    meta = payload.get("meta") or {}
    title = str(meta.get("title") or payload.get("title") or "Untitled").strip()
    repo = str(meta.get("repo_root") or payload.get("repo_root") or "").strip()
    page = str(meta.get("archive_name") or payload.get("page") or "").strip()
    section_id = str(payload.get("section_id") or "").strip()
    section_title = str(payload.get("section_title") or "").strip()
    section_text = str(payload.get("section_text") or "").strip()[:SECTION_CAP]
    selection = str(payload.get("selection") or "").strip()[:SELECTION_CAP]
    question = str(payload.get("question") or payload.get("text") or "").strip()
    files = payload.get("files") or meta.get("files") or []
    if not isinstance(files, list):
        files = []
    file_lines = [str(f).strip() for f in files if str(f).strip()][:FILES_CAP]
    document = str(payload.get("document_text") or "").strip()[:DOCUMENT_CAP]

    parts = [
        "# Document context",
        f"Page: {title}",
    ]
    if page:
        parts.append(f"Archive file: {page}")
    if repo:
        parts.append(f"Repo: {repo}")
    if section_id or section_title:
        label = " — ".join(x for x in (section_id, section_title) if x)
        parts.append(f"Section: {label}")
    if include_document and document:
        parts.append("Full document text (the whole page, for reference):")
        parts.append("<<<")
        parts.append(document)
        parts.append(">>>")
    if section_text:
        parts.append("Section excerpt (what the reader is looking at):")
        parts.append("<<<")
        parts.append(section_text)
        parts.append(">>>")
    if selection:
        parts.append("Selection (primary focus):")
        parts.append("<<<")
        parts.append(selection)
        parts.append(">>>")
    if file_lines:
        parts.append("File refs mentioned on the page:")
        parts.extend(f"- {f}" for f in file_lines)
    parts.append("")
    parts.append("# Question")
    parts.append(question or "(no question text)")
    parts.append("")
    closing = (
        "Answer with reference to the document context above. "
        "Prefer the selection when present."
    )
    if tools:
        closing += " You may inspect the repo at Repo."
    else:
        closing += (
            " You cannot open files: answer from the context above, and say so"
            " when it is not enough."
        )
    parts.append(closing)
    return "\n".join(parts)


def serialize_message(message: Any) -> dict[str, Any]:
    """Map an SDK stream message to a JSON-friendly event for the browser."""
    mtype = getattr(message, "type", None) or type(message).__name__
    out: dict[str, Any] = {"type": str(mtype)}

    if mtype == "assistant":
        texts: list[str] = []
        inner = getattr(message, "message", None)
        content = getattr(inner, "content", None) if inner is not None else None
        if content is None:
            content = getattr(message, "content", None)
        if content:
            for block in content:
                if getattr(block, "type", None) == "text":
                    texts.append(getattr(block, "text", "") or "")
        out["text"] = "".join(texts)
    elif mtype == "thinking":
        out["text"] = getattr(message, "text", "") or ""
    elif mtype == "tool_call":
        out["name"] = getattr(message, "name", None)
        out["status"] = getattr(message, "status", None)
        for key in ("id", "call_id", "tool_call_id"):
            val = getattr(message, key, None)
            if val:
                out["id"] = str(val)
                break
        args = getattr(message, "args", None)
        if args is None:
            args = getattr(message, "arguments", None)
        if args is not None:
            try:
                if hasattr(args, "model_dump"):
                    args = args.model_dump()
                elif hasattr(args, "dict"):
                    args = args.dict()
            except Exception:
                pass
            out["args"] = args
    elif mtype == "status":
        out["status"] = getattr(message, "status", None)
    elif mtype == "usage":
        usage = getattr(message, "usage", None)
        if usage is not None:
            out["usage"] = {
                "total_tokens": getattr(usage, "total_tokens", None),
                "input_tokens": getattr(usage, "input_tokens", None),
                "output_tokens": getattr(usage, "output_tokens", None),
            }
    else:
        # Best-effort fallback for unknown shapes
        text = getattr(message, "text", None)
        if text:
            out["text"] = text
    return out


@dataclass
class ChatSession:
    session_id: str
    repo_root: Path
    client: Any = None
    agent: Any = None
    agent_id: str | None = None
    current_run: Any = None
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    # Which catalog entry this session is currently bound to. Switching models
    # tears the session down (see SessionStore.get_or_create) rather than
    # carrying a Cursor agent's state into a local model, or vice versa.
    model_key: str | None = None
    # The article is sent once per session: after the first turn it lives in the
    # agent's conversation (Cursor) or in `history` (Ollama).
    sent_document: bool = False
    # Cached article for backends whose history holds only Q/A (Ollama).
    document: str = ""
    # Ollama has no server-side agent, so multi-turn lives here.
    history: list[dict[str, str]] = field(default_factory=list)
    cancelled: bool = False

    def remember(self, question: str, answer: str) -> None:
        if question:
            self.history.append({"role": "user", "content": question})
        if answer:
            self.history.append({"role": "assistant", "content": answer})
        # Keep the tail; the backend trims again when building the request.
        if len(self.history) > 2 * ollama_backend.HISTORY_TURNS:
            self.history = self.history[-2 * ollama_backend.HISTORY_TURNS :]

    async def ensure_agent(self, api_key: str, model: Any) -> None:
        if self.agent is not None:
            return
        from cursor_sdk import AsyncClient, LocalAgentOptions

        cwd = str(self.repo_root)
        self.client = await AsyncClient.launch_bridge(workspace=cwd)
        await self.client.__aenter__()
        self.agent = await self.client.agents.create(
            model=model,
            api_key=api_key,
            local=LocalAgentOptions(cwd=cwd),
            name=f"explain-diff:{self.session_id[:8]}",
        )
        # Enter agent context for cleanup symmetry
        await self.agent.__aenter__()
        self.agent_id = getattr(self.agent, "agent_id", None)

    async def close(self) -> None:
        if self.current_run is not None:
            try:
                if self.current_run.supports("cancel"):
                    await self.current_run.cancel()
            except Exception:
                pass
            self.current_run = None
        if self.agent is not None:
            try:
                await self.agent.__aexit__(None, None, None)
            except Exception:
                try:
                    await self.agent.close()
                except Exception:
                    pass
            self.agent = None
        if self.client is not None:
            try:
                await self.client.__aexit__(None, None, None)
            except Exception:
                try:
                    await self.client.aclose()
                except Exception:
                    pass
            self.client = None


class SessionStore:
    def __init__(self) -> None:
        self._sessions: dict[str, ChatSession] = {}
        self._lock = asyncio.Lock()

    async def get_or_create(
        self, session_id: str, repo_root: Path, model_key: str | None = None
    ) -> ChatSession:
        async with self._lock:
            sess = self._sessions.get(session_id)
            stale = sess is not None and (
                sess.repo_root != repo_root
                # A model switch is a hard reset: the Cursor agent and the local
                # history are different state stores, and blending them would
                # silently drop or duplicate turns.
                or (model_key is not None and sess.model_key not in (None, model_key))
            )
            if sess is None or stale:
                if sess is not None:
                    await sess.close()
                sess = ChatSession(session_id=session_id, repo_root=repo_root)
                self._sessions[session_id] = sess
            if model_key is not None:
                sess.model_key = model_key
            return sess

    async def drop(self, session_id: str) -> None:
        async with self._lock:
            sess = self._sessions.pop(session_id, None)
        if sess is not None:
            await sess.close()

    async def close_all(self) -> None:
        async with self._lock:
            items = list(self._sessions.values())
            self._sessions.clear()
        for sess in items:
            await sess.close()


async def run_ollama_turn(
    websocket: Any,
    sess: ChatSession,
    model_id: str,
    model_key: str,
    prompt: str,
    question: str,
) -> None:
    """Stream one local-model turn, mirroring the Cursor run_start/event/run_end shape."""
    await websocket.send_json(
        {
            "type": "run_start",
            "session_id": sess.session_id,
            "agent_id": None,
            "model": model_id,
            "model_key": model_key,
            "model_params": [{"id": "backend", "value": "ollama"}],
        }
    )
    sess.cancelled = False
    messages = ollama_backend.build_messages(
        prompt, sess.history, sess.document, tools=True
    )
    answer: list[str] = []
    try:
        # repo_root is the sandbox boundary for the read-only tools.
        async for event in ollama_backend.stream_chat(
            model_id, messages, repo_root=sess.repo_root
        ):
            if sess.cancelled:
                break
            if event.get("type") == "assistant" and event.get("text"):
                answer.append(event["text"])
            await websocket.send_json({"type": "event", "event": event})
    finally:
        # Remember whatever was produced, including a cancelled partial answer,
        # so the next turn sees the same conversation the reader sees.
        sess.remember(question, "".join(answer))
    await websocket.send_json(
        {
            "type": "run_end",
            "status": "cancelled" if sess.cancelled else "completed",
            "result": None,
            "agent_id": None,
        }
    )
    sess.cancelled = False


def create_app(archive: Path, model: Any) -> Any:
    from starlette.applications import Starlette
    from starlette.middleware.cors import CORSMiddleware
    from starlette.requests import Request
    from starlette.responses import FileResponse, JSONResponse, Response
    from starlette.routing import Route, WebSocketRoute
    from starlette.websockets import WebSocket, WebSocketDisconnect

    archive = archive.resolve()
    store = SessionStore()

    async def models_endpoint(_request: Request) -> JSONResponse:
        return JSONResponse(await model_catalog(model))

    async def health(_request: Request) -> JSONResponse:
        key = _api_key()
        ollama_ok = await ollama_backend.ping()
        cursor_ok = bool(key) and _sdk_available()
        return JSONResponse(
            {
                "ok": True,
                "version": VERSION,
                "service": "explain-diff",
                "archive": str(archive),
                "has_api_key": bool(key),
                "sdk": _sdk_available(),
                "ollama": ollama_ok,
                "chat": cursor_ok or ollama_ok,
                "model": (getattr(model, "id", None) or None) if model is not None else None,
                "model_params": [
                    {"id": p.id, "value": p.value}
                    for p in (getattr(model, "params", None) or ())
                ]
                if model is not None
                else [],
            }
        )

    async def index(_request: Request) -> Response:
        pages = _list_pages(archive)
        if not pages:
            return JSONResponse(
                {"ok": True, "pages": [], "hint": f"No explanation HTML in {archive}"},
            )
        items = "".join(
            f'<li><a href="/p/{html_escape(p.name)}">{html_escape(p.name)}</a></li>'
            for p in pages
        )
        body = (
            "<!DOCTYPE html><html><head><meta charset='utf-8'>"
            "<title>explain-diff archive</title>"
            "<style>body{font:16px/1.5 system-ui;max-width:48rem;margin:2rem auto;padding:0 1rem}"
            "a{color:#2563eb}</style></head><body>"
            "<h1>explain-diff</h1>"
            f"<p>Archive: <code>{html_escape(str(archive))}</code></p>"
            f"<ol>{items}</ol></body></html>"
        )
        return Response(body, media_type="text/html; charset=utf-8")

    async def page(request: Request) -> Response:
        name = unquote(request.path_params["name"])
        # Prevent path traversal
        if "/" in name or "\\" in name or name in (".", ".."):
            return JSONResponse({"error": "invalid name"}, status_code=400)
        path = (archive / name).resolve()
        try:
            path.relative_to(archive)
        except ValueError:
            return JSONResponse({"error": "not found"}, status_code=404)
        if not path.is_file() or not name.endswith(".html"):
            return JSONResponse({"error": "not found"}, status_code=404)
        return FileResponse(path, media_type="text/html; charset=utf-8")

    async def ask_asset(request: Request) -> Response:
        name = unquote(request.path_params["name"])
        if name not in ASK_ASSETS:
            return JSONResponse({"error": "not found"}, status_code=404)
        path = (ASK_ASSET_DIR / name).resolve()
        try:
            path.relative_to(ASK_ASSET_DIR.resolve())
        except ValueError:
            return JSONResponse({"error": "not found"}, status_code=404)
        if not path.is_file():
            return JSONResponse({"error": "not found"}, status_code=404)
        if name.endswith(".css"):
            media = "text/css; charset=utf-8"
        elif name.endswith(".js"):
            media = "application/javascript; charset=utf-8"
        else:
            media = "text/html; charset=utf-8"
        # Ask UI iterates often during local dev — avoid stale assets in the browser.
        return FileResponse(
            path,
            media_type=media,
            headers={"Cache-Control": "no-cache"},
        )

    async def session_info(request: Request) -> JSONResponse:
        sid = request.query_params.get("session_id") or ""
        sess = store._sessions.get(sid)  # noqa: SLF001 — read-only peek
        if not sess:
            return JSONResponse({"session_id": sid or None, "agent_id": None})
        return JSONResponse({"session_id": sess.session_id, "agent_id": sess.agent_id})

    async def chat_ws(websocket: WebSocket) -> None:
        await websocket.accept()
        session_id = websocket.query_params.get("session_id") or str(uuid.uuid4())
        sess: ChatSession | None = None
        try:
            await websocket.send_json(
                {"type": "ready", "session_id": session_id, "version": VERSION}
            )
            while True:
                raw = await websocket.receive_text()
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    await websocket.send_json({"type": "error", "error": "invalid JSON"})
                    continue
                mtype = msg.get("type")
                if mtype == "ping":
                    await websocket.send_json({"type": "pong"})
                    continue
                if mtype == "dispose":
                    await store.drop(session_id)
                    sess = None
                    await websocket.send_json({"type": "disposed", "session_id": session_id})
                    continue
                if mtype == "cancel":
                    if sess is not None:
                        # Ollama has no Run to cancel; the stream loop polls this.
                        sess.cancelled = True
                    if sess and sess.current_run is not None:
                        try:
                            if sess.current_run.supports("cancel"):
                                await sess.current_run.cancel()
                        except Exception as exc:
                            await websocket.send_json(
                                {"type": "error", "error": f"cancel failed: {exc}"}
                            )
                    await websocket.send_json({"type": "cancelled"})
                    continue
                if mtype not in ("message", "start"):
                    await websocket.send_json(
                        {"type": "error", "error": f"unknown type: {mtype}"}
                    )
                    continue

                question = str(msg.get("question") or msg.get("text") or "").strip()
                if not question:
                    await websocket.send_json(
                        {"type": "error", "error": "empty question"}
                    )
                    continue

                # Which backend answers this turn. Falls back to the process
                # default when the client sends nothing (older pages).
                requested = str(msg.get("model") or "").strip()
                backend, model_id = split_model_key(requested)
                if not model_id:
                    catalog = await model_catalog(model)
                    backend, model_id = split_model_key(
                        str(catalog.get("default") or "")
                    )
                if not model_id:
                    await websocket.send_json(
                        {
                            "type": "error",
                            "error": "no chat backend: set CURSOR_API_KEY or start Ollama",
                        }
                    )
                    continue

                api_key = _api_key()
                if backend == "cursor":
                    if not api_key:
                        await websocket.send_json(
                            {
                                "type": "error",
                                "error": "CURSOR_API_KEY not set on the serve process",
                            }
                        )
                        continue
                    if not _sdk_available():
                        await websocket.send_json(
                            {
                                "type": "error",
                                "error": "cursor-sdk not installed (pip install -r ask/requirements.txt)",
                            }
                        )
                        continue

                repo_raw = (
                    (msg.get("meta") or {}).get("repo_root")
                    or msg.get("repo_root")
                    or ""
                )
                repo_root = Path(str(repo_raw)).expanduser() if repo_raw else Path.cwd()
                if not repo_root.is_dir():
                    await websocket.send_json(
                        {
                            "type": "error",
                            "error": f"repo_root is not a directory: {repo_root}",
                        }
                    )
                    continue

                model_key = f"{backend}:{model_id}"
                # Session first: it knows whether the article was already sent.
                sess = await store.get_or_create(
                    session_id, repo_root.resolve(), model_key=model_key
                )
                incoming_doc = str(msg.get("document_text") or "").strip()
                if incoming_doc and not sess.document:
                    sess.document = incoming_doc[:DOCUMENT_CAP]
                # Cursor keeps the thread server-side, so the article goes in
                # the first prompt only. Ollama gets it re-injected per turn by
                # build_messages from sess.document.
                prompt = build_prompt(
                    msg,
                    tools=True,
                    include_document=(
                        backend == "cursor" and not sess.sent_document
                    ),
                )
                if backend == "cursor":
                    sess.sent_document = True

                async with sess.lock:
                    try:
                        if backend == "ollama":
                            await run_ollama_turn(
                                websocket, sess, model_id, model_key, prompt, question
                            )
                        else:
                            await sess.ensure_agent(api_key, model)
                            assert sess.agent is not None
                            await websocket.send_json(
                                {
                                    "type": "run_start",
                                    "session_id": session_id,
                                    "agent_id": sess.agent_id,
                                    "model": getattr(model, "id", None) or str(model),
                                    "model_key": model_key,
                                    "model_params": [
                                        {"id": p.id, "value": p.value}
                                        for p in (getattr(model, "params", None) or ())
                                    ],
                                }
                            )
                            run = await sess.agent.send(prompt)
                            sess.current_run = run
                            async for event in run.stream():
                                await websocket.send_json(
                                    {"type": "event", "event": serialize_message(event)}
                                )
                            result = await run.wait()
                            sess.current_run = None
                            await websocket.send_json(
                                {
                                    "type": "run_end",
                                    "status": getattr(result, "status", None),
                                    "result": getattr(result, "result", None),
                                    "agent_id": sess.agent_id,
                                }
                            )
                    except Exception as exc:
                        sess.current_run = None
                        await websocket.send_json(
                            {
                                "type": "error",
                                "error": str(exc),
                                "detail": traceback.format_exc(limit=4),
                            }
                        )
        except WebSocketDisconnect:
            pass
        finally:
            # Keep agent for multi-turn across reconnects of same session_id;
            # explicit dispose or server shutdown cleans up.
            pass

    from contextlib import asynccontextmanager

    @asynccontextmanager
    async def lifespan(_app: Any):
        yield
        await store.close_all()

    app = Starlette(
        routes=[
            Route("/health", health),
            Route("/", index),
            Route("/p/{name:path}", page),
            Route("/ask/{name}", ask_asset),
            Route("/api/session", session_info),
            Route("/api/models", models_endpoint),
            WebSocketRoute("/api/chat", chat_ws),
        ],
        lifespan=lifespan,
    )
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["*"],
        allow_credentials=False,
    )
    # Stash for tests / CLI
    app.state.archive = archive
    app.state.store = store
    app.state.model = model
    return app


def _list_pages(archive: Path) -> list[Path]:
    if not archive.is_dir():
        return []
    pages = [
        p
        for p in archive.iterdir()
        if p.is_file() and p.suffix == ".html" and "explanation" in p.name.lower()
    ]
    return sorted(pages, key=lambda p: p.stat().st_mtime, reverse=True)


def html_escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def resolve_python() -> Path:
    """Prefer project venv, else current interpreter."""
    repo = REPO_ROOT
    for candidate in (
        repo / ".venv" / "bin" / "python",
        repo / ".venv" / "bin" / "python3",
    ):
        if candidate.is_file():
            return candidate
    return Path(sys.executable)


def main(argv: list[str] | None = None) -> int:
    load_dotenv()

    parser = argparse.ArgumentParser(description="explain-diff Ask sidecar server")
    parser.add_argument(
        "--host",
        default=os.environ.get("EXPLAIN_DIFF_HOST", DEFAULT_HOST),
        help="Bind host (default 127.0.0.1)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("EXPLAIN_DIFF_PORT", DEFAULT_PORT)),
        help=f"Bind port (default {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--archive",
        type=Path,
        default=Path(
            os.environ.get(
                "EXPLAIN_DIFF_DIR",
                str(Path.home() / ".local" / "share" / "explain-diff"),
            )
        ),
        help="Archive directory of HTML pages",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("EXPLAIN_DIFF_MODEL", DEFAULT_MODEL),
        help=f"Cursor model id (default {DEFAULT_MODEL}; grok uses high+fast)",
    )
    args = parser.parse_args(argv)

    if args.host not in ("127.0.0.1", "localhost", "::1"):
        print(
            "error: refuse to bind non-localhost host "
            f"{args.host!r} (set EXPLAIN_DIFF_HOST=127.0.0.1)",
            file=sys.stderr,
        )
        return 2

    args.archive.mkdir(parents=True, exist_ok=True)

    try:
        import uvicorn
    except ImportError:
        print(
            f"error: uvicorn/starlette missing — pip install -r {ASK_DIR / 'requirements.txt'}",
            file=sys.stderr,
        )
        return 1

    has_key = bool(_api_key())
    has_sdk = _sdk_available()
    ollama_models: list[dict[str, Any]] = []
    try:
        ollama_models = asyncio.run(ollama_backend.list_models())
    except Exception:
        ollama_models = []

    if has_key and not has_sdk:
        print(
            "warning: CURSOR_API_KEY is set but cursor-sdk is missing — "
            f"pip install -r {ASK_DIR / 'requirements.txt'}",
            file=sys.stderr,
        )
    elif not has_key and ollama_models:
        print(
            "info: CURSOR_API_KEY unset — Cursor harness off; "
            f"Ask will use Ollama ({len(ollama_models)} local model"
            f"{'' if len(ollama_models) == 1 else 's'})",
            file=sys.stderr,
        )
    elif not has_key and not ollama_models:
        print(
            "warning: no chat backend — set CURSOR_API_KEY or start Ollama. "
            "Pages still serve without Ask.",
            file=sys.stderr,
        )

    model = resolve_cursor_model(args.model)
    app = create_app(args.archive, model)
    url = f"http://{args.host}:{args.port}/"
    print(url, flush=True)
    print(f"archive: {args.archive.resolve()}", flush=True)
    backends: list[str] = []
    if has_key and has_sdk and model is not None:
        backends.append(
            "cursor:"
            + str(model.id)
            + "".join(f" {p.id}={p.value}" for p in (model.params or ()))
        )
    for entry in ollama_models:
        backends.append(str(entry.get("key") or entry.get("id")))
    print(
        "backends: " + (" ".join(backends) if backends else "(none)"),
        flush=True,
    )
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
    return 0


if __name__ == "__main__":
    sys.exit(main())
