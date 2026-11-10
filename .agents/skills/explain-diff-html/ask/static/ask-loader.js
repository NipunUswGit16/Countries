(function () {
  "use strict";
  if (window.__explainDiffAskLoader) return;
  window.__explainDiffAskLoader = true;
  var DEFAULT_PORT = 7432;
  var meta = {};
  try {
    var el = document.getElementById("explain-diff-meta");
    meta = el ? JSON.parse(el.textContent || "{}") : {};
  } catch (e) {}
  var port = parseInt(meta.ask_port || DEFAULT_PORT, 10) || DEFAULT_PORT;
  var bases = [];
  if (location.protocol === "http:" || location.protocol === "https:") {
    bases.push(location.origin);
  }
  bases.push("http://127.0.0.1:" + port);

  function inject(base) {
    window.__explainDiffAskBase = base;
    if (!document.querySelector('link[data-explain-diff-ask="css"]')) {
      var link = document.createElement("link");
      link.rel = "stylesheet";
      link.href = base + "/ask/ask.css";
      link.setAttribute("data-explain-diff-ask", "css");
      document.head.appendChild(link);
    }
    if (!document.querySelector('script[data-explain-diff-ask="js"]')) {
      var s = document.createElement("script");
      s.src = base + "/ask/ask.js";
      s.defer = true;
      s.setAttribute("data-explain-diff-ask", "js");
      document.head.appendChild(s);
    }
  }

  function activate(base, data) {
    window.__explainDiffAskHealth = data;
    // file:// tabs cannot host the Ask sideview reliably — bounce to sidecar.
    if (location.protocol === "file:" && meta.archive_name) {
      var target =
        base +
        "/p/" +
        encodeURIComponent(meta.archive_name) +
        "?ask=1";
      location.replace(target);
      return;
    }
    inject(base);
  }

  var i = 0;
  function next() {
    if (i >= bases.length) return;
    var base = bases[i++];
    fetch(base + "/health", { method: "GET", mode: "cors", cache: "no-store" })
      .then(function (r) {
        return r.ok ? r.json() : Promise.reject();
      })
      .then(function (data) {
        if (!data || !data.ok || data.service !== "explain-diff") return next();
        activate(base, data);
      })
      .catch(next);
  }
  next();
})();
