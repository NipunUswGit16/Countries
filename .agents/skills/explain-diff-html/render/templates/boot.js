(function () {
  try {
    var root = document.documentElement;
    var w = localStorage.getItem("explain-diff-width");
    var sb = localStorage.getItem("explain-diff-sidebar");
    var theme = localStorage.getItem("explain-diff-theme");
    if (w && /^\d+$/.test(w)) root.style.setProperty("--wrap-max", w + "px");
    if (sb === "open" || sb === "closed") root.setAttribute("data-sidebar", sb);
    if (theme === "kanagawa" || theme === "dark" || theme === "light") {
      root.setAttribute("data-theme", theme);
    }
  } catch (e) {}
})();
