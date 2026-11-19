"""Quiz shuffle + card HTML."""

from __future__ import annotations

import html
import json
import random
import secrets
from typing import Any


def balanced_option_order(num_questions: int, num_options: int, seed: int) -> list[int]:
    """Return target 0-based slot index for the correct answer per question."""
    rng = random.Random(seed)
    slots = list(range(num_options))
    rng.shuffle(slots)
    positions = [slots[i % num_options] for i in range(num_questions)]
    rng.shuffle(positions)
    return positions


def order_quiz_options(
    options: list[dict[str, Any]], target_index: int
) -> list[dict[str, Any]]:
    correct = [o for o in options if o.get("correct")]
    distractors = [o for o in options if not o.get("correct")]
    if len(correct) != 1:
        raise ValueError("each quiz question must have exactly one correct option")
    correct_opt = correct[0]
    rng = random.Random(secrets.randbits(64))
    rng.shuffle(distractors)
    target_index = max(0, min(target_index, len(distractors)))
    return distractors[:target_index] + [correct_opt] + distractors[target_index:]


def render_quiz(quiz: list[dict[str, Any]], seed: int, ui: dict[str, str]) -> tuple[str, str]:
    n = len(quiz)
    if n == 0:
        # "[]" and not "": the JS payload is `var QUIZ = {{quiz_js}};`.
        return "", "[]"
    num_options = max(len(q.get("options", [])) for q in quiz)
    positions = balanced_option_order(n, num_options, seed)
    cards: list[str] = []
    js_data: list[dict[str, Any]] = []

    for qi, question in enumerate(quiz):
        ordered = order_quiz_options(question["options"], positions[qi])
        qid = f"q{qi}"
        opts_html: list[str] = []
        opts_js: list[dict[str, str]] = []
        for oi, opt in enumerate(ordered):
            text = html.escape(opt.get("text", ""))
            opts_html.append(
                f'<li><button type="button" class="quiz-btn" data-q="{qid}" '
                f'aria-label="{html.escape(ui["option"])} {oi + 1}">{text}</button></li>'
            )
            opts_js.append({
                "correct": "true" if opt.get("correct") else "false",
                "explain": opt.get("explain", question.get("explain", "")),
                "distractors": opt.get("distractors", question.get("distractors", "")),
            })
        cards.append(
            f'<article class="quiz-card" data-quiz-id="{qid}">'
            f'<h3>{html.escape(ui["question"])} {qi + 1}</h3>'
            f'<p>{html.escape(question.get("question", ""))}</p>'
            f'<ul class="quiz-options" role="group">{"".join(opts_html)}</ul>'
            f'<div class="quiz-feedback" aria-live="polite"></div></article>'
        )
        js_data.append({"id": qid, "options": opts_js})

    return "".join(cards), json.dumps(js_data, ensure_ascii=True)
