
(function () {
  "use strict";
  var UI = __DIFF_UI__;
  var NARROW = 820;

  /* Prism tokenises each column as one document so multi-line constructs stay
     correct; this splits the highlighted markup back into lines, reopening any
     tag that spans a newline. */
  function splitHighlighted(markup) {
    var tpl = document.createElement("template");
    tpl.innerHTML = markup;
    var lines = [document.createElement("span")];
    var chain = [];

    function target() {
      return chain.length ? chain[chain.length - 1] : lines[lines.length - 1];
    }
    function newLine() {
      var line = document.createElement("span");
      lines.push(line);
      var parent = line;
      var rebuilt = [];
      for (var i = 0; i < chain.length; i++) {
        var clone = chain[i].cloneNode(false);
        parent.appendChild(clone);
        parent = clone;
        rebuilt.push(clone);
      }
      chain = rebuilt;
    }
    function visit(node) {
      if (node.nodeType === 3) {
        var parts = node.data.split("\n");
        for (var i = 0; i < parts.length; i++) {
          if (i > 0) newLine();
          if (parts[i]) target().appendChild(document.createTextNode(parts[i]));
        }
        return;
      }
      if (node.nodeType !== 1) return;
      var clone = node.cloneNode(false);
      target().appendChild(clone);
      chain.push(clone);
      for (var child = node.firstChild; child; child = child.nextSibling) visit(child);
      chain.pop();
    }
    for (var n = tpl.content.firstChild; n; n = n.nextSibling) visit(n);
    for (var k = 0; k < lines.length; k++) lines[k].className = "dl";
    return lines;
  }

  /* Wrap character ranges (plain-text coordinates) that changed within a line,
     on top of whatever syntax spans Prism already produced. */
  function markRanges(el, ranges) {
    if (!ranges || !ranges.length) return;
    var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
    var nodes = [];
    var node;
    while ((node = walker.nextNode())) nodes.push(node);
    var offset = 0;
    for (var i = 0; i < nodes.length; i++) {
      var tn = nodes[i];
      var start = offset;
      var end = offset + tn.data.length;
      offset = end;
      var cuts = [];
      for (var r = 0; r < ranges.length; r++) {
        var s = Math.max(ranges[r][0], start);
        var e = Math.min(ranges[r][1], end);
        if (e > s) cuts.push([s - start, e - start]);
      }
      if (!cuts.length) continue;
      var frag = document.createDocumentFragment();
      var pos = 0;
      for (var c = 0; c < cuts.length; c++) {
        if (cuts[c][0] > pos) {
          frag.appendChild(document.createTextNode(tn.data.slice(pos, cuts[c][0])));
        }
        var mark = document.createElement("span");
        mark.className = "dw";
        mark.textContent = tn.data.slice(cuts[c][0], cuts[c][1]);
        frag.appendChild(mark);
        pos = cuts[c][1];
      }
      if (pos < tn.data.length) {
        frag.appendChild(document.createTextNode(tn.data.slice(pos)));
      }
      tn.parentNode.replaceChild(frag, tn);
    }
  }

  function highlightLines(text, language) {
    if (text === "") return [];
    var grammar = null;
    if (typeof Prism !== "undefined" && language && Prism.languages[language]) {
      grammar = Prism.languages[language];
    }
    if (!grammar) {
      return text.split("\n").map(function (raw) {
        var span = document.createElement("span");
        span.className = "dl";
        span.textContent = raw;
        return span;
      });
    }
    return splitHighlighted(Prism.highlight(text, grammar, language));
  }

  function cell(cls, lineEl, ranges) {
    var div = document.createElement("div");
    div.className = cls;
    if (lineEl) {
      var clone = lineEl.cloneNode(true);
      markRanges(clone, ranges);
      div.appendChild(clone);
    }
    return div;
  }

  function num(cls, value) {
    var div = document.createElement("div");
    div.className = cls;
    div.textContent = value == null ? "" : String(value);
    return div;
  }

  function gapRow(grid, label) {
    var div = document.createElement("div");
    div.className = "dgap";
    div.textContent = "⋯ " + (label ? label : UI.gap);
    grid.appendChild(div);
  }

  function buildSplit(payload, left, right) {
    var grid = document.createElement("div");
    grid.className = "diff-grid" + (payload.mode === "split" ? "" : " single");
    var single = payload.mode !== "split";
    payload.rows.forEach(function (row) {
      if (row.t === "gap") return gapRow(grid, row.label);
      if (single) {
        var side = row.l || row.r;
        var lines = row.l ? left : right;
        var kind = row.t === "del" ? "del" : row.t === "add" ? "add" : "";
        grid.appendChild(num("dn " + kind, side.n));
        grid.appendChild(cell("dc " + kind, lines[side.i], side.w));
        return;
      }
      var lKind = row.t === "del" || row.t === "mod" ? "del" : row.t === "add" ? "empty" : "";
      var rKind = row.t === "add" || row.t === "mod" ? "add" : row.t === "del" ? "empty" : "";
      grid.appendChild(num("dn dn-l " + lKind, row.l ? row.l.n : null));
      grid.appendChild(cell("dc dc-l " + lKind, row.l ? left[row.l.i] : null, row.l && row.l.w));
      grid.appendChild(num("dn dn-r " + rKind, row.r ? row.r.n : null));
      grid.appendChild(cell("dc dc-r " + rKind, row.r ? right[row.r.i] : null, row.r && row.r.w));
    });
    return grid;
  }

  function unifiedCell(kind, sign, lineEl, ranges) {
    var div = cell("dc " + kind, lineEl, ranges);
    var marker = document.createElement("span");
    marker.className = "sign";
    marker.textContent = sign + " ";
    div.insertBefore(marker, div.firstChild);
    return div;
  }

  function buildUnified(payload, left, right) {
    var grid = document.createElement("div");
    grid.className = "diff-grid unified";
    function emitDel(side) {
      grid.appendChild(num("dn del", side.n));
      grid.appendChild(num("dn del", null));
      grid.appendChild(unifiedCell("del", "−", left[side.i], side.w));
    }
    function emitAdd(side) {
      grid.appendChild(num("dn add", null));
      grid.appendChild(num("dn add", side.n));
      grid.appendChild(unifiedCell("add", "+", right[side.i], side.w));
    }
    payload.rows.forEach(function (row) {
      if (row.t === "gap") return gapRow(grid, row.label);
      if (row.t === "ctx") {
        grid.appendChild(num("dn", row.l.n));
        grid.appendChild(num("dn", row.r.n));
        grid.appendChild(unifiedCell("", " ", left[row.l.i], null));
        return;
      }
      if (row.t === "del") return emitDel(row.l);
      if (row.t === "add") return emitAdd(row.r);
      emitDel(row.l);
      emitAdd(row.r);
    });
    return grid;
  }

  /* "N explained" chip filters the list down to files that have a dedicated
     passage — the point of the highlight is finding them among a long list. */
  document.querySelectorAll("[data-cs-filter]").forEach(function (chip) {
    var panel = chip.closest(".changeset");
    if (!panel) return;
    chip.addEventListener("click", function (event) {
      event.preventDefault();
      event.stopPropagation();  // the chip lives inside <summary>
      var on = chip.getAttribute("aria-pressed") !== "true";
      chip.setAttribute("aria-pressed", on ? "true" : "false");
      panel.classList.toggle("filtered", on);
      if (on) panel.open = true;
    });
  });

  document.querySelectorAll(".diff-figure").forEach(function (figure) {
    var script = figure.querySelector("script.diff-payload");
    var mount = figure.querySelector("[data-diff-mount]");
    if (!script || !mount) return;
    var payload;
    try {
      payload = JSON.parse(script.textContent);
    } catch (err) {
      mount.textContent = "diff payload is not valid JSON";
      return;
    }

    var language = payload.language && payload.language !== "text" ? payload.language : null;
    var left = highlightLines(payload.leftText, language);
    var right = highlightLines(payload.rightText, language);
    var cache = {};

    function render(view) {
      if (!cache[view]) {
        cache[view] = view === "unified"
          ? buildUnified(payload, left, right)
          : buildSplit(payload, left, right);
      }
      mount.textContent = "";
      mount.appendChild(cache[view]);
      figure.setAttribute("data-view", view);
      figure.querySelectorAll(".diff-view-btn").forEach(function (btn) {
        btn.classList.toggle("is-on", btn.getAttribute("data-view") === view);
      });
    }

    // Two code columns are unreadable on a phone, so start unified there; an
    // explicit click still wins afterwards.
    var initial = figure.getAttribute("data-view") || "split";
    if (payload.mode === "split" && window.innerWidth < NARROW) initial = "unified";
    render(initial);

    figure.querySelectorAll(".diff-view-btn").forEach(function (btn) {
      btn.addEventListener("click", function () {
        render(btn.getAttribute("data-view"));
      });
    });
  });
})();
