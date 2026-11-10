"""Local Ollama backend for the explain-diff Ask sidecar.

The Cursor path (`serve.py`) drives a real agent: it gets a workspace, tools and
multi-step runs. Ollama here is deliberately narrower — a streaming chat over
`/api/chat` with per-session history and no tool loop, so a local model can
answer about the page text without pretending to have repo access it will not
use. Events are emitted in the same shape the browser already consumes
(incremental `assistant` / `thinking` deltas), so the UI needed no new cases.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, AsyncIterator

import repo_tools

DEFAULT_HOST = "http://127.0.0.1:11434"
LIST_TIMEOUT = 3.0
# Local generation is slow and bursty; the read timeout has to cover the gap
# between tokens, not the whole response.
CHAT_CONNECT_TIMEOUT = 10.0
CHAT_READ_TIMEOUT = 300.0
HISTORY_TURNS = 12
# A local model that keeps calling tools will happily spin; this bounds one turn.
MAX_TOOL_ITERATIONS = 6
MAX_TOOL_RESULT = 40_000

SYSTEM_PROMPT = (
    "You are answering questions about a single technical document that explains "
    "a code change. The user's question arrives with the page context they are "
    "looking at (their selection, the visible section, and page metadata), plus "
    "the full text of the document. Answer from that context first. "
    "Match the language of the question."
)

TOOLS_PROMPT = (
    " You also have read-only access to the repository the document is about, "
    "through the read_file, list_dir and grep tools. Use them when the document "
    "text is not enough — for example to quote the real implementation. You "
    "cannot modify anything. Never invent file contents: read the file instead."
)


def host() -> str:
    return (os.environ.get("OLLAMA_HOST") or DEFAULT_HOST).strip().rstrip("/")


def _label_for(tag: str, caps: list[str]) -> str:
    bits = [c for c in ("tools", "thinking", "vision") if c in caps]
    return f"{tag} · local" + (" · " + "/".join(bits) if bits else "")


async def list_models() -> list[dict[str, Any]]:
    """Enumerate installed Ollama models. Returns [] when Ollama is not up.

    Never raises: the sidecar must keep serving the Cursor backend when there is
    no local Ollama, so an unreachable daemon is an empty list, not an error.
    """
    import httpx

    try:
        async with httpx.AsyncClient(timeout=LIST_TIMEOUT) as client:
            resp = await client.get(f"{host()}/api/tags")
            resp.raise_for_status()
            payload = resp.json()
    except Exception:
        return []

    out: list[dict[str, Any]] = []
    for entry in payload.get("models") or []:
        tag = entry.get("model") or entry.get("name")
        if not tag:
            continue
        caps = list(entry.get("capabilities") or [])
        out.append(
            {
                "key": f"ollama:{tag}",
                "backend": "ollama",
                "id": tag,
                "label": _label_for(tag, caps),
                "capabilities": caps,
                "tools": True,  # read-only loop implemented here
            }
        )
    out.sort(key=lambda m: m["id"])
    return out


async def ping(timeout: float = 0.4) -> bool:
    """Cheap daemon check for /health. Does not enumerate tags."""
    import httpx

    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.get(f"{host()}/api/tags")
            return resp.is_success
    except Exception:
        return False


async def available() -> bool:
    return bool(await list_models())


def build_messages(
    prompt: str,
    history: list[dict[str, str]],
    document: str = "",
    tools: bool = False,
) -> list[dict[str, str]]:
    """System (+ the article) + trimmed history + the new turn.

    The article rides as a system message rebuilt on every call rather than
    being folded into the first user turn: `history` stores bare questions and
    answers, so a once-only injection would fall out of the window as soon as
    the conversation moved on — the model would answer turn 2 without the
    document it had for turn 1.
    """
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT + (TOOLS_PROMPT if tools else "")}
    ]
    if document:
        messages.append(
            {
                "role": "system",
                "content": "Full text of the document under discussion:\n<<<\n"
                + document
                + "\n>>>",
            }
        )
    messages.extend(history[-HISTORY_TURNS:])
    messages.append({"role": "user", "content": prompt})
    return messages


async def _stream_once(
    client: Any,
    model_id: str,
    messages: list[dict[str, Any]],
    tools: list[dict[str, Any]] | None,
) -> AsyncIterator[dict[str, Any]]:
    """One /api/chat round trip. Yields display events plus a final `_done`
    record carrying the accumulated assistant text and any tool calls."""
    body: dict[str, Any] = {"model": model_id, "messages": messages, "stream": True}
    if tools:
        body["tools"] = tools

    text_parts: list[str] = []
    tool_calls: list[dict[str, Any]] = []
    usage: dict[str, Any] | None = None

    async with client.stream("POST", f"{host()}/api/chat", json=body) as resp:
        if resp.status_code >= 400:
            detail = (await resp.aread()).decode("utf-8", "replace")[:400]
            raise RuntimeError(f"ollama {resp.status_code}: {detail}")
        async for line in resp.aiter_lines():
            line = line.strip()
            if not line:
                continue
            try:
                chunk = json.loads(line)
            except json.JSONDecodeError:
                continue
            if chunk.get("error"):
                raise RuntimeError(f"ollama: {chunk['error']}")

            message = chunk.get("message") or {}
            thinking = message.get("thinking")
            if thinking:
                yield {"type": "thinking", "text": thinking}
            content = message.get("content")
            if content:
                text_parts.append(content)
                yield {"type": "assistant", "text": content}
            for call in message.get("tool_calls") or []:
                tool_calls.append(call)

            if chunk.get("done"):
                prompt_n = chunk.get("prompt_eval_count")
                out_n = chunk.get("eval_count")
                if prompt_n is not None or out_n is not None:
                    usage = {
                        "input_tokens": prompt_n,
                        "output_tokens": out_n,
                        "total_tokens": (prompt_n or 0) + (out_n or 0),
                    }
                break

    yield {
        "type": "_done",
        "text": "".join(text_parts),
        "tool_calls": tool_calls,
        "usage": usage,
    }


async def stream_chat(
    model_id: str,
    messages: list[dict[str, Any]],
    repo_root: Path | None = None,
) -> AsyncIterator[dict[str, Any]]:
    """Stream a turn, running the read-only tool loop when `repo_root` is set.

    Ollama reports the tool calls a model wants but never executes them — it is
    an inference server, not an agent harness. So the loop lives here: stream,
    run whatever was requested against the sandbox, feed the results back, and
    stream again until the model answers without asking for more.
    """
    import httpx

    tools = repo_tools.TOOL_SCHEMA if repo_root is not None else None
    timeout = httpx.Timeout(CHAT_READ_TIMEOUT, connect=CHAT_CONNECT_TIMEOUT)
    convo = list(messages)

    async with httpx.AsyncClient(timeout=timeout) as client:
        for iteration in range(MAX_TOOL_ITERATIONS):
            done: dict[str, Any] | None = None
            async for event in _stream_once(client, model_id, convo, tools):
                if event.get("type") == "_done":
                    done = event
                    continue
                yield event
            if done is None:
                return

            calls = done.get("tool_calls") or []
            if not calls or repo_root is None:
                if done.get("usage"):
                    yield {"type": "usage", "usage": done["usage"]}
                return

            # Last iteration: stop asking for tools and let it answer.
            if iteration == MAX_TOOL_ITERATIONS - 1:
                tools = None

            convo.append(
                {
                    "role": "assistant",
                    "content": done.get("text") or "",
                    "tool_calls": calls,
                }
            )
            for call in calls:
                fn = call.get("function") or {}
                name = str(fn.get("name") or "")
                args = fn.get("arguments")
                if isinstance(args, str):
                    try:
                        args = json.loads(args)
                    except json.JSONDecodeError:
                        args = {}
                args = args or {}
                yield {
                    "type": "tool_call",
                    "id": str(call.get("id") or name),
                    "name": name,
                    "status": "running",
                    "args": args,
                }
                result = repo_tools.run_tool(repo_root, name, args)
                yield {
                    "type": "tool_call",
                    "id": str(call.get("id") or name),
                    "name": name,
                    "status": "error" if result.startswith("error:") else "done",
                    "args": args,
                }
                convo.append(
                    {"role": "tool", "tool_name": name, "content": result[:MAX_TOOL_RESULT]}
                )
