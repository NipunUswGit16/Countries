"""Load renderer templates and vendored JS for inlining."""

from __future__ import annotations

from paths import SKILL_DIR, TEMPLATES_DIR, VENDOR_DIR

PRISM_VENDOR = (
    "prism.min.js",
    "prism-go.min.js",
    "prism-yaml.min.js",
    "prism-sql.min.js",
    "prism-bash.min.js",
    "prism-json.min.js",
)
PRISM_LANG_ALIASES = {
    "postgres": "sql",
    "sh": "bash",
    "shell": "bash",
    "yml": "yaml",
    "plain": "text",
    "": "text",
    "text": "text",
}


def template(name: str) -> str:
    return (TEMPLATES_DIR / name).read_text(encoding="utf-8")


def fill(text: str, values: dict[str, str]) -> str:
    """Replace `{{key}}` tokens. Inserted values are not rescanned."""
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("{{", i):
            end = text.find("}}", i + 2)
            if end != -1:
                key = text[i + 2 : end]
                if key in values:
                    out.append(values[key])
                    i = end + 2
                    continue
        out.append(text[i])
        i += 1
    return "".join(out)


def load_prism_js() -> str:
    return "\n".join(
        (VENDOR_DIR / name).read_text(encoding="utf-8") for name in PRISM_VENDOR
    )


def prism_language(language: str) -> str | None:
    normalized = (language or "text").lower()
    mapped = PRISM_LANG_ALIASES.get(normalized, normalized)
    if mapped == "text":
        return None
    return mapped


def load_ask_loader_js() -> str:
    path = SKILL_DIR / "ask" / "static" / "ask-loader.js"
    if not path.is_file():
        return "/* ask-loader.js missing */"
    return path.read_text(encoding="utf-8")
