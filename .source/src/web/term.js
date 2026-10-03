/* Selkies Forge - a small but real terminal.
 *
 * Grid based, so cursor moves, line erases, colours and the alternate screen
 * all behave: `docker pull` output, vim and htop all render correctly.
 * Repaints are coalesced into one rAF per frame, which keeps it cheap on a Pi.
 */
(function () {
  "use strict";

  var PAL = [
    "#1b2130", "#ff6b7e", "#3ddc97", "#ffc24d", "#5aa6ff", "#b88dff", "#49d6e0", "#cfe0f5",
    "#4a5771", "#ff9aa7", "#7ae2b0", "#ffd79a", "#8ec5ff", "#cbb8ff", "#8ee9f0", "#ffffff"
  ];

  function xterm256(n) {
    if (n < 16) return PAL[n];
    if (n < 232) {
      n -= 16;
      var r = Math.floor(n / 36), g = Math.floor((n % 36) / 6), b = n % 6;
      var f = function (v) { return v === 0 ? 0 : 55 + v * 40; };
      return "rgb(" + f(r) + "," + f(g) + "," + f(b) + ")";
    }
    var v = 8 + (n - 232) * 10;
    return "rgb(" + v + "," + v + "," + v + ")";
  }

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function Cell() { this.c = " "; this.f = null; this.b = null; this.bo = false; this.un = false; }

  function Term(el, opts) {
    opts = opts || {};
    this.el = el;
    this.cols = opts.cols || 100;
    this.rows = opts.rows || 28;
    this.maxScroll = opts.maxScroll || 2400;
    this.showCursor = true;
    this.cursorVisible = true;
    this.scroll = [];
    this.alt = null;
    this.state = "G";
    this.buf = "";
    this.pending = "";
    this.dirty = false;
    this.frame = null;
    this.atBottom = true;
    this.reset();
    var self = this;
    el.addEventListener("scroll", function () {
      self.atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 28;
    }, { passive: true });
  }

  Term.prototype.reset = function () {
    this.grid = [];
    for (var y = 0; y < this.rows; y++) this.grid.push(this.blankRow());
    this.x = 0;
    this.y = 0;
    this.attr = { f: null, b: null, bo: false, un: false, inv: false };
    this.scroll = [];
    this.markDirty();
  };

  Term.prototype.blankRow = function () {
    var r = [];
    for (var x = 0; x < this.cols; x++) r.push(new Cell());
    return r;
  };

  Term.prototype.resize = function (cols, rows) {
    cols = Math.max(20, Math.min(400, cols | 0));
    rows = Math.max(6, Math.min(200, rows | 0));
    if (cols === this.cols && rows === this.rows) return;
    this.cols = cols;
    this.rows = rows;
    var g = [];
    for (var y = 0; y < rows; y++) {
      var old = this.grid[y];
      var row = this.blankRow();
      if (old) for (var x = 0; x < Math.min(cols, old.length); x++) row[x] = old[x];
      g.push(row);
    }
    this.grid = g;
    this.x = Math.min(this.x, cols - 1);
    this.y = Math.min(this.y, rows - 1);
    this.markDirty();
  };

  /* ---------------------------------------------------------- log mode */
  Term.prototype.line = function (text, cls) {
    var row = [];
    var s = String(text == null ? "" : text).replace(/\t/g, "        ");
    for (var i = 0; i < s.length; i++) {
      var c = new Cell();
      c.c = s[i];
      c.cls = cls || null;
      row.push(c);
    }
    this.scroll.push(row);
    while (this.scroll.length > this.maxScroll) this.scroll.shift();
    this.markDirty();
  };

  /* ---------------------------------------------------------- tty mode */
  Term.prototype.write = function (data) {
    this.pending += data;
    if (this.pending.length > 400000) {
      this.pending = this.pending.slice(-200000);
    }
    this.parse();
    this.markDirty();
  };

  Term.prototype.parse = function () {
    var s = this.pending;
    this.pending = "";
    for (var i = 0; i < s.length; i++) {
      var ch = s[i];
      if (this.state === "G") {
        if (ch === "\x1b") { this.state = "E"; this.buf = ""; continue; }
        this.put(ch);
      } else if (this.state === "E") {
        if (ch === "[") { this.state = "C"; this.buf = ""; }
        else if (ch === "]") { this.state = "O"; this.buf = ""; }
        else if (ch === "(" || ch === ")" || ch === "#" || ch === "%") { this.state = "X"; }
        else if (ch === "M") { this.revIndex(); this.state = "G"; }
        else if (ch === "7" || ch === "8" || ch === "=" || ch === ">") { this.state = "G"; }
        else if (ch === "c") { this.reset(); this.state = "G"; }
        else { this.state = "G"; }
      } else if (this.state === "X") {
        this.state = "G";
      } else if (this.state === "C") {
        if (ch >= "@" && ch <= "~") { this.csi(ch, this.buf); this.state = "G"; this.buf = ""; }
        else { this.buf += ch; if (this.buf.length > 48) { this.state = "G"; this.buf = ""; } }
      } else if (this.state === "O") {
        if (ch === "\x07") { this.state = "G"; this.buf = ""; }
        else if (ch === "\x1b") { this.state = "OE"; }
        else { this.buf += ch; if (this.buf.length > 512) { this.state = "G"; this.buf = ""; } }
      } else if (this.state === "OE") {
        this.state = "G";
        this.buf = "";
      }
    }
  };

  Term.prototype.put = function (ch) {
    var code = ch.charCodeAt(0);
    if (ch === "\n") { this.nextLine(); return; }
    if (ch === "\r") { this.x = 0; return; }
    if (ch === "\b") { this.x = Math.max(0, this.x - 1); return; }
    if (ch === "\t") {
      var n = 8 - (this.x % 8);
      for (var i = 0; i < n && this.x < this.cols; i++) this.put(" ");
      return;
    }
    if (code === 7) return;                       /* bell */
    if (code < 32 || code === 127) return;
    if (this.x >= this.cols) { this.x = 0; this.nextLine(); }
    var cell = this.grid[this.y][this.x];
    cell.c = ch;
    cell.cls = null;
    if (this.attr.inv) { cell.f = this.attr.b || "#04070e"; cell.b = this.attr.f || "#cfe0f5"; }
    else { cell.f = this.attr.f; cell.b = this.attr.b; }
    cell.bo = this.attr.bo;
    cell.un = this.attr.un;
    this.x++;
  };

  Term.prototype.nextLine = function () {
    this.x = 0;
    this.y++;
    if (this.y >= this.rows) {
      this.y = this.rows - 1;
      if (!this.alt) {
        this.scroll.push(this.grid.shift());
        while (this.scroll.length > this.maxScroll) this.scroll.shift();
      } else {
        this.grid.shift();
      }
      this.grid.push(this.blankRow());
    }
  };

  Term.prototype.revIndex = function () {
    this.y--;
    if (this.y < 0) { this.y = 0; this.grid.pop(); this.grid.unshift(this.blankRow()); }
  };

  Term.prototype.csi = function (fin, raw) {
    var priv = raw[0] === "?";
    var body = priv ? raw.slice(1) : raw;
    var ps = body.split(";").map(function (v) { return v === "" ? null : parseInt(v, 10); });
    var p0 = ps[0] == null ? null : ps[0];
    var n = p0 == null ? 1 : Math.max(1, p0);

    if (priv) {
      var on = fin === "h";
      if (p0 === 1049 || p0 === 1047 || p0 === 47) {
        if (on && !this.alt) {
          this.alt = { grid: this.grid, x: this.x, y: this.y };
          this.grid = [];
          for (var i = 0; i < this.rows; i++) this.grid.push(this.blankRow());
          this.x = this.y = 0;
        } else if (!on && this.alt) {
          this.grid = this.alt.grid;
          this.x = this.alt.x;
          this.y = this.alt.y;
          this.alt = null;
        }
      } else if (p0 === 25) {
        this.cursorVisible = on;
      }
      return;
    }

    switch (fin) {
      case "A": this.y = Math.max(0, this.y - n); break;
      case "B": this.y = Math.min(this.rows - 1, this.y + n); break;
      case "C": this.x = Math.min(this.cols - 1, this.x + n); break;
      case "D": this.x = Math.max(0, this.x - n); break;
      case "E": this.y = Math.min(this.rows - 1, this.y + n); this.x = 0; break;
      case "F": this.y = Math.max(0, this.y - n); this.x = 0; break;
      case "G": case "`": this.x = Math.min(this.cols - 1, Math.max(0, n - 1)); break;
      case "d": this.y = Math.min(this.rows - 1, Math.max(0, n - 1)); break;
      case "H": case "f":
        this.y = Math.min(this.rows - 1, Math.max(0, (ps[0] || 1) - 1));
        this.x = Math.min(this.cols - 1, Math.max(0, (ps[1] || 1) - 1));
        break;
      case "J": this.eraseDisplay(p0 || 0); break;
      case "K": this.eraseLine(p0 || 0); break;
      case "L": this.insertLines(n); break;
      case "M": this.deleteLines(n); break;
      case "P": this.deleteChars(n); break;
      case "X": this.eraseChars(n); break;
      case "@": this.insertChars(n); break;
      case "m": this.sgr(ps); break;
      case "s": this.saved = { x: this.x, y: this.y }; break;
      case "u": if (this.saved) { this.x = this.saved.x; this.y = this.saved.y; } break;
      default: break;
    }
  };

  Term.prototype.blank = function (row, from, to) {
    for (var x = from; x < to && x < this.cols; x++) row[x] = new Cell();
  };

  Term.prototype.eraseLine = function (mode) {
    var row = this.grid[this.y];
    if (mode === 0) this.blank(row, this.x, this.cols);
    else if (mode === 1) this.blank(row, 0, this.x + 1);
    else this.blank(row, 0, this.cols);
  };

  Term.prototype.eraseDisplay = function (mode) {
    if (mode === 0) {
      this.eraseLine(0);
      for (var y = this.y + 1; y < this.rows; y++) this.grid[y] = this.blankRow();
    } else if (mode === 1) {
      this.eraseLine(1);
      for (var y2 = 0; y2 < this.y; y2++) this.grid[y2] = this.blankRow();
    } else {
      for (var y3 = 0; y3 < this.rows; y3++) this.grid[y3] = this.blankRow();
      if (mode === 3) this.scroll = [];
    }
  };

  Term.prototype.insertLines = function (n) {
    for (var i = 0; i < n; i++) { this.grid.splice(this.y, 0, this.blankRow()); this.grid.pop(); }
  };

  Term.prototype.deleteLines = function (n) {
    for (var i = 0; i < n; i++) { this.grid.splice(this.y, 1); this.grid.push(this.blankRow()); }
  };

  Term.prototype.deleteChars = function (n) {
    var row = this.grid[this.y];
    for (var i = 0; i < n; i++) { row.splice(this.x, 1); row.push(new Cell()); }
  };

  Term.prototype.insertChars = function (n) {
    var row = this.grid[this.y];
    for (var i = 0; i < n; i++) { row.splice(this.x, 0, new Cell()); row.pop(); }
  };

  Term.prototype.eraseChars = function (n) {
    this.blank(this.grid[this.y], this.x, this.x + n);
  };

  Term.prototype.sgr = function (ps) {
    if (!ps.length || (ps.length === 1 && ps[0] == null)) ps = [0];
    for (var i = 0; i < ps.length; i++) {
      var p = ps[i] == null ? 0 : ps[i];
      if (p === 0) this.attr = { f: null, b: null, bo: false, un: false, inv: false };
      else if (p === 1) this.attr.bo = true;
      else if (p === 2 || p === 22) this.attr.bo = false;
      else if (p === 4) this.attr.un = true;
      else if (p === 24) this.attr.un = false;
      else if (p === 7) this.attr.inv = true;
      else if (p === 27) this.attr.inv = false;
      else if (p >= 30 && p <= 37) this.attr.f = PAL[p - 30];
      else if (p === 39) this.attr.f = null;
      else if (p >= 40 && p <= 47) this.attr.b = PAL[p - 40];
      else if (p === 49) this.attr.b = null;
      else if (p >= 90 && p <= 97) this.attr.f = PAL[p - 90 + 8];
      else if (p >= 100 && p <= 107) this.attr.b = PAL[p - 100 + 8];
      else if (p === 38 || p === 48) {
        var isFg = p === 38;
        if (ps[i + 1] === 5) { var c = ps[i + 2] || 0; this.attr[isFg ? "f" : "b"] = xterm256(c); i += 2; }
        else if (ps[i + 1] === 2) {
          var col = "rgb(" + (ps[i + 2] || 0) + "," + (ps[i + 3] || 0) + "," + (ps[i + 4] || 0) + ")";
          this.attr[isFg ? "f" : "b"] = col;
          i += 4;
        }
      }
    }
  };

  /* ----------------------------------------------------------- painting */
  Term.prototype.markDirty = function () {
    if (this.dirty) return;
    this.dirty = true;
    var self = this;
    this.frame = requestAnimationFrame(function () { self.render(); });
  };

  Term.prototype.rowHtml = function (row, cursorX) {
    var out = "";
    var run = "";
    var key = null;
    var lastTrim = row.length;
    while (lastTrim > 0 && row[lastTrim - 1].c === " " && !row[lastTrim - 1].b) lastTrim--;
    if (cursorX != null) lastTrim = Math.max(lastTrim, cursorX + 1);

    function styleKey(c, isCur) {
      if (isCur) return "CUR";
      if (c.cls) return "L" + c.cls;
      if (!c.f && !c.b && !c.bo && !c.un) return "";
      return (c.f || "-") + "|" + (c.b || "-") + "|" + (c.bo ? 1 : 0) + "|" + (c.un ? 1 : 0);
    }

    function open(k, c) {
      if (k === "") return "";
      if (k === "CUR") return '<span class="cur">';
      if (k.charAt(0) === "L") return '<span class="' + k.slice(1) + '">';
      var st = "";
      if (c.f) st += "color:" + c.f + ";";
      if (c.b) st += "background:" + c.b + ";";
      if (c.bo) st += "font-weight:700;";
      if (c.un) st += "text-decoration:underline;";
      return '<span style="' + st + '">';
    }

    var curCell = null;
    for (var x = 0; x < lastTrim; x++) {
      var c = row[x];
      var isCur = cursorX === x;
      var k = styleKey(c, isCur);
      if (k !== key) {
        if (key !== null && key !== "") out += "</span>";
        out += open(k, c);
        key = k;
        curCell = c;
      }
      out += esc(c.c === "" ? " " : c.c);
    }
    if (key !== null && key !== "") out += "</span>";
    return out;
  };

  Term.prototype.render = function () {
    this.dirty = false;
    var parts = [];
    var sb = this.scroll;
    var start = Math.max(0, sb.length - this.maxScroll);
    for (var i = start; i < sb.length; i++) parts.push(this.rowHtml(sb[i], null));
    var showCur = this.showCursor && this.cursorVisible;
    for (var y = 0; y < this.grid.length; y++) {
      parts.push(this.rowHtml(this.grid[y], showCur && y === this.y ? this.x : null));
    }
    /* Trim trailing blank grid rows so the log view doesn't float in space. */
    while (parts.length && parts[parts.length - 1] === "" && this.gridOnlyTrailing) parts.pop();
    this.el.innerHTML = parts.join("\n");
    if (this.atBottom) this.el.scrollTop = this.el.scrollHeight;
  };

  Term.prototype.measure = function () {
    var probe = document.createElement("span");
    probe.textContent = "0123456789";
    probe.style.cssText = "position:absolute;visibility:hidden;white-space:pre;font:inherit";
    this.el.appendChild(probe);
    var w = probe.getBoundingClientRect().width / 10;
    var h = probe.getBoundingClientRect().height * 1.42;
    this.el.removeChild(probe);
    return { w: w || 7.2, h: h || 17 };
  };

  Term.prototype.fit = function () {
    var m = this.measure();
    var cols = Math.max(24, Math.floor((this.el.clientWidth - 26) / m.w));
    var rows = Math.max(8, Math.floor((this.el.clientHeight - 22) / m.h));
    this.resize(cols, rows);
    return { cols: this.cols, rows: this.rows };
  };

  window.ForgeTerm = Term;
})();
