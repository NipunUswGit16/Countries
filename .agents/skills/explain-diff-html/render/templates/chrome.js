
  var root = document.documentElement;
  var WIDTH_KEY = "explain-diff-width";
  var SIDEBAR_KEY = "explain-diff-sidebar";
  var TAB_KEY = "explain-diff-sbtab";
  var THEME_KEY_C = "explain-diff-theme";
  var THEMES = ["kanagawa", "dark", "light"];
  var MINW = 720, MAXW = 1680, DEFW = 1100;

  /* Theme */
  var picker = document.getElementById("theme-picker");
  var storedTheme = localStorage.getItem(THEME_KEY_C);
  if (THEMES.indexOf(storedTheme) >= 0) root.setAttribute("data-theme", storedTheme);
  else if (!root.getAttribute("data-theme")) root.setAttribute("data-theme", "kanagawa");
  if (picker) {
    picker.value = root.getAttribute("data-theme");
    picker.addEventListener("change", function () {
      root.setAttribute("data-theme", picker.value);
      localStorage.setItem(THEME_KEY_C, picker.value);
    });
  }

  /* Reading width — now the max-width of .main, not of the whole page. */
  var slider = document.getElementById("width-slider");
  var widthValue = document.getElementById("width-value");
  function clampWidth(n) {
    n = Math.round(Number(n) / 20) * 20;
    return n < MINW ? MINW : (n > MAXW ? MAXW : n);
  }
  function applyWidth(px, persist) {
    px = clampWidth(px);
    root.style.setProperty("--wrap-max", px + "px");
    if (slider) slider.value = String(px);
    if (widthValue) widthValue.textContent = px + "px";
    if (persist) localStorage.setItem(WIDTH_KEY, String(px));
  }
  var storedWidth = localStorage.getItem(WIDTH_KEY);
  applyWidth(storedWidth && /^\d+$/.test(storedWidth) ? storedWidth : DEFW, false);
  if (slider) {
    slider.addEventListener("input", function () { applyWidth(slider.value, true); });
  }

  /* Sidebar open/closed + tabs */
  var sidebar = document.getElementById("sidebar");
  function setSidebar(state, persist) {
    root.setAttribute("data-sidebar", state === "closed" ? "closed" : "open");
    document.querySelectorAll("[data-sb-toggle]").forEach(function (btn) {
      btn.setAttribute("aria-expanded", state === "closed" ? "false" : "true");
    });
    if (persist) localStorage.setItem(SIDEBAR_KEY, state);
  }
  function selectTab(name, persist) {
    if (!sidebar) return;
    var found = false;
    sidebar.querySelectorAll(".sb-tab").forEach(function (tab) {
      var on = tab.getAttribute("data-tab") === name;
      if (on) found = true;
      tab.classList.toggle("is-on", on);
      tab.setAttribute("aria-selected", on ? "true" : "false");
    });
    if (!found) return;
    sidebar.querySelectorAll(".sb-panel").forEach(function (panel) {
      panel.classList.toggle("is-on", panel.getAttribute("data-panel") === name);
    });
    if (persist) localStorage.setItem(TAB_KEY, name);
  }
  setSidebar(localStorage.getItem(SIDEBAR_KEY) === "closed" ? "closed" : "open", false);
  selectTab(localStorage.getItem(TAB_KEY) || "toc", false);

  document.querySelectorAll("[data-sb-toggle]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      setSidebar(root.getAttribute("data-sidebar") === "closed" ? "open" : "closed", true);
    });
  });
  if (sidebar) {
    sidebar.querySelectorAll(".sb-tab").forEach(function (tab) {
      tab.addEventListener("click", function () {
        selectTab(tab.getAttribute("data-tab"), true);
      });
    });
    // Rail buttons open the sidebar straight onto the panel they name.
    sidebar.querySelectorAll("[data-open-tab]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        selectTab(btn.getAttribute("data-open-tab"), true);
        setSidebar("open", true);
      });
    });
  }

  /* Top bar auto-hide. Ask turns .wrap into the scroll container, so listen in
     the capture phase and read whichever element actually scrolled. */
  var lastY = 0;
  var ticking = false;
  function onScrollPos(y) {
    root.setAttribute("data-scrolled", y > 80 ? "1" : "0");
    var goingDown = y > lastY + 6;
    var goingUp = y < lastY - 6;
    if (goingDown && y > 160) root.setAttribute("data-topbar-hidden", "1");
    else if (goingUp || y <= 80) root.removeAttribute("data-topbar-hidden");
    lastY = y;
  }
  window.addEventListener("scroll", function (event) {
    var target = event.target;
    var y = (!target || target === document || target === window)
      ? (window.scrollY || document.documentElement.scrollTop || 0)
      : (target.scrollTop || 0);
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () { ticking = false; onScrollPos(y); });
  }, true);
  // Reaching for the controls brings them back without scrolling.
  document.addEventListener("mousemove", function (event) {
    if (event.clientY < 70) root.removeAttribute("data-topbar-hidden");
  }, { passive: true });

  /* Scroll-spy: mark the section the reader is in. */
  var tocLinks = {};
  document.querySelectorAll(".toc-list a[href^='#']").forEach(function (a) {
    tocLinks[a.getAttribute("href").slice(1)] = a;
  });
  var spied = document.querySelectorAll("section[id]");
  if (spied.length && typeof IntersectionObserver !== "undefined") {
    var visible = {};
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        visible[entry.target.id] = entry.isIntersecting;
      });
      var current = null;
      for (var i = 0; i < spied.length; i++) {
        if (visible[spied[i].id]) { current = spied[i].id; break; }
      }
      Object.keys(tocLinks).forEach(function (id) {
        tocLinks[id].classList.toggle("is-current", id === current);
      });
    }, { rootMargin: "-15% 0px -70% 0px" });
    spied.forEach(function (section) { spy.observe(section); });
  }
