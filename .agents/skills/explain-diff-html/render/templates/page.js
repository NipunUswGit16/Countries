/* PRISM_BUNDLE */
(function () {
  "use strict";
  var QUIZ = {{quiz_js}};
  var WIDTH_KEY = "explain-diff-width";
  var THEME_KEY = "explain-diff-theme";
  var DEFAULT_WIDTH = 1100;
  var MIN_WIDTH = 720;
  var MAX_WIDTH = 1680;

  if (typeof Prism !== "undefined") {
    Prism.manual = true;
    Prism.highlightAll();
  }

  /* DIFF_RUNTIME */

  document.querySelectorAll("a.editor-link").forEach(function (link) {
    link.addEventListener("click", function (event) {
      event.preventDefault();
      window.location.href = link.getAttribute("href");
    });
  });

  /* CHROME_RUNTIME */

  QUIZ.forEach(function (q) {
    var card = document.querySelector('[data-quiz-id="' + q.id + '"]');
    if (!card) return;
    var feedback = card.querySelector(".quiz-feedback");
    card.querySelectorAll(".quiz-btn").forEach(function (button, oi) {
      button.addEventListener("click", function () {
        if (card.dataset.answered === "1") return;
        card.dataset.answered = "1";
        var opt = q.options[oi];
        var ok = opt.correct === "true";
        button.classList.add(ok ? "selected-correct" : "selected-wrong");
        card.querySelectorAll(".quiz-btn").forEach(function (b) { b.disabled = true; });
        if (!ok) {
          q.options.forEach(function (o, idx) {
            if (o.correct === "true") {
              card.querySelectorAll(".quiz-btn")[idx].classList.add("reveal-correct");
            }
          });
        }
        feedback.className = "quiz-feedback show " + (ok ? "ok" : "no");
        feedback.textContent = (ok ? "\u2713 " : "\u2717 ") + opt.explain + (ok ? "" : " " + opt.distractors);
      });
    });
  });

})();
