/* Selkies Forge - web UI. Vanilla, no build step, no CDN. */
(function () {
  "use strict";

  /* ------------------------------------------------------------- helpers */
  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  function h(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function mb(v) {
    v = Number(v || 0);
    return v >= 1024 ? (v / 1024).toFixed(v >= 10240 ? 0 : 1) + " GB" : Math.round(v) + " MB";
  }

  function bytes(v) {
    v = Number(v || 0);
    var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i === 0 ? Math.round(v) : v.toFixed(1)) + " " + u[i];
  }

  function ago(ts) {
    if (!ts) return "-";
    var s = Math.max(0, (Date.now() - new Date(ts).getTime()) / 1000);
    if (s < 60) return Math.round(s) + "s";
    if (s < 3600) return Math.round(s / 60) + "m";
    if (s < 86400) return Math.round(s / 3600) + "h";
    return Math.round(s / 86400) + "d";
  }

  function api(path, opts) {
    opts = opts || {};
    var init = { method: opts.method || "GET", headers: { "Accept": "application/json" } };
    if (opts.body !== undefined) {
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(opts.body);
      init.method = opts.method || "POST";
    }
    return fetch(path, init).then(function (r) {
      return r.text().then(function (t) {
        var j = null;
        try { j = t ? JSON.parse(t) : {}; } catch (e) { j = { error: t.slice(0, 300) }; }
        if (!r.ok) throw new Error((j && j.error) || ("HTTP " + r.status));
        return j;
      });
    });
  }

  function sse(path, handlers) {
    var url = path + (path.indexOf("?") < 0 ? "?" : "&") + "_=1";
    var es = new EventSource(url);
    Object.keys(handlers).forEach(function (k) {
      if (k === "error") return;
      es.addEventListener(k, function (ev) {
        var d = ev.data;
        try { d = JSON.parse(ev.data); } catch (e) {}
        handlers[k](d, ev);
      });
    });
    es.onerror = function () { if (handlers.error) handlers.error(); };
    return es;
  }

  function toast(title, detail, kind) {
    var box = $("#toasts");
    var el = document.createElement("div");
    el.className = "toast " + (kind || "");
    el.innerHTML = "<div><b>" + h(title) + "</b>" + (detail ? "<small>" + h(detail) + "</small>" : "") +
      '</div><button class="x" type="button" title="Dismiss">\u00d7</button>';
    el.querySelector(".x").onclick = function () { el.remove(); };
    box.appendChild(el);
    while (box.children.length > 4) box.removeChild(box.firstChild);
    setTimeout(function () {
      el.style.transition = "opacity .3s, transform .3s";
      el.style.opacity = "0";
      el.style.transform = "translateX(14px)";
      setTimeout(function () { el.remove(); }, 320);
    }, kind === "bad" ? 7000 : 4200);
  }

  function copy(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { toast("Copied", text, "ok"); },
        function () { toast("Could not copy", text); });
    } else {
      var ta = document.createElement("textarea");
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); toast("Copied", text, "ok"); } catch (e) {}
      ta.remove();
    }
  }

  var SVG = 'viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" ' +
            'stroke-linecap="round" stroke-linejoin="round"';
  var I = {
    globe: '<svg ' + SVG + '><circle cx="12" cy="12" r="9"/><path d="M3 12h18"/>' +
           '<path d="M12 3c2.5 2.6 3.8 5.6 3.8 9S14.5 18.4 12 21C9.5 18.4 8.2 15.4 8.2 12S9.5 5.6 12 3z"/></svg>',
    home: '<svg ' + SVG + '><path d="M4 11l8-7 8 7"/><path d="M6 10v9h12v-9"/></svg>',
    plus: '<svg ' + SVG + '><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M4 16V6a2 2 0 0 1 2-2h10"/><path d="M14 11v6M11 14h6"/></svg>',
    save: '<svg ' + SVG + '><path d="M12 3v12"/><path d="M7 10l5 5 5-5"/><path d="M5 21h14"/></svg>',
    lock: '<svg ' + SVG + '><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>',
    copy: '<svg ' + SVG + '><rect x="9" y="9" width="11" height="11" rx="2"/>' +
          '<path d="M5 15V5h10"/></svg>',
    open: '<svg ' + SVG + '><path d="M14 5h5v5"/><path d="M19 5l-8 8"/>' +
          '<path d="M18 14v4a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h4"/></svg>',
    play: '<svg ' + SVG + '><path d="M7 4l12 8-12 8z"/></svg>',
    stop: '<svg ' + SVG + '><rect x="6" y="6" width="12" height="12" rx="2"/></svg>',
    restart: '<svg ' + SVG + '><path d="M20 12a8 8 0 1 1-2.6-5.9"/><path d="M20 4v5h-5"/></svg>',
    term: '<svg ' + SVG + '><rect x="3" y="4" width="18" height="16" rx="2"/>' +
          '<path d="M7 9l3 3-3 3"/><path d="M13 15h4"/></svg>',
    logs: '<svg ' + SVG + '><path d="M6 3h8l4 4v14H6z"/><path d="M9 12h6M9 16h6M9 8h3"/></svg>',
    tune: '<svg ' + SVG + '><path d="M5 8h14M5 16h14"/><circle cx="10" cy="8" r="2.4"/>' +
          '<circle cx="15" cy="16" r="2.4"/></svg>',
    trash: '<svg ' + SVG + '><path d="M4 7h16"/><path d="M10 11v6M14 11v6"/>' +
           '<path d="M6 7l1 13h10l1-13"/><path d="M9 7V4h6v3"/></svg>',
    plug: '<svg ' + SVG + '><path d="M9 3v6M15 3v6"/><path d="M7 9h10v3a5 5 0 0 1-10 0z"/>' +
          '<path d="M12 17v4"/></svg>',
    unplug: '<svg ' + SVG + '><path d="M4 4l16 16"/><path d="M9 3v6M15 3v6"/>' +
            '<path d="M7 9h10v3a5 5 0 0 1-10 0z"/></svg>',
    more: '<svg ' + SVG + '><circle cx="6" cy="12" r="1.4" fill="currentColor"/>' +
          '<circle cx="12" cy="12" r="1.4" fill="currentColor"/>' +
          '<circle cx="18" cy="12" r="1.4" fill="currentColor"/></svg>',
    close: '<svg ' + SVG + '><path d="M6 6l12 12M18 6L6 18"/></svg>',
    fit: '<svg ' + SVG + '><path d="M4 9V4h5M20 15v5h-5M15 4h5v5M9 20H4v-5"/></svg>',
    upd: '<svg ' + SVG + '><path d="M12 3v12"/><path d="M7 10l5 5 5-5"/><path d="M5 21h14"/></svg>',
    eye: '<svg ' + SVG + '><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/>' +
         '<circle cx="12" cy="12" r="3"/></svg>'
  };

  function sparkline(values, color) {
    var v = (values || []).slice(-60);
    if (v.length < 2) return '<svg class="spark" viewBox="0 0 100 26" preserveAspectRatio="none"></svg>';
    var max = Math.max.apply(null, v) || 1;
    var step = 100 / (v.length - 1);
    var pts = v.map(function (y, i) {
      return (i * step).toFixed(2) + "," + (24 - (y / max) * 22).toFixed(2);
    });
    var line = "M" + pts.join(" L");
    var fill = line + " L100,26 L0,26 Z";
    var c = color || "var(--acc)";
    return '<svg class="spark" viewBox="0 0 100 26" preserveAspectRatio="none">' +
      '<path class="fill" d="' + fill + '" style="fill:rgba(90,166,255,.14)"/>' +
      '<path d="' + line + '" style="stroke:' + c + '"/></svg>';
  }

  /* --------------------------------------------------------------- state */
  var S = {
    boot: null, host: null, catalog: [], instances: [], stats: {},
    view: "browse", sel: null, plan: null, job: null, jobES: null,
    shell: null, drawerSess: null, drawerName: null, termName: null, instKey: "",
    info: null, gallery: [], shotIdx: 0,
    filters: { q: "", family: "", weight: "", kind: "", sort: "beauty" },
    smart: { taste: "balanced", purpose: "general" },
    lite: false,
    burrow: null
  };

  /* ------------------------------------------------------------ lite mode */
  function decideLite() {
    var saved = null;
    try { saved = localStorage.getItem("forge_lite"); } catch (e) {}
    if (saved !== null) return saved === "1";
    var cores = navigator.hardwareConcurrency || 4;
    var memGb = navigator.deviceMemory || 4;
    var slow = cores <= 2 || memGb <= 2 ||
      (navigator.connection && navigator.connection.saveData) ||
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    return !!slow;
  }

  function applyLite(on) {
    S.lite = !!on;
    document.documentElement.classList.toggle("lite", S.lite);
    var b = $("#liteBtn");
    if (b) b.textContent = S.lite ? "Lite mode: on" : "Lite mode: off";
    try { localStorage.setItem("forge_lite", S.lite ? "1" : "0"); } catch (e) {}
  }

  /* -------------------------------------------------------------- themes */
  // The look is a set of CSS variables (app.css); a theme swaps them through
  // html[data-theme]. "stealth" is the tunnel manager's black-and-white look.
  var THEMES = [
    { id: "forge", label: "Forge", hint: "Blue glass, the default", sw: ["#5aa6ff", "#8b7dff", "#0a1120"] },
    { id: "stealth", label: "Stealth", hint: "Black room, white light: the Burrow look", sw: ["#f1f2f3", "#101113", "#030304"] },
    { id: "daylight", label: "Daylight", hint: "Light, for bright rooms", sw: ["#2f6fe4", "#ffffff", "#e9edf4"] },
    { id: "ember", label: "Ember", hint: "Warm amber on charcoal", sw: ["#ffad42", "#ff6a3d", "#16110d"] }
  ];

  function applyTheme(id) {
    var t = THEMES.filter(function (x) { return x.id === id; })[0] || THEMES[0];
    if (t.id === "forge") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.setAttribute("data-theme", t.id);
    try { localStorage.setItem("forge_theme", t.id); } catch (e) {}
    var meta = document.querySelector('meta[name="theme-color"]');
    if (!meta) { meta = document.createElement("meta"); meta.name = "theme-color"; document.head.appendChild(meta); }
    meta.content = t.sw[2];
    var box = $("#themes");
    if (!box) return;
    box.innerHTML = THEMES.map(function (x) {
      return '<button type="button" role="radio" class="theme-sw' + (x.id === t.id ? " on" : "") + '" data-theme-id="' + x.id +
        '" aria-checked="' + (x.id === t.id) + '" title="' + h(x.label + ": " + x.hint) + '">' +
        '<i style="background:linear-gradient(135deg,' + x.sw[0] + " 0 50%," + x.sw[1] + " 50% 100%);box-shadow:0 0 0 3px " + x.sw[2] + ' inset"></i>' +
        "<span>" + h(x.label) + "</span></button>";
    }).join("");
  }

  function currentTheme() {
    try { return localStorage.getItem("forge_theme") || "forge"; } catch (e) { return "forge"; }
  }

  /* ---------------------------------------------------------------- boot */
  function boot() {
    applyLite(decideLite());
    applyTheme(currentTheme());
    return api("/api/boot").then(function (b) {
      S.boot = b;
      S.host = b.host;
      S.catalog = b.catalog;
      S.instances = b.instances || [];
      renderMeters();
      renderFilters();
      renderGrid();
      renderRail();
      renderHost();
      renderSmartControls();
      pollStats();
      setInterval(refreshInstances, 6000);
      setInterval(refreshHost, 15000);
      pollUpdate();
      pollLife();
      api("/api/burrow").then(function (b) { S.burrow = b; S.instKey = ""; if (S.view === "manager") renderManager(); }).catch(function () {});
    }).catch(function (e) {
      document.body.insertAdjacentHTML("afterbegin",
        '<div class="warnbox bad" style="margin:14px">Could not reach the forge engine: ' +
        h(e.message) + "</div>");
    });
  }

  function refreshHost() {
    return api("/api/host").then(function (hh) { S.host = hh; renderMeters(); }).catch(function () {});
  }

  /* Everything running on this machine: this UI's launches and selkies-cli's. */
  function refreshJobs() {
    return api("/api/jobs").then(function (r) {
      S.jobs = (r.jobs || []).filter(function (j) { return j.status === "running"; });
      renderJobStrip();
    }).catch(function () {});
  }
  function renderJobStrip() {
    var el = $("#jobStrip");
    if (!el) return;
    var jobs = S.jobs || [];
    el.hidden = !jobs.length;
    el.innerHTML = jobs.length ? "<b>Working</b>" + jobs.map(function (j) {
      var pct = Math.round((j.progress || 0) * 100);
      return '<div class="jrow"><span class="jt">' + h(j.title || j.kind) + "</span>" +
        '<span class="jp">' + h(j.label || j.phase || "") + (j.foreign ? " \u00b7 from the terminal" : "") + "</span>" +
        '<span class="jbar"><i style="width:' + pct + '%"></i></span><span class="jn">' + pct + "%</span>" +
        ((!j.foreign || j.owner === "cli") ? '<button class="btn sm ghost" data-jobcancel="' + h(j.id) + '">Cancel</button>' : "") +
        "</div>";
    }).join("") : "";
  }

  function refreshInstances() {
    if (S.view === "manager") refreshJobs();
    return api("/api/instances").then(function (r) {
      S.instances = r.instances || [];
      S.burrow = r.burrow || null;
      renderRail();
      if (S.view === "manager") renderManager();
    }).catch(function () {});
  }

  function pollStats() {
    api("/api/stats").then(function (r) {
      S.stats = r.stats || {};
      if (S.view === "manager") renderManager();
    }).catch(function () {}).then(function () {
      setTimeout(pollStats, S.view === "manager" ? 3000 : 9000);
    });
  }

  /* ------------------------------------------------------------- top bar */
  function renderMeters() {
    var hst = S.host || {};
    var memUsed = (hst.mem_total_mb || 0) - (hst.mem_avail_mb || 0);
    var memPct = hst.mem_total_mb ? (memUsed / hst.mem_total_mb) * 100 : 0;
    var cpuPct = hst.cpus ? Math.min(100, ((hst.load1 || 0) / hst.cpus) * 100) : 0;
    var diskPct = hst.disk_total_mb ? (1 - hst.disk_free_mb / hst.disk_total_mb) * 100 : 0;
    function m(label, value, pct) {
      var cls = pct > 90 ? "bad" : pct > 72 ? "warn" : "";
      return '<div class="meter"><b>' + h(label) + '</b><div class="v">' + h(value) +
        '</div><div class="bar ' + cls + '"><i style="width:' + pct.toFixed(1) + '%"></i></div></div>';
    }
    var pr = hst.pressure || {};
    if (pr.active && !S.pressureToast) {
      S.pressureToast = true;
      toast("The machine is low on memory", "Stop a desktop you are not using, or set one to stop when idle.", "bad");
    }
    if (!pr.active) S.pressureToast = false;
    $("#meters").innerHTML =
      m(pr.active ? "RAM LOW" : "RAM FREE", mb(hst.mem_avail_mb) + " of " + mb(hst.mem_total_mb), pr.active ? 100 : memPct) +
      m("CPU LOAD", (hst.load1 || 0).toFixed(2) + " of " + (hst.cpus || "?") + " cores", cpuPct) +
      m("DISK FREE", mb(hst.disk_free_mb), diskPct);
  }

  function renderRail() {
    var running = S.instances.filter(function (i) { return i.running; }).length;
    $("#tagInst").textContent = S.instances.length ? (running + "/" + S.instances.length) : "0";
    $("#tagCat").textContent = String(S.boot ? S.boot.counts.runnable : S.catalog.length);
  }

  /* -------------------------------------------------------------- browse */
  function runnable(e) {
    return !S.host || !S.host.arch || e.arches.indexOf(S.host.arch) >= 0;
  }

  function renderFilters() {
    var labels = (S.boot && S.boot.family_labels) || {};
    var counts = {}, total = 0;
    S.catalog.forEach(function (e) {
      if (!runnable(e)) return;
      counts[e.family] = (counts[e.family] || 0) + 1;
      total++;
    });
    var fams = Object.keys(counts).sort(function (a, b) {
      return (labels[a] || a).localeCompare(labels[b] || b);
    });
    $("#famSel").innerHTML = '<option value="">All families (' + total + ")</option>" +
      fams.map(function (f) {
        return '<option value="' + h(f) + '"' + (S.filters.family === f ? " selected" : "") +
          ">" + h(labels[f] || f) + " (" + counts[f] + ")</option>";
      }).join("");
    $$("#weightSeg button").forEach(function (b) {
      b.classList.toggle("on", b.dataset.w === S.filters.weight);
    });
    $$("#kindSeg button").forEach(function (b) {
      b.classList.toggle("on", b.dataset.kind === S.filters.kind);
    });
  }

  function filtered() {
    var f = S.filters;
    var q = f.q.trim().toLowerCase();
    var out = S.catalog.filter(function (e) {
      if (!runnable(e)) return false;
      if (f.family && e.family !== f.family) return false;
      if (f.weight && e.weight !== f.weight) return false;
      if (f.kind && e.kind !== f.kind) return false;
      if (q) {
        var hay = (e.name + " " + e.subtitle + " " + e.desc + " " + e.de_label + " " +
          e.family_label + " " + (e.tags || []).join(" ")).toLowerCase();
        if (hay.indexOf(q) < 0) return false;
      }
      return true;
    });
    var sorters = {
      beauty: function (a, b) { return b.beauty - a.beauty || a.heavy - b.heavy; },
      light: function (a, b) { return a.heavy - b.heavy || b.beauty - a.beauty; },
      fast: function (a, b) { return b.speed - a.speed || a.heavy - b.heavy; },
      small: function (a, b) { return a.dl_mb - b.dl_mb; },
      name: function (a, b) { return a.name.localeCompare(b.name); }
    };
    out.sort(sorters[f.sort] || sorters.beauty);
    return out;
  }

  function cardHtml(e) {
    var ready = e.kind === "pull";
    return '<article class="card" tabindex="0" data-id="' + h(e.id) + '">' +
      '<div class="top"><div class="logo">' + window.forgeLogo(e.family) + "</div>" +
      '<div style="min-width:0"><div class="name">' + h(e.name) + "</div>" +
      '<div class="meta">' + h(e.family_label) + " · " + h(e.de_label) + "</div></div></div>" +
      '<div class="badges">' +
      '<span class="badge ' + h(e.weight) + '">' + h(e.weight) + "</span>" +
      '<span class="badge">' + window.forgeGlyph(e.glyph) + h(e.de_label) + "</span>" +
      (ready ? '<span class="badge ready">ready</span>' : '<span class="badge">builds here</span>') +
      (e.profile === "kasm" ? '<span class="badge">kasm</span>' : "") +
      "</div>" +
      '<div class="desc">' + h(e.desc) + "</div>" +
      '<div class="beauty"><span>look</span><div class="bar"><i style="width:' + e.beauty +
      '%"></i></div><b>' + e.beauty + "</b></div>" +
      '<div class="specs">' +
      "<div><b>" + mb(e.dl_mb) + "</b><span>download</span></div>" +
      "<div><b>" + mb(e.disk_mb) + "</b><span>on disk</span></div>" +
      "<div><b>" + mb(e.ram_rec) + "</b><span>ram</span></div>" +
      "<div><b>" + e.cpu_rec + "</b><span>cores</span></div>" +
      "</div></article>";
  }

  function renderGrid() {
    var list = filtered();
    var hidden = S.catalog.filter(function (e) { return !runnable(e); }).length;
    $("#count").textContent = list.length + " shown" +
      (hidden ? " · " + hidden + " more need a different CPU" : "");
    var grid = $("#grid");
    if (!list.length) {
      grid.innerHTML = '<div class="empty" style="grid-column:1/-1"><div class="big">∅</div>' +
        "Nothing matches that. Try clearing a filter.</div>";
      return;
    }
    grid.innerHTML = list.map(cardHtml).join("");
  }

  /* --------------------------------------------------------------- smart */
  function renderSmartControls() {
    var tastes = (S.boot && S.boot.tastes) || {};
    var order = ["balanced", "beautiful", "lightest", "fastest"].filter(function (t) { return tastes[t]; });
    $("#tasteSeg").innerHTML = order.map(function (t) {
      return '<button data-taste="' + h(t) + '" title="' + h(tastes[t]) + '" class="' +
        (S.smart.taste === t ? "on" : "") + '">' + h(t.charAt(0).toUpperCase() + t.slice(1)) +
        "</button>";
    }).join("");
    $("#purposeSel").value = S.smart.purpose;
  }

  function runSmart() {
    var box = $("#smartOut");
    box.innerHTML = '<div class="skel" style="height:110px;margin-top:14px"></div>';
    api("/api/smart", { body: { taste: S.smart.taste, purpose: S.smart.purpose, limit: 3 } })
      .then(function (r) {
        if (!r.picks.length) {
          box.innerHTML = '<div class="warnbox" style="margin-top:14px">Nothing in the catalog fits ' +
            "this machine right now. Free some memory or disk and try again.</div>";
          return;
        }
        var fl = ["ram", "cpu", "disk", "beauty", "speed", "ready", "small"];
        box.innerHTML = '<p class="sub" style="margin:16px 0 10px">Weighed <b>' + r.considered +
          "</b> candidates against this machine, aiming for <b>" + h(r.taste) + "</b>.</p>" +
          '<div class="grid" style="grid-template-columns:repeat(auto-fill,minmax(280px,1fr))">' +
          r.picks.map(function (p, i) {
            var e = p.entry;
            return '<div class="pick' + (i === 0 ? " best" : "") + '">' +
              '<div class="hd"><div class="logo" style="width:38px;height:38px;border-radius:11px;' +
              'display:grid;place-items:center;border:1px solid var(--line)">' +
              window.forgeLogo(e.family) + '</div><div style="min-width:0"><b>' + h(e.name) +
              '</b><div style="font-size:11.5px;color:var(--dim-2)">' + h(e.family_label) +
              " · " + h(e.de_label) + "</div></div>" +
              '<span class="score">' + p.score.toFixed(0) + "</span></div>" +
              '<ul class="why">' + p.why.map(function (w) { return "<li>" + h(w) + "</li>"; }).join("") +
              "</ul>" +
              '<div class="factors">' + fl.map(function (k) {
                var v = (p.factors[k] || 0) * 100;
                return '<div class="factor"><span>' + k + '</span><div class="bar"><i style="width:' +
                  v.toFixed(0) + '%"></i></div><b>' + v.toFixed(0) + "</b></div>";
              }).join("") + "</div>" +
              '<div class="row" style="margin-top:4px"><button class="btn primary sm" data-use="' +
              h(e.id) + '">See details</button><button class="btn sm" data-go="' + h(e.id) +
              '">Forge it now</button></div></div>';
          }).join("") + "</div>";
      }).catch(function (e) {
        box.innerHTML = '<div class="warnbox bad" style="margin-top:14px">' + h(e.message) + "</div>";
      });
  }

  /* -------------------------------------------------------------- detail */
  function openDetail(id, autostart) {
    show("configure");
    $("#dHero").innerHTML = '<div class="skel" style="height:96px"></div>';
    $("#dGallery").hidden = true;
    ["cfgTune", "cfgAuth", "cfgOpts", "dAbout", "cfgSpecs"].forEach(function (k) {
      $("#" + k).innerHTML = '<div class="skel" style="height:120px"></div>';
    });
    $("#dDocker").hidden = true;
    $("#goBar").innerHTML = "";
    Promise.all([
      api("/api/entry/" + encodeURIComponent(id)),
      api("/api/info/" + encodeURIComponent(id)).catch(function () { return null; })
    ]).then(function (r) {
      S.sel = r[0];
      S.info = r[1] || {};
      S.plan = Object.assign({}, r[0].plan);
      renderDetail();
      if (autostart) startLaunch();
    }).catch(function (err) {
      $("#dHero").innerHTML = '<div class="warnbox bad">Could not open that entry: ' + h(err.message) + "</div>";
    });
  }

  function trimText(t, n) {
    t = String(t || "").trim();
    if (t.length <= n) return t;
    var cut = t.slice(0, n);
    var dot = cut.lastIndexOf(". ");
    return (dot > n * 0.5 ? cut.slice(0, dot + 1) : cut.replace(/\s+\S*$/, "") + "…");
  }

  function renderDetail() {
    var e = S.sel, hst = S.host, inf = S.info || {};
    var noArch = e.arches.indexOf(hst.arch) < 0;
    var kasm = e.profile === "kasm";
    var distro = inf.distro, desk = inf.desktop, base = inf.based_on;
    var curated = (e.tags || []).indexOf("curated") >= 0;
    // A curated look ("Cupertino Clean") should describe itself, not Debian.
    var aboutText = curated ? e.desc : ((distro && distro.extract) || inf.fallback || e.desc);
    var aboutLink = curated ? null : distro;

    /* -- hero */
    $("#dHero").innerHTML =
      '<div class="dhero"><div class="logo">' + window.forgeLogo(e.family) + "</div>" +
      '<div style="min-width:0"><h2>' + h(e.name) + "</h2>" +
      '<div class="tag">' + h(e.family_label) + " · " + h(e.de_label) + " · " +
      h(e.kind === "pull" ? "prebuilt image" : "built on this machine") + "</div>" +
      '<div class="badges" style="margin-top:10px">' +
      '<span class="badge ' + h(e.weight) + '">' + h(e.weight) + "</span>" +
      '<span class="badge">' + window.forgeGlyph(e.glyph) + h(e.de_label) + "</span>" +
      '<span class="badge' + (noArch ? " off" : "") + '">' + h(e.arches.join(" / ")) + "</span>" +
      (kasm ? '<span class="badge">kasm</span>' : "") + "</div>" +
      '<p class="about">' + h(trimText(aboutText, 400)) +
      (aboutLink && aboutLink.url ? ' <a href="' + h(aboutLink.url) + '" target="_blank" rel="noopener">' +
        "Read on Wikipedia ↗</a>" : "") + "</p></div>" +
      '<div class="go"><button class="btn primary" id="goBtn"' + (noArch ? " disabled" : "") +
      ">Forge " + h(e.name) + '</button><div class="sum" id="goSum"></div></div></div>' +
      (noArch ? '<div class="warnbox bad" style="margin:14px 0 0">This image has no ' + h(hst.arch) +
        " build, so it cannot run on this machine.</div>" : "");

    /* -- screenshots: first the real thing, captured by the forge running this
       exact entry; then Wikimedia's pictures of the distro and desktop in general */
    var shots = (S.boot && S.boot.shots) || {};
    var real = shots.ids && shots.ids[e.id] ? [{
      src: shots.base + e.id + ".jpg?d=" + encodeURIComponent(shots.ids[e.id].taken || ""),
      caption: "This exact desktop, running in Selkies Forge (captured " + (shots.ids[e.id].taken || "") + ")",
      about: e.name, real: true
    }] : [];
    var wiki = (inf.images || []).map(function (im) {
      return Object.assign({}, im, { caption: (im.caption || "") });
    });
    var imgs = real.concat(wiki);
    var gal = $("#dGallery");
    if (imgs.length) {
      S.gallery = imgs;
      gal.hidden = false;
      var realHtml = real.length ? '<figure class="shot real" data-shot="0"><div class="ph">' +
        '<img decoding="async" src="' + h(real[0].src) + '" alt="' + h(e.name) + '"></div>' +
        "<figcaption><b>What you get</b>" + h(real[0].caption) + "</figcaption></figure>" : "";
      gal.innerHTML = "<h3>Screenshots <span class=\"hint\">" +
        (real.length ? "a real capture of this desktop, then " : "") +
        (wiki.length ? wiki.length + " picture" + (wiki.length === 1 ? "" : "s") + " of " + h(e.de_label) +
          " from Wikimedia Commons" : "") +
        " · click to enlarge</span></h3>" + realHtml +
        (wiki.length ? (real.length ? '<div class="galsub">From Wikipedia: ' + h(e.de_label) +
          " on various systems, so themes and versions differ from this build</div>" : "") +
        '<div class="gallery">' + wiki.map(function (im, j) {
          var i = j + real.length;
          return '<figure class="shot" data-shot="' + i + '"><div class="ph">' +
            '<img loading="lazy" decoding="async" referrerpolicy="no-referrer" src="' + h(im.src) +
            '" alt="' + h(im.caption) + '"></div><figcaption><b>' +
            h(im.about || "") + "</b>" + h(im.caption) + "</figcaption></figure>";
        }).join("") + "</div>" : "") +
        '<p class="credit">Descriptions from Wikipedia and images from Wikimedia Commons, used under ' +
        "their CC licences. Open an image for its author and licence.</p>";
      $$("#dGallery img").forEach(function (img) {
        img.onload = function () { img.classList.add("ok"); };
        img.onerror = function () {
          var f = img.closest(".shot");
          if (f && f.classList.contains("real")) {
            var hint = $("#dGallery h3 .hint");
            if (hint) hint.textContent = (S.gallery.length - 1) + " pictures from Wikimedia Commons \u00b7 click to enlarge";
          }
          if (f) f.remove();
        };
        if (img.complete && img.naturalWidth) img.classList.add("ok");
      });
    } else {
      gal.hidden = true;
    }

    /* -- about the desktop + base */
    $("#dAbout").innerHTML = "<h3>About " + h(e.de_label) + "</h3>" +
      '<p class="prose">' + h(trimText((desk && desk.extract) || inf.desktop_blurb || e.desc, 560)) + "</p>" +
      (desk && desk.url ? '<a class="srclink" href="' + h(desk.url) +
        '" target="_blank" rel="noopener">Read on Wikipedia ↗</a>' : "") +
      (curated && distro && base ? sideArticle("Inspired by " + distro.title, distro) : "") +
      (curated && distro && !base ? sideArticle("Built on " + distro.title, distro) : "") +
      (base ? sideArticle("Built on " + base.title, base) : "");

    /* -- specs */
    $("#cfgSpecs").innerHTML = "<h3>At a glance</h3><dl class=\"kv\">" +
      "<dt>Download</dt><dd>" + mb(e.dl_mb) + "</dd>" +
      "<dt>On disk</dt><dd>about " + mb(e.disk_mb) + "</dd>" +
      "<dt>Idle memory</dt><dd>around " + mb(e.idle_mb) + "</dd>" +
      "<dt>Memory floor</dt><dd>" + mb(e.ram_min) + " (sweet spot " + mb(e.ram_rec) + ")</dd>" +
      "<dt>Cores wanted</dt><dd>" + e.cpu_rec + "</dd>" +
      "<dt>Weight</dt><dd>" + h(e.weight) + "</dd>" +
      "<dt>Image</dt><dd style=\"font-family:var(--mono);font-size:11.5px;word-break:break-all\">" +
      h(e.image || (e.recipe && e.recipe.image) || "-") + "</dd>" +
      (e.recipe && e.recipe.pkgs ? "<dt>Installs</dt><dd style=\"font-size:12px;color:var(--dim)\">" +
        h(e.recipe.pkgs) + "</dd>" : "") + "</dl>";

    /* -- 1 resources */
    var maxMem = Math.max(512, Math.min(hst.mem_total_mb - 256, hst.mem_avail_mb));
    var maxDisk = Math.max(20480, Math.min(hst.disk_free_mb, 400000));
    $("#cfgTune").innerHTML = '<h3><span class="num">1</span>Resources <span class="hint">' +
      mb(hst.mem_avail_mb) + " RAM free · " + hst.cpus + " cores · " +
      mb(hst.disk_free_mb) + " disk free</span></h3>" +
      slider("sMem", "Memory", 256, maxMem, 128, S.plan.memory_mb, mb, "needs at least " + mb(e.ram_min)) +
      slider("sCpu", "CPU cores", 0.5, hst.cpus, 0.5, S.plan.cpus,
        function (v) { return Number(v).toFixed(1) + " cores"; }, "wants " + e.cpu_rec) +
      slider("sShm", "Shared memory", 128, 4096, 64, S.plan.shm_mb, mb,
        "browsers inside want 512 MB or more") +
      slider("sDisk", "Storage", 5120, maxDisk, 1024, S.plan.disk_mb, mb,
        hst.quota_support ? "hard limit" : "budget, tracked") +
      (hst.quota_support ? "" : '<p class="sub" style="margin:2px 0 0;font-size:12px">' +
        h(hst.storage_driver + " on " + hst.backing_fs) + " cannot hard-cap one container's disk, " +
        "so storage is a tracked budget here rather than an enforced limit.</p>");

    /* -- 2 sign-in */
    $("#cfgAuth").innerHTML = '<h3><span class="num">2</span>Sign-in <span class="hint">' +
      (kasm ? "this image always asks for a password" : "off means anyone with the link gets straight in") +
      "</span></h3>" +
      '<label class="toggle"><input type="checkbox" id="oAuth"' + (kasm ? " checked" : "") +
      '><i></i><span>Ask for a username and password<small>' +
      (kasm ? "Kasm signs you in as kasm_user" : "basic auth in front of the desktop") +
      "</small></span></label>" +
      '<div id="authFields" style="display:' + (kasm ? "block" : "none") + ';margin-top:12px">' +
      '<label class="field"><span>Username</span><input type="text" id="oUser" value="' +
      (kasm ? "kasm_user" : "forge") + '"' + (kasm ? " disabled" : "") + "></label>" +
      '<label class="field"><span>Password</span><div class="row" style="gap:8px;flex-wrap:nowrap">' +
      '<input type="text" id="oPass" placeholder="type one, or generate" autocomplete="new-password" ' +
      'spellcheck="false"><button class="btn sm" type="button" id="genPass">Generate</button></div></label>' +
      '<p class="sub" style="margin:0;font-size:12px">It is shown again in the manager if you forget it.</p></div>';

    /* -- 3 options */
    $("#cfgOpts").innerHTML = '<h3><span class="num">3</span>Options</h3>' +
      '<label class="field"><span>Name (optional)</span><input type="text" id="oName" placeholder="' +
      h(e.id) + '"></label>' +
      toggle("oTunnel", true, "Public link through serveo",
        kasm ? "https image, so a short-lived TCP tunnel" : "an https link that works from anywhere") +
      toggle("oAuto", false, "Start with Docker",
        "off: it only runs when you start it, not after a reboot") +
      gpuField("oGpu", "auto") +
      toggle("oSeccomp", false, "Relax seccomp", "only if the desktop refuses to start; the forge tries this by itself") +
      idleField("oIdle", null) +
      (kasm ? "" : screenField("o", e.display || "fit", "auto", "1920x1080"));

    /* -- dockerfile */
    var dd = $("#dDocker");
    if (e.dockerfile) {
      dd.hidden = false;
      dd.innerHTML = '<div class="row"><h3 style="margin:0">How it is built</h3><div class="spacer"></div>' +
        '<button class="btn sm ghost" id="dfBtn">Show Dockerfile</button></div>' +
        '<pre class="code" id="dfOut" style="display:none;margin-top:12px">' + h(e.dockerfile) + "</pre>";
    } else {
      dd.hidden = true;
    }

    $("#goBar").innerHTML = '<div class="what" id="goWhat"></div>' +
      '<button class="btn sm ghost" data-back="browse">Cancel</button>' +
      '<button class="btn primary" id="goBtn2"' + (noArch ? " disabled" : "") + ">Forge it</button>";

    $$("#cfgTune input[type=range]").forEach(syncRange);
    updateGoSummary();

    $("#genPass").onclick = function () {
      var abc = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
      var buf = new Uint32Array(16), out = "";
      if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(buf);
      else for (var j = 0; j < 16; j++) buf[j] = Math.floor(Math.random() * 1e9);
      for (var i = 0; i < 16; i++) out += abc.charAt(buf[i] % abc.length);
      $("#oPass").value = out;
      $("#oAuth").checked = true;
      $("#authFields").style.display = "block";
    };
  }

  function sideArticle(title, art) {
    return '<h3 style="margin-top:20px">' + h(title) + "</h3>" +
      '<p class="prose">' + h(trimText(art.extract || "", 300)) + "</p>" +
      (art.url ? '<a class="srclink" href="' + h(art.url) + '" target="_blank" rel="noopener">' +
        "Read on Wikipedia ↗</a>" : "");
  }

  /* Screen: follow the browser window, or a fixed size scaled to fit. Desktops
     that cannot cope with the screen changing size default to fixed. On 4K
     screens the forge layer's screen guard scales "follow" for the viewer. */
  function screenField(p, preferred, cur, res) {
    var auto = "Automatic \u00b7 " + (preferred === "fixed" ? "fixed size, scaled" : "follows your window");
    var opt = function (v, t) { return '<option value="' + v + '"' + (cur === v ? " selected" : "") + ">" + t + "</option>"; };
    var ropt = function (v) { return '<option value="' + v + '"' + (res === v ? " selected" : "") + ">" + v.replace("x", " \u00d7 ") + "</option>"; };
    return '<label class="field" style="margin-top:12px"><span>Screen</span><select id="' + p + 'Display" data-pref="' + preferred + '">' +
      opt("auto", auto) + opt("fit", "Follow my browser window") + opt("fixed", "Fixed size, scaled to fit") +
      "</select></label>" +
      '<label class="field" id="' + p + 'ResWrap" style="display:' +
      ((cur === "fixed" || (cur === "auto" && preferred === "fixed")) ? "block" : "none") +
      '"><span>Fixed size</span><select id="' + p + 'Res">' +
      ["1280x720", "1366x768", "1600x900", "1920x1080", "2560x1440"].map(ropt).join("") + "</select></label>" +
      '<p class="sub" style="margin:2px 0 0;font-size:12px">' +
      (preferred === "fixed" ? "This desktop misdraws when the screen changes size under it, so it runs at a fixed size by default."
        : "Follow suits most desktops; on a 4K screen it's scaled up from a desktop about 1920 wide, so text stays readable. " +
          "Choose fixed if anything ever ends up off the edge.") + "</p>";
  }

  /* Stop when nobody's watching: the watchdog counts open tabs, and stops a
     desktop that has had none for this long. Its files are kept. */
  var IDLE_CHOICES = [["", "Forge default"], ["0", "Never"], ["30", "After 30 minutes"],
    ["60", "After 1 hour"], ["120", "After 2 hours"], ["240", "After 4 hours"]];
  /* GPU Smart Passthrough: auto checks what really works inside the image
     and falls back by itself; on forces it; off keeps the GPU out. */
  function gpuField(id, cur) {
    var g = (S.host && S.host.gpu) || {};
    var found = !!g.primary;
    var opt = function (v, t) { return '<option value="' + v + '"' + (cur === v ? " selected" : "") + ">" + t + "</option>"; };
    return '<label class="field" style="margin-top:12px"><span>GPU</span><select id="' + id + '">' +
      opt("auto", found ? "Smart · use it where it’s checked to work" : "Smart · none usable here, software") +
      opt("on", "Force on · skip the checks and fallbacks") +
      opt("off", "Off · draw and encode in software") +
      "</select></label>" +
      '<p class="sub" style="margin:2px 0 14px;font-size:12px">' + h(g.summary || "Detecting…") +
      (found ? ". Checked once inside the image; if the desktop misbehaves with it, the forge steps back to software by itself." : "") +
      "</p>";
  }

  function idleField(id, cur) {
    var v = cur === null || cur === undefined ? "" : String(cur);
    if (v && !IDLE_CHOICES.some(function (c) { return c[0] === v; })) IDLE_CHOICES.push([v, "After " + v + " minutes"]);
    return '<label class="field" style="margin-top:12px"><span>Stop when nobody\u2019s watching</span><select id="' + id + '">' +
      IDLE_CHOICES.map(function (c) {
        return '<option value="' + c[0] + '"' + (c[0] === v ? " selected" : "") + ">" + h(c[1]) + "</option>";
      }).join("") + "</select></label>" +
      '<p class="sub" style="margin:2px 0 0;font-size:12px">Frees its memory when no browser tab has it open. ' +
      "Files are kept; start it again any time. Needs the web UI running.</p>";
  }

  function slider(id, label, min, max, step, val, fmt, advice) {
    val = Math.max(min, Math.min(max, val));
    return '<div class="slider"><div class="lbl"><span>' + h(label) + ' <span class="adv">' +
      h(advice || "") + '</span></span><b id="' + id + 'V">' + fmt(val) + "</b></div>" +
      '<input type="range" id="' + id + '" min="' + min + '" max="' + max + '" step="' + step +
      '" value="' + val + '"></div>';
  }

  function toggle(id, on, label, hint) {
    return '<label class="toggle"><input type="checkbox" id="' + id + '"' + (on ? " checked" : "") +
      "><i></i><span>" + h(label) + "<small>" + h(hint) + "</small></span></label>";
  }

  function updateGoSummary() {
    if (!S.plan || !S.sel) return;
    var txt = mb(S.plan.memory_mb) + " RAM · " + Number(S.plan.cpus).toFixed(1) + " cores · " +
      mb(S.plan.shm_mb) + " shared · " + mb(S.plan.disk_mb) + " storage";
    var w = $("#goWhat");
    if (w) w.innerHTML = "<b>" + h(S.sel.name) + "</b> · " + h(txt);
    var s = $("#goSum");
    if (s) s.textContent = S.sel.kind === "pull" ? "About " + mb(S.sel.dl_mb) + " to download"
      : "Builds here · about " + mb(S.sel.dl_mb) + " to fetch";
  }

  function syncRange(r) {
    var pct = ((r.value - r.min) / (r.max - r.min)) * 100;
    r.style.setProperty("--pct", pct.toFixed(1) + "%");
  }

  /* ------------------------------------------------------------ lightbox */
  function openShot(i) {
    var list = S.gallery || [];
    if (!list.length) return;
    S.shotIdx = (i + list.length) % list.length;
    var im = list[S.shotIdx];
    $("#lbImg").src = im.src;
    $("#lbImg").alt = im.caption || "";
    $("#lbCount").textContent = (S.shotIdx + 1) + " of " + list.length + " · " + (im.about || "");
    $("#lbCap").innerHTML = h(im.caption || "") +
      (im.page ? ' · <a href="' + h(im.page) + '" target="_blank" rel="noopener">source and licence' +
        (im.license ? " (" + h(im.license) + ")" : "") + "</a>" : "");
    $("#lightbox").hidden = false;
  }

  function closeShot() { $("#lightbox").hidden = true; $("#lbImg").removeAttribute("src"); }

  /* -------------------------------------------------------------- launch */
  function startLaunch() {
    var e = S.sel;
    var opts = {
      tunnel: $("#oTunnel") ? $("#oTunnel").checked : true,
      autostart: $("#oAuto") ? $("#oAuto").checked : false,
      gpu: $("#oGpu") ? $("#oGpu").value : "auto",
      seccomp_unconfined: $("#oSeccomp") ? $("#oSeccomp").checked : false
    };
    if ($("#oDisplay")) {
      opts.display = $("#oDisplay").value;
      opts.resolution = $("#oRes").value;
    }
    if ($("#oIdle") && $("#oIdle").value !== "") opts.idle_stop = parseInt($("#oIdle").value, 10);
    var nm = $("#oName") && $("#oName").value.trim();
    if (nm) opts.name = nm;
    if ($("#oAuth") && $("#oAuth").checked) {
      opts.username = ($("#oUser").value || "forge").trim();
      opts.password = $("#oPass").value || Math.random().toString(36).slice(2, 10);
    }
    if (e.profile === "kasm" && !opts.password) opts.password = "forge";

    show("launch");
    $("#lTitle").innerHTML = '<div class="hero"><div class="logo">' + window.forgeLogo(e.family) +
      "</div><div><h2>Forging " + h(e.name) + "</h2><p>" + h(e.subtitle) +
      " &middot; " + mb(S.plan.memory_mb) + " RAM &middot; " + S.plan.cpus + " cores</p></div></div>";
    $("#lResult").innerHTML = "";
    $("#lSteps").innerHTML = "";
    setProgress(0, "starting", "Preparing");

    var termEl = $("#lTerm");
    termEl.innerHTML = "";
    S.job = null;
    var term = new window.ForgeTerm(termEl, { cols: 200, rows: 1, maxScroll: 4000 });
    term.showCursor = false;
    term.grid = [];
    term.line("selkies forge :: " + e.name, "i");
    term.line("");

    var cancelBtn = $("#lCancel");
    cancelBtn.hidden = true;
    cancelBtn.disabled = false;
    cancelBtn.textContent = "Cancel";
    api("/api/launch", { body: { id: e.id, plan: S.plan, opts: opts } }).then(function (r) {
      S.plan = r.plan;
      S.job = r.job;
      cancelBtn.hidden = false;
      cancelBtn.onclick = function () {
        if (!confirm("Stop forging " + e.name + "?\n\nWhatever is downloading or building stops, and a half-made desktop is removed.")) return;
        cancelBtn.disabled = true;
        cancelBtn.textContent = "Cancelling\u2026";
        api("/api/job/" + r.job.id + "/cancel", { body: {} }).catch(function (x) {
          toast("Could not cancel", x.message, "bad");
          cancelBtn.disabled = false;
          cancelBtn.textContent = "Cancel";
        });
      };
      if (S.jobES) S.jobES.close();
      S.jobES = sse("/api/job/" + r.job.id + "/events", {
        snapshot: function () {},
        log: function (d) {
          var line = d.data ? d.data.line : d.line;
          var stream = (d.data ? d.data.stream : d.stream) || "out";
          var cls = stream === "err" ? "e" : /^(>>|forge |host |plan |image |ports |container|desktop|tunnel|note |download|build )/.test(line) ? "i" : null;
          term.line(line, cls);
        },
        phase: function (d) {
          var p = d.data || d;
          setProgress(p.progress * 100, p.phase, p.label);
          renderSteps(p.phase);
        },
        progress: function (d) {
          var p = d.data || d;
          var extra = p.extra || {};
          var note = "";
          if (extra.bytes_total) {
            note = bytes(extra.bytes) + " of " + bytes(extra.bytes_total) +
              " (" + (extra.layers_done || 0) + "/" + (extra.layers || 0) + " layers)";
          } else if (extra.packages_total) {
            note = extra.packages + " of ~" + extra.packages_total + " packages";
          } else if (extra.waiting) {
            note = "waiting for the desktop (" + extra.waiting + ")";
          }
          setProgress(p.progress * 100, p.phase, note || p.phase);
        },
        done: function (d) {
          var res = d.data || d;
          cancelBtn.hidden = true;
          renderSteps("ready");
          setProgress(100, "ready", "Ready");
          term.line("");
          term.line(">> ready: " + (res.local_url || ""), "g");
          renderResult(res);
          refreshInstances();
          toast("Desktop is up", res.name, "ok");
        },
        error: function (d) {
          var err = d.data || d;
          cancelBtn.hidden = true;
          if (err.cancelled) {
            renderSteps("error");
            setProgress(0, "cancelled", "Cancelled");
            term.line("");
            term.line("!! cancelled: " + (err.message || ""), "e");
            $("#lResult").innerHTML = '<div class="warnbox">Cancelled. ' + h(err.message || "") + "</div>" +
              '<div class="row"><button class="btn" data-back="browse">Back to the catalog</button></div>';
            toast("Cancelled", e.name);
            return;
          }
          renderSteps("error");
          term.line("");
          term.line("!! " + (err.message || "launch failed"), "e");
          (err.hints || []).forEach(function (x) { term.line("   hint: " + x, "e"); });
          $("#lResult").innerHTML = '<div class="warnbox bad"><b>That did not work.</b><br>' +
            h(err.message) + (err.hints && err.hints.length ?
              "<ul class=\"why\">" + err.hints.map(function (x) { return "<li>" + h(x) + "</li>"; }).join("") + "</ul>" : "") +
            '</div><div class="row"><button class="btn" data-back="browse">Pick something else</button>' +
            '<button class="btn primary" id="retryBtn">Try again</button></div>';
          toast("Launch failed", err.message, "bad");
        },
        final: function () { if (S.jobES) S.jobES.close(); }
      });
    }).catch(function (err) {
      $("#lResult").innerHTML = '<div class="warnbox bad">' + h(err.message) + "</div>";
    });
  }

  var PHASES = [["resolve", "check"], ["fetch", "fetch image"], ["build", "build"],
    ["layer", "forge layer"], ["create", "start"], ["health", "handshake"],
    ["session", "desktop"], ["tunnel", "tunnel"], ["ready", "ready"]];

  function renderSteps(active) {
    var idx = PHASES.findIndex(function (p) { return p[0] === active; });
    $("#lSteps").innerHTML = PHASES.map(function (p, i) {
      var cls = active === "error" ? (i <= Math.max(0, idx) ? "bad" : "")
        : i < idx ? "done" : i === idx ? "on" : "";
      return '<div class="step ' + cls + '"><i class="dot"></i>' + h(p[1]) + "</div>";
    }).join("");
  }

  function setProgress(pct, phase, what) {
    pct = Math.max(0, Math.min(100, pct || 0));
    $("#lBar").style.width = pct.toFixed(1) + "%";
    $("#lPct").textContent = pct.toFixed(0) + "%";
    $("#lWhat").textContent = what || phase || "";
  }

  function renderResult(res) {
    var e = res.entry || S.sel;
    var rows = [];
    if (res.tunnel && res.tunnel.url) {
      rows.push(linkRow("Public link", res.tunnel.url, "hero-link",
        res.tunnel.mode === "tcp" ? "serveo TCP tunnel, anonymous tunnels expire" : "serveo https tunnel"));
    }
    rows.push(linkRow("On this machine", res.local_url, "", "no tunnel needed"));
    if (res.https_url) rows.push(linkRow("Local https", res.https_url, "", "for LAN devices"));

    var cred = res.credentials ? '<div class="warnbox"><b>Sign in with</b> ' +
      h(res.credentials.user) + " / " + h(res.credentials.password) + "</div>" : "";

    var warn = res.warning ? '<div class="warnbox bad"><b>Heads up.</b> ' + h(res.warning) +
      (res.session && res.session.log ? '<pre class="code" style="margin-top:10px;max-height:220px">' +
        h(res.session.log) + "</pre>" : "") + "</div>" : "";
    var fixed = (res.fixes && res.fixes.length) ? '<div class="warnbox"><b>Fixed on the way:</b> ' +
      h(res.fixes.map(function (f) {
        return ({ memory: "gave it more memory", shm: "more shared memory", seccomp: "relaxed seccomp",
                  slow: "waited longer for a slow first boot", restart: "restarted it once" })[f] || f;
      }).join(", ")) + ". Nothing for you to do.</div>" : "";
    var sess = res.session && res.session.wm ? '<div class="sub" style="margin:0 0 10px">' +
      h(res.session.wm) + " is up" + (res.display ? " \u00b7 screen: " + h(res.display === "fit" ?
        "follows your browser window" : res.display + ", scaled to fit") : "") + "</div>" : "";
    $("#lResult").innerHTML = '<div class="panel"><h3>' + h(e ? e.name : res.name) +
      (res.warning ? " started, with a problem" : " is running") + "</h3>" + sess + warn + fixed + cred +
      '<div class="result">' + rows.join("") + "</div>" +
      '<dl class="kv" style="margin-top:14px">' +
      "<dt>Container</dt><dd style=\"font-family:var(--mono);font-size:12px\">" + h(res.name) + "</dd>" +
      "<dt>Host ports</dt><dd>" + h((res.ports || []).join(", ")) + "</dd>" +
      "<dt>Memory cap</dt><dd>" + mb(res.plan.memory_mb) + "</dd>" +
      "<dt>CPU cap</dt><dd>" + res.plan.cpus + " cores</dd>" +
      "<dt>Shared memory</dt><dd>" + mb(res.plan.shm_mb) + "</dd>" +
      "<dt>Storage budget</dt><dd>" + mb(res.plan.disk_mb) +
      (res.quota_enforced ? " (enforced)" : " (tracked)") + "</dd>" +
      "<dt>Image</dt><dd style=\"font-family:var(--mono);font-size:11.5px;word-break:break-all\">" +
      h(res.image) + "</dd></dl>" +
      '<div class="row" style="margin-top:14px">' +
      '<a class="btn primary" href="' + h(res.local_url) + '" target="_blank" rel="noopener">Open the desktop</a>' +
      '<button class="btn" data-term="' + h(res.name) + '">' + I.term + "Open a shell</button>" +
      '<button class="btn" data-back="manager">Go to the manager</button>' +
      '<button class="btn ghost" data-back="browse">Forge another</button></div></div>';
  }

  function linkRow(what, url, cls, note) {
    if (!url) return "";
    return '<div class="link-row ' + (cls || "") + '"><span class="ico">' +
      (cls ? I.globe : I.home) + '</span><div style="min-width:0;flex:1">' +
      '<div class="what">' + h(what) + (note ? " &middot; " + h(note) : "") + "</div>" +
      '<a href="' + h(url) + '" target="_blank" rel="noopener">' + h(url) + "</a></div>" +
      '<button class="iconbtn" data-copy="' + h(url) + '" title="Copy">' + I.copy + "</button></div>";
  }

  /* ------------------------------------------------------------- manager */
  function instKey() {
    return S.instances.map(function (i) {
      var l = i.limits || {};
      return [i.name, i.running ? 1 : 0, (i.tunnel && i.tunnel.url) || "",
        (i.tunnel && i.tunnel.alive) ? 1 : 0, l.memory_mb, l.cpus, l.shm_mb, i.disk_cap_mb,
        i.autostart ? 1 : 0, i.auth ? i.auth.user : "",
        i.session ? [i.session.wm, i.session.mode, i.session.screen, i.session.viewers,
          Math.floor((i.session.idle_s || 0) / 60)].join("/") : "", i.idle_stop_min,
        (burrowFor(i) || {}).url || ""].join(":");
    }).join("|") + "|b" + (S.burrow && S.burrow.running ? 1 : 0);
  }

  function renderManager() {
    var box = $("#instList");
    if (!S.instances.length) {
      $("#instStats").innerHTML = "";
      box.innerHTML = '<div class="empty" style="grid-column:1/-1"><div class="big">\u25A6</div>' +
        "Nothing forged yet.<br>Pick a desktop in <b>Browse</b> and it shows up here.</div>";
      S.instKey = "";
      return;
    }
    var key = instKey();
    if (key !== S.instKey) {
      var keepDrawer = S.drawerName && S.instances.some(function (i) {
        return i.name === S.drawerName && i.running;
      });
      var drawerEl = keepDrawer ? $("#drawerHost") : null;
      if (drawerEl) drawerEl.remove();
      else closeDrawer();
      S.instKey = key;
      box.innerHTML = S.instances.map(mcCard).join("");
      if (drawerEl) {
        var card = document.querySelector('.mc[data-name="' + cssq(S.drawerName) + '"]');
        if (card) card.appendChild(drawerEl); else closeDrawer();
      }
    }
    paintStats();
  }

  function shortHost(url) {
    var m = String(url).match(/^https?:\/\/([^/:]+)(:\d+)?/);
    if (!m) return { head: url, tail: "" };
    var parts = m[1].split(".");
    var head = parts.shift();
    if (head.length > 10) head = head.slice(0, 8) + "\u2026";
    return { head: head, tail: "." + parts.join(".") + (m[2] || "") };
  }

  /* ------------------------------------------------------- ways to open */
  // A desktop (or an addon) can be reached up to four ways: on this machine,
  // from this network (the address this page came from), through a serveo
  // public link, and through Burrow when it is installed. The chooser lists
  // them all, with buttons to make the missing ones.
  function deskPort(i) {
    return (i.ports || {})[i.profile === "kasm" ? "6901" : "3000"] || null;
  }
  function burrowFor(i) {
    var b = S.burrow, port = deskPort(i);
    if (!b || !b.running || !port) return null;
    var mine = (b.tunnels || []).filter(function (t) { return t.targetPort === port; });
    return mine[0] || null;
  }
  function networkUrl(localUrl) {
    var host = location.hostname;
    if (!localUrl || /^(localhost|127\.0\.0\.1|\[?::1\]?)$/.test(host)) return null;
    return localUrl.replace(/^(https?:\/\/)[^/:]+/, "$1" + (host.indexOf(":") >= 0 ? "[" + host + "]" : host));
  }

  // rows: [{icon, label, sub, url, pill, pillCls, buttons: [{label, cls, icon, run}]}]
  function linkChooser(title, intro, rows) {
    var html = (intro ? '<p class="sub lk-intro">' + intro + "</p>" : "") + '<div class="lk">' + rows.map(function (r, n) {
      var acts = "";
      if (r.url) {
        acts += '<button class="iconbtn" data-copy="' + h(r.url) + '" title="Copy">' + I.copy + "</button>" +
          '<a class="btn sm primary" href="' + h(r.url) + '" target="_blank" rel="noopener">' + I.open + "Open</a>";
      }
      (r.buttons || []).forEach(function (b, k) {
        acts += '<button class="btn sm ' + (b.cls || "") + '" data-lk="' + n + ":" + k + '">' + (b.icon ? I[b.icon] : "") + h(b.label) + "</button>";
      });
      return '<div class="lk-row' + (r.url ? "" : " off") + '"><span class="lk-ic">' + I[r.icon] + "</span>" +
        '<div class="lk-t"><b>' + h(r.label) + (r.pill ? ' <span class="pill ' + (r.pillCls || "") + '"><i></i>' + h(r.pill) + "</span>" : "") +
        "</b><span" + (r.url ? ' class="mono"' : "") + ">" + h(r.url || r.sub || "") + "</span></div>" +
        '<div class="lk-acts">' + acts + "</div></div>";
    }).join("") + "</div>";
    openModal(title, html);
    Array.prototype.forEach.call(document.querySelectorAll("#modalBody [data-lk]"), function (el) {
      el.onclick = function () {
        var nk = el.dataset.lk.split(":"), b = rows[+nk[0]].buttons[+nk[1]];
        el.disabled = true;
        el.innerHTML = '<span class="spin-sm"></span>' + h(b.busy || "Working\u2026");
        Promise.resolve(b.run()).catch(function (e) {
          toast(b.label + " failed", e.message, "bad");
          el.disabled = false;
          el.textContent = b.label;
        });
      };
    });
  }

  function openDesktop(name) {
    var i = S.instances.filter(function (x) { return x.name === name; })[0];
    if (!i) return;
    var tun = (i.tunnel && i.tunnel.url) ? i.tunnel : null;
    var b = S.burrow || {};
    var bt = burrowFor(i);
    var rows = [{ icon: "home", label: "This machine", url: i.local_url }];
    var net = networkUrl(i.local_url);
    if (net) rows.push({ icon: "plug", label: "This network", url: net });
    rows.push(tun && tun.alive
      ? { icon: "globe", label: "Public link", url: tun.url, pill: "serveo", buttons: [
          { label: "Drop", cls: "ghost danger", busy: "Dropping\u2026", run: function () { closeModal(); instAction(name, "untunnel"); } }] }
      : { icon: "globe", label: "Public link", sub: tun ? "The serveo link went down." : "A random serveousercontent.com address anyone can open.",
          buttons: [{ label: tun ? "Reopen public link" : "Make a public link", icon: "plug", busy: "Opening\u2026",
                      run: function () { closeModal(); instAction(name, "tunnel"); } }] });
    if (b.installed) {
      if (!b.running) {
        rows.push({ icon: "lock", label: "Burrow", sub: "Burrow is installed but not answering" + (b.error ? ": " + b.error : "") + "." });
      } else if (bt) {
        rows.push({ icon: "lock", label: "Burrow", url: bt.url, sub: bt.url ? "" : "Getting an address\u2026",
                    pill: bt.access === "public" ? "public" : "login", pillCls: bt.access === "public" ? "" : "up",
                    buttons: [{ label: "Unpublish", cls: "ghost danger", busy: "Removing\u2026", run: function () {
                      return api("/api/burrow/unpublish", { body: { desktop: name } }).then(function (r) {
                        S.burrow = r.burrow; S.instKey = ""; renderManager(); openDesktop(name); toast("No longer published through Burrow", "", "ok");
                      });
                    } }] });
      } else {
        rows.push({ icon: "lock", label: "Burrow", sub: "Its own address (" + (b.pattern || "Burrow") + "), behind Burrow's login.",
                    buttons: [{ label: "Publish through Burrow", icon: "lock", busy: "Publishing\u2026", run: function () {
                      return api("/api/burrow/publish", { body: { desktop: name } }).then(function (r) {
                        S.burrow = r.burrow; S.instKey = ""; renderManager(); openDesktop(name);
                        toast("Published through Burrow", (r.tunnel && r.tunnel.url) || "its address is on the way", "ok");
                      });
                    } }] });
      }
    }
    linkChooser("Open " + i.title, "", rows);
  }

  function mcCard(i) {
    var running = i.running;
    var tun = (i.tunnel && i.tunnel.url) ? i.tunnel : null;
    var bt = burrowFor(i);
    var lim = i.limits || {};
    var fam = (S.boot && S.boot.family_labels && S.boot.family_labels[i.family]) || i.family;
    var rows = "";

    if (i.local_url) {
      var lp = i.local_url.replace(/^https?:\/\//, "");
      rows += arow("home", "Local", '<span>' + h(lp) + "</span>", i.local_url, i.local_url, "");
    }
    if (tun) {
      var sh = shortHost(tun.url);
      rows += arow("globe", "Public", '<span>' + h(sh.head) + '</span><span class="muted">' +
        h(sh.tail) + "</span>", tun.url, tun.url, "pub" + (tun.alive ? "" : " down"),
        tun.alive ? "" : "tunnel is down, use the menu to reopen it");
    }
    if (bt && bt.url) {
      var bh = shortHost(bt.url);
      rows += arow("lock", "Burrow", '<span>' + h(bh.head) + '</span><span class="muted">' + h(bh.tail) + "</span>",
        bt.url, bt.url, "pub", bt.access === "public" ? "published through Burrow, public" : "published through Burrow, behind its login");
    }
    if (i.auth) {
      rows += '<div class="arow"><span class="ic">' + I.lock + '</span><span class="lab">Sign-in</span>' +
        '<span class="val" data-secret="' + h(i.name) + '"><span>' + h(i.auth.user) +
        '</span><span class="muted"> / \u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022</span></span>' +
        '<div class="acts"><button class="iconbtn" data-reveal="' + h(i.name) + '" title="Show password">' +
        I.eye + '</button><button class="iconbtn" data-copy="' + h(i.auth.password) +
        '" title="Copy password">' + I.copy + "</button></div></div>";
    }

    var actions = running
      ? '<button class="btn primary" data-open="' + h(i.name) + '">' + I.open + "Open desktop</button>" +
        '<button class="btn" data-drawer="' + h(i.name) + '">' + I.term + "Shell</button>" +
        '<button class="btn" data-act="stop">' + I.stop + "Stop</button>"
      : '<button class="btn primary" data-act="start">' + I.play + "Start</button>" +
        '<button class="btn" data-tune="' + h(i.name) + '">' + I.tune + "Limits</button>" +
        '<button class="btn" data-logs="' + h(i.name) + '">' + I.logs + "Logs</button>";

    return '<article class="mc ' + (running ? "up" : "") + '" data-name="' + h(i.name) + '">' +
      '<section class="mc-head"><div class="logo">' + window.forgeLogo(i.family) + "</div>" +
        '<div style="min-width:0"><div class="nm">' + h(i.title) + "</div>" +
        '<div class="sub2">' + h(fam) + " \u00b7 " + h(i.de_label || "") + " \u00b7 " + h(i.name) + "</div></div>" +
        '<span class="pill ' + (running ? "up" : (i.exit_code ? "bad" : "")) + '"><i></i>' +
        h(running ? "Running \u00b7 " + ago(i.started_at) : cap(i.status || "stopped")) + "</span>" +
      "</section>" +
      sessionLine(i) +
      '<section class="mc-metrics">' +
        metricCell(i.name, "cpu", "CPU") + metricCell(i.name, "mem", "Memory") +
        metricCell(i.name, "net", "Network") +
      "</section>" +
      (rows ? '<section class="mc-access">' + rows + "</section>" : "") +
      '<section class="mc-limits"><div class="limits-line">' +
        lchip("RAM", lim.memory_mb ? mb(lim.memory_mb) : "no cap") +
        lchip("CPU", lim.cpus ? lim.cpus + (lim.cpus === 1 ? " core" : " cores") : "No cap") +
        lchip("Shared", lim.shm_mb ? mb(lim.shm_mb) : "64 MB") +
        lchip("Storage", i.disk_cap_mb ? mb(i.disk_cap_mb) : "\u2014") +
        lchip("Auto-start", i.autostart ? "On" : "Off", i.autostart) +
        '</div><button class="btn sm" data-tune="' + h(i.name) + '">' + I.tune + "Edit</button>" +
      "</section>" +
      '<section class="mc-actions">' + actions +
        '<div class="menu-wrap"><button class="iconbtn" data-menu="' + h(i.name) + '" title="More">' +
        I.more + '</button><div class="menu" hidden>' +
          (running ? '<button data-act="restart">' + I.restart + "Restart</button>" : "") +
          (running ? (tun ? '<button data-act="untunnel">' + I.unplug + "Drop public link</button>"
                          : '<button data-act="tunnel">' + I.plug + "Open public link</button>") : "") +
          '<button data-logs="' + h(i.name) + '">' + I.logs + "Container logs</button>" +
          (i.profile === "kasm" ? "" : '<button data-act="repair" title="Recreate it on the newest forge layer; files are kept">' +
            I.restart + "Repair</button>") +
          '<button data-tune="' + h(i.name) + '">' + I.tune + "Edit limits</button>" +
          '<button data-act="idle" title="Stop it when nobody has it open">' + I.stop + "Stop when idle\u2026</button>" +
          "<hr>" +
          '<button data-act="backup" title="Copy its files (home folder) to a backup">' + I.save + "Back up files</button>" +
          '<button data-act="backups">' + I.logs + "Backups\u2026</button>" +
          '<button data-act="clone" title="A second desktop with a copy of its files">' + I.plus + "Clone\u2026</button>" +
          "<hr>" +
          '<button class="danger" data-act="remove">' + I.trash + "Remove</button>" +
        "</div></div>" +
      "</section>" +
    "</article>";
  }

  function cap(s) { s = String(s || ""); return s.charAt(0).toUpperCase() + s.slice(1); }

  /* What the forge agent inside the desktop last reported (via the watchdog). */
  function sessionLine(i) {
    var s = i.session;
    if (!i.running || !s) return "";
    if (s.mode === "rescue") {
      return '<section class="mc-session bad">Session crashed on start; a rescue window shows why. ' +
        '<button class="btn sm" data-logs="' + h(i.name) + '">See what happened</button></section>';
    }
    var watch = "";
    if (typeof s.viewers === "number") {
      watch = s.viewers ? " \u00b7 " + s.viewers + " watching"
        : " \u00b7 unwatched" + (s.idle_s >= 120 ? " " + dur(s.idle_s) : "");
      if (!s.viewers && i.idle_stop_min) {
        var left = i.idle_stop_min * 60 - (s.idle_s || 0);
        watch += left > 0 ? ", stops in " + dur(left) : ", stopping";
      }
    }
    if (!s.wm) return watch ? '<section class="mc-session">' + h(watch.slice(3)) + "</section>" : "";
    var scr = s.screen && s.screen !== "wayland" ? s.screen.replace("x", "\u00d7") : s.screen;
    return '<section class="mc-session"><i class="ok"></i>' + h(s.wm) + " running" +
      (scr ? " \u00b7 " + h(scr) : "") + ((i.display || "").indexOf("fixed") === 0 ? " \u00b7 fixed size, scaled" : "") +
      h(watch) + "</section>";
  }
  function dur(sec) {
    sec = Math.max(0, Math.round(sec));
    if (sec < 90) return sec + "s";
    if (sec < 5400) return Math.round(sec / 60) + " min";
    return (sec / 3600).toFixed(sec < 36000 ? 1 : 0) + " h";
  }
  function catEntry(id) {
    var c = (S.boot && S.boot.catalog) || [];
    for (var k = 0; k < c.length; k++) if (c[k].id === id) return c[k];
    return null;
  }

  function arow(icon, label, valHtml, copyText, openUrl, cls, title) {
    return '<div class="arow ' + (cls || "") + '"' + (title ? ' title="' + h(title) + '"' : "") + ">" +
      '<span class="ic">' + I[icon] + '</span><span class="lab">' + h(label) + "</span>" +
      '<span class="val">' + valHtml + "</span>" +
      '<div class="acts"><button class="iconbtn" data-copy="' + h(copyText) + '" title="Copy">' + I.copy +
      '</button><a class="iconbtn" href="' + h(openUrl) + '" target="_blank" rel="noopener" title="Open">' +
      I.open + "</a></div></div>";
  }

  function lchip(k, v, on) {
    return '<span class="lchip' + (on ? " on" : "") + '"><span>' + h(k) + "</span>" + h(v) + "</span>";
  }

  function metricCell(name, kind, label) {
    var body = kind === "net"
      ? '<div class="sparkbox" data-spark="net" data-name="' + h(name) + '"></div>'
      : '<div class="bar" data-bar="' + kind + '" data-name="' + h(name) + '"><i></i></div>';
    return '<div class="m"><div class="k">' + h(label) + "</div>" +
      '<div class="v" data-metric="' + kind + '" data-name="' + h(name) + '">\u2014</div>' + body + "</div>";
  }

  /* Numbers repaint in place every few seconds; rebuilding the cards each
     time would drop an open shell and make the page crawl on a small box. */
  function paintStats() {
    var totRx = 0, totTx = 0, totMem = 0, running = 0;
    S.instances.forEach(function (i) {
      var st = S.stats[i.name] || {};
      totRx += st.rx_total || 0;
      totTx += st.tx_total || 0;
      totMem += st.mem_mb || 0;
      if (i.running) running++;
      if (!i.running) {
        set(i.name, "cpu", '<small>stopped</small>');
        set(i.name, "mem", '<small>stopped</small>');
        set(i.name, "net", '<small>stopped</small>');
        bar(i.name, "cpu", 0); bar(i.name, "mem", 0);
        return;
      }
      set(i.name, "cpu", st.cpu != null ? st.cpu.toFixed(1) + "<small> %</small>" : "\u2014");
      set(i.name, "mem", st.mem_mb != null ? Math.round(st.mem_mb) + "<small> of " +
        mb(st.mem_limit_mb || 0) + "</small>" : "\u2014");
      set(i.name, "net", bytes((st.rx_total || 0) + (st.tx_total || 0)) +
        (st.rx_rate || st.tx_rate ? "<small> \u00b7 " + bytes((st.rx_rate || 0) + (st.tx_rate || 0)) + "/s</small>" : ""));
      bar(i.name, "cpu", Math.min(100, st.cpu || 0));
      bar(i.name, "mem", st.mem_pct || 0);
      var sp = document.querySelector('[data-spark="net"][data-name="' + cssq(i.name) + '"]');
      if (sp) sp.innerHTML = sparkline(st.spark_net || []);
    });
    $("#instStats").innerHTML =
      stat("Desktops", S.instances.length, running + " running") +
      stat("Memory in use", mb(totMem), "across running desktops") +
      stat("Downloaded", bytes(totRx), "into the desktops") +
      stat("Uploaded", bytes(totTx), "out of the desktops");
  }

  function cssq(s) { return String(s).replace(/["\\]/g, "\\$&"); }

  function set(name, kind, html) {
    var el = document.querySelector('[data-metric="' + kind + '"][data-name="' + cssq(name) + '"]');
    if (el) el.innerHTML = html;
  }

  function bar(name, kind, pct) {
    var el = document.querySelector('[data-bar="' + kind + '"][data-name="' + cssq(name) + '"]');
    if (!el) return;
    el.className = "bar" + (pct > 88 ? " bad" : pct > 70 ? " warn" : "");
    el.firstChild.style.width = Math.max(0, Math.min(100, pct)).toFixed(0) + "%";
  }

  function stat(k, v, s) {
    return '<div class="stat"><div class="k">' + h(k) + '</div><div class="v">' + h(v) +
      '</div><div class="s">' + h(s) + "</div></div>";
  }

  function closeMenus(except) {
    $$(".menu").forEach(function (m) { if (m !== except) m.hidden = true; });
    $$("[data-menu]").forEach(function (b) { b.classList.remove("on"); });
    if (except) {
      var btn = except.parentNode.querySelector("[data-menu]");
      if (btn) btn.classList.add("on");
    }
  }

  /* Long jobs started from the manager (backup, restore, clone) report back
     through the job API; the Working strip shows them while they run. */
  function watchJob(id, label, onDone) {
    var tick = function () {
      api("/api/job/" + id).then(function (j) {
        if (j.status === "running") { setTimeout(tick, 1500); return; }
        if (j.status === "done") toast(label + " done", (j.result && (j.result.file || j.result.name)) || "", "ok");
        else toast(label + (j.status === "cancelled" ? " cancelled" : " failed"),
          (j.error && j.error.message) || j.status, j.status === "cancelled" ? "" : "bad");
        S.instKey = "";
        refreshInstances();
        refreshJobs();
        if (onDone) onDone(j);
      }).catch(function () { setTimeout(tick, 3000); });
    };
    setTimeout(tick, 800);
    refreshJobs();
  }

  function startJob(url, body, label, onDone) {
    toast(label + "\u2026", "");
    return api(url, { body: body || {} }).then(function (r) { watchJob(r.job.id, label, onDone); })
      .catch(function (e) { toast(label + " failed", e.message, "bad"); });
  }

  function showBackups(name) {
    openModal("Backups \u00b7 " + name, '<div class="skel" style="height:120px"></div>');
    api("/api/backups?name=" + encodeURIComponent(name)).then(function (r) {
      var rows = r.backups || [];
      $("#modalBody").innerHTML =
        '<div class="row" style="margin-bottom:12px"><p class="sub" style="margin:0;flex:1">Copies of this desktop\u2019s ' +
        "home folder (caches left out). Restoring takes a safety copy of the current files first.</p>" +
        '<button class="btn sm primary" data-bk="new">Back up now</button></div>' +
        (rows.length ? '<div class="evlist">' + rows.map(function (b) {
          return '<div class="ev"><span class="t">' + h(new Date(b.created * 1000).toLocaleString()) + "</span>" +
            "<b>" + h(mb(b.size / 1048576)) + (b.tag ? " \u00b7 " + h(b.tag) : "") + "</b>" +
            '<span class="d">' + h(b.file) + "</span>" +
            '<span class="row" style="gap:6px;margin-left:auto">' +
            '<button class="btn sm" data-bk="restore" data-file="' + h(b.file) + '">Restore</button>' +
            '<button class="btn sm ghost" data-bk="fork" data-file="' + h(b.file) + '">New desktop</button>' +
            '<button class="btn sm ghost" data-bk="del" data-file="' + h(b.file) + '">Delete</button></span></div>';
        }).join("") + "</div>" : '<div class="empty">No backups yet.</div>');
      $$("#modalBody [data-bk]").forEach(function (b) {
        b.onclick = function () {
          var f = b.dataset.file, k = b.dataset.bk;
          if (k === "new") { closeModal(); startJob("/api/instance/" + encodeURIComponent(name) + "/backup", {}, "Backup of " + name); }
          if (k === "restore" && confirm("Replace " + name + "\u2019s files with this backup?\n\n" + f +
              "\n\nA safety backup of the current files is taken first. A running desktop restarts.")) {
            closeModal(); startJob("/api/backups/restore", { name: name, file: f }, "Restore of " + name);
          }
          if (k === "fork") {
            var nn = prompt("Name for the new desktop (optional)", "");
            if (nn === null) return;
            closeModal(); startJob("/api/backups/clone", { file: f, name: nn.trim() }, "New desktop from backup");
          }
          if (k === "del" && confirm("Delete this backup for good?\n\n" + f)) {
            api("/api/backups/delete", { body: { file: f } }).then(function () { showBackups(name); })
              .catch(function (e) { toast("Delete failed", e.message, "bad"); });
          }
        };
      });
    }).catch(function (e) { $("#modalBody").innerHTML = '<div class="warnbox bad">' + h(e.message) + "</div>"; });
  }

  function instAction(name, act) {
    var body = {};
    var enc = encodeURIComponent(name);
    if (act === "backup") return startJob("/api/instance/" + enc + "/backup", {}, "Backup of " + name);
    if (act === "backups") return showBackups(name);
    if (act === "clone") {
      var nn = prompt("Clone " + name + "\n\nA second desktop with a copy of all its files, the same limits " +
        "and options. Name for the copy (optional):", "");
      if (nn === null) return;
      return startJob("/api/instance/" + enc + "/clone", { name: nn.trim() }, "Clone of " + name);
    }
    if (act === "idle") {
      var cur = (S.instances.filter(function (x) { return x.name === name; })[0] || {}).idle_stop_min || 0;
      var mins = prompt("Stop " + name + " after how many minutes with nobody watching?\n\n" +
        "0 = never. Leave empty for the forge default. Files are always kept.", cur ? String(cur) : "");
      if (mins === null) return;
      return api("/api/instance/" + enc + "/idle", { body: { minutes: mins.trim() === "" ? null : parseInt(mins, 10) || 0 } })
        .then(function (r) {
          toast("Idle stop " + (r.idle_stop_min ? "after " + r.idle_stop_min + " min" : r.idle_stop_min === 0 ? "off" : "default"), name, "ok");
          S.instKey = ""; refreshInstances();
        }).catch(function (e) { toast("Could not set it", e.message, "bad"); });
    }
    if (act === "repair" && !confirm("Repair " + name + "?\n\nIt is recreated on the newest forge layer " +
        "(first-run fixes, screen agent, crash supervisor). Your files in /config are kept; it restarts.")) return;
    if (act === "remove") {
      if (!confirm("Remove " + name + "?")) return;
      body.purge = confirm("Also delete its saved files (the /config volume)?\n\nOK deletes them, Cancel keeps them.");
    }
    var card = document.querySelector('.mc[data-name="' + cssq(name) + '"]');
    if (card) card.classList.add("busy");
    toast(cap(act) + "\u2026", name);
    api("/api/instance/" + encodeURIComponent(name) + "/" + act, { body: body })
      .then(function (r) {
        if (r.warning) toast(cap(act) + " done, with a problem", r.warning, "bad");
        else toast(cap(act) + " done", (r.tunnel && r.tunnel.url) || name, "ok");
        S.instKey = "";
        refreshInstances();
      })
      .catch(function (e) { toast(cap(act) + " failed", e.message, "bad"); })
      .then(function () { if (card) card.classList.remove("busy"); });
  }

  /* ---------------------------------------------------------------- modal */
  function openModal(title, html) {
    $("#modalTitle").textContent = title;
    $("#modalBody").innerHTML = html;
    $("#modal").style.display = "grid";
  }

  // Every close path hides first and tidies up after, so nothing that goes
  // wrong while tidying can leave a panel stuck open.
  function closeModal() {
    $("#modal").style.display = "none";
    try { $("#modalBody").innerHTML = ""; } catch (e) { console.error(e); }
  }

  function showLogs(name) {
    openModal("Logs \u00b7 " + name, '<div class="skel" style="height:200px"></div>');
    api("/api/logs/" + encodeURIComponent(name) + "?tail=400").then(function (r) {
      var evs = (r.events || []).slice().reverse();
      var EV = { create: "created", ready: "ready", crashed: "crashed", healed: "restarted after a crash",
        "heal-skipped": "crashed too often, left stopped", "session-rescue": "session crashed, rescue shown",
        stop: "stopped", start: "started", restart: "restarted", repair: "repaired", retune: "limits changed",
        recreate: "recreated", "launch-failed": "launch failed", "launch-cancelled": "launch cancelled",
        stopped: "stopped outside the forge", "session-frozen": "froze (no sign of life)",
        "idle-stop": "stopped: nobody was watching", "pressure-stop": "stopped: the machine was out of memory",
        "launch-interrupted": "launch interrupted", backup: "backed up", restored: "files restored",
        cloned: "cloned", "idle-limit": "idle stop changed", "heal-failed": "restart after a crash failed" };
      var evHtml = evs.length ? '<h3 style="margin:0 0 8px">What happened</h3><div class="evlist">' +
        evs.map(function (x) {
          var bad = /crash|fail|rescue|skipped|frozen|interrupted|pressure/.test(x.event);
          return '<div class="ev' + (bad ? " bad" : "") + '"><span class="t">' +
            h(new Date(x.ts * 1000).toLocaleString()) + '</span><b>' + h(EV[x.event] || x.event) + "</b>" +
            (x.detail && x.detail !== "requested" ? '<span class="d">' + h(x.detail) + "</span>" : "") + "</div>";
        }).join("") + '</div><h3 style="margin:16px 0 8px">Container log</h3>' : "";
      $("#modalBody").innerHTML = evHtml + '<pre class="code" style="max-height:52vh">' + h(r.logs || "(empty)") + "</pre>";
    }).catch(function (e) {
      $("#modalBody").innerHTML = '<div class="warnbox bad">' + h(e.message) + "</div>";
    });
  }

  function showTune(name) {
    var i = S.instances.filter(function (x) { return x.name === name; })[0];
    if (!i) return;
    var L = i.limits || {};
    var cur = {
      mem: L.memory_mb || 1024, cpu: L.cpus || 1, shm: L.shm_mb || 256,
      disk: i.disk_cap_mb || 10240, auto: !!i.autostart,
      display: (i.display || "").indexOf("fixed") === 0 ? "fixed" : (i.display === "fit" ? "fit" : "auto"),
      res: (i.display || "").indexOf("fixed:") === 0 ? i.display.slice(6) : ""
    };
    var maxMem = Math.max(512, S.host.mem_total_mb - 256);
    var maxDisk = Math.max(20480, Math.min(S.host.disk_free_mb, 400000));
    openModal("Limits \u00b7 " + i.title,
      '<p class="sub" style="margin-top:-4px">Memory, CPU and auto-start change instantly. ' +
      "Shared memory, storage and the screen mode need the desktop recreated; your files in /config are kept.</p>" +
      slider("tMem", "Memory", 256, maxMem, 128, cur.mem, mb, "live") +
      slider("tCpu", "CPU cores", 0.5, S.host.cpus, 0.5, cur.cpu,
        function (v) { return Number(v).toFixed(1) + " cores"; }, "live") +
      slider("tShm", "Shared memory", 128, 4096, 64, cur.shm, mb, "restarts it \u00b7 browsers want 512 MB+") +
      slider("tDisk", "Storage", 5120, maxDisk, 1024, cur.disk, mb,
        S.host.quota_support ? "restarts it" : "restarts it \u00b7 tracked budget") +
      toggle("tAuto", cur.auto, "Start with Docker", "on: comes back after a reboot. off: only when you start it") +
      (i.profile === "kasm" ? "" : screenField("t", (catEntry(i.entry_id) || {}).display || "fit",
        cur.display, cur.res || "1920x1080")) +
      '<div class="row" style="margin-top:16px"><span class="sub" id="tNote" style="margin:0;flex:1"></span>' +
      '<button class="btn ghost" id="tCancel" type="button">Cancel</button>' +
      '<button class="btn primary" id="tApply" type="button">Apply</button></div>');
    $$("#modalBody input[type=range]").forEach(syncRange);

    function changed() {
      return {
        mem: Number($("#tMem").value), cpu: Number($("#tCpu").value),
        shm: Number($("#tShm").value), disk: Number($("#tDisk").value), auto: $("#tAuto").checked,
        display: $("#tDisplay") ? $("#tDisplay").value : cur.display,
        res: $("#tRes") ? $("#tRes").value : cur.res
      };
    }
    function note() {
      var c = changed();
      var screen = c.display !== cur.display || (c.display === "fixed" && c.res !== cur.res);
      var restart = c.shm !== cur.shm || c.disk !== cur.disk || screen;
      var any = restart || c.mem !== cur.mem || c.cpu !== cur.cpu || c.auto !== cur.auto;
      $("#tNote").textContent = !any ? "Nothing changed yet." :
        restart ? "This restarts the desktop to apply (about half a minute). Files are kept." :
        "Applies instantly, no restart.";
      $("#tApply").disabled = !any;
    }
    $("#modalBody").oninput = function (ev) {
      var t = ev.target;
      if (t.type === "range") {
        syncRange(t);
        var fmt = t.id === "tCpu" ? Number(t.value).toFixed(1) + " cores" : mb(t.value);
        $("#" + t.id + "V").textContent = fmt;
      }
      note();
    };
    $("#modalBody").onchange = note;
    $("#tCancel").onclick = closeModal;
    $("#tApply").onclick = function () {
      var c = changed();
      var body = {};
      if (c.mem !== cur.mem) body.memory_mb = c.mem;
      if (c.cpu !== cur.cpu) body.cpus = c.cpu;
      if (c.shm !== cur.shm) body.shm_mb = c.shm;
      if (c.disk !== cur.disk) body.disk_mb = c.disk;
      if (c.auto !== cur.auto) body.autostart = c.auto;
      if (c.display !== cur.display || (c.display === "fixed" && c.res !== cur.res)) {
        body.display = c.display;
        body.resolution = c.res;
      }
      var btn = $("#tApply");
      btn.disabled = true;
      var rec = body.shm_mb || body.disk_mb || body.display;
      btn.textContent = rec ? "Recreating\u2026" : "Applying\u2026";
      if (S.drawerName === name && rec) closeDrawer();
      api("/api/instance/" + encodeURIComponent(name) + "/retune", { body: body })
        .then(function (r) {
          toast(r.recreated ? "Recreated with new limits" : "Limits applied", name, "ok");
          closeModal();
          S.instKey = "";
          refreshInstances();
        })
        .catch(function (e) {
          toast("Could not change limits", e.message, "bad");
          btn.disabled = false;
          btn.textContent = "Apply";
        });
    };
    note();
  }

  /* ------------------------------------------------------------ terminal */
  function keyToSeq(ev) {
    var k = ev.key;
    if (ev.ctrlKey && k.length === 1) {
      var c = k.toUpperCase().charCodeAt(0);
      if (c >= 64 && c <= 95) return String.fromCharCode(c - 64);
      if (k === " ") return "\x00";
    }
    switch (k) {
      case "Enter": return "\r";
      case "Backspace": return "\x7f";
      case "Tab": return "\t";
      case "Escape": return "\x1b";
      case "ArrowUp": return "\x1b[A";
      case "ArrowDown": return "\x1b[B";
      case "ArrowRight": return "\x1b[C";
      case "ArrowLeft": return "\x1b[D";
      case "Home": return "\x1b[H";
      case "End": return "\x1b[F";
      case "PageUp": return "\x1b[5~";
      case "PageDown": return "\x1b[6~";
      case "Delete": return "\x1b[3~";
      case "Insert": return "\x1b[2~";
      default: return (k && k.length === 1) ? k : null;
    }
  }

  /* One attach routine, used by the full Shell view and by the drawer that
     slides out of a manager card. */
  function attachTerm(cfg) {
    var term = new window.ForgeTerm(cfg.el, { cols: 100, rows: cfg.rows || 28 });
    var sess = { id: null, es: null, term: term, name: cfg.name, dead: false };
    var t0 = Date.now();
    var frames = "\u280b\u2819\u2839\u2838\u283c\u2834\u2826\u2827\u2807\u280f";
    var fi = 0, live = false;
    var spin = setInterval(function () {
      head(frames.charAt(fi++ % 10) + "  attaching to " + cfg.name + "  " +
           ((Date.now() - t0) / 1000).toFixed(1) + "s");
      if (fi === 90) term.line("still waiting on docker exec, the container may be busy", "d");
    }, 90);

    function head(txt) { if (cfg.head) cfg.head.textContent = txt; }
    function settled(txt) { if (spin) { clearInterval(spin); spin = null; } head(txt); }

    term.line("connecting to " + cfg.name + " ...", "d");
    term.line("");

    var fit = term.fit();
    api("/api/term", { body: { container: cfg.name, cols: fit.cols, rows: fit.rows } })
      .then(function (r) {
        sess.id = r.id;
        head("handshaking with the shell\u2026");
        sess.es = sse("/api/term/" + r.id + "/stream", {
          data: function (d) {
            if (!live) {
              live = true;
              settled("docker exec \u00b7 " + cfg.name + "  \u00b7  " +
                      ((Date.now() - t0) / 1000).toFixed(1) + "s to attach");
            }
            var raw = atob(typeof d === "string" ? d.replace(/^"|"$/g, "") : d);
            var out;
            try { out = decodeURIComponent(escape(raw)); } catch (e) { out = raw; }
            term.write(out);
          },
          closed: function () {
            sess.dead = true;
            settled("session closed \u00b7 " + cfg.name);
            term.line("");
            term.line("[session closed]", "d");
          },
          error: function () {}
        });
        cfg.el.focus();
      })
      .catch(function (e) {
        settled("could not attach");
        term.line("could not open a shell: " + e.message, "e");
      });

    function onKey(ev) {
      if (ev.metaKey || ev.altKey) return;
      if (ev.ctrlKey && (ev.key === "c" || ev.key === "v") && window.getSelection().toString()) return;
      var seq = keyToSeq(ev);
      if (seq != null) {
        ev.preventDefault();
        if (sess.id) api("/api/term/" + sess.id + "/input", { body: { data: seq } })
          .catch(function () {});
      }
    }
    function onPaste(ev) {
      ev.preventDefault();
      var txt = (ev.clipboardData || window.clipboardData).getData("text");
      if (sess.id) api("/api/term/" + sess.id + "/input", { body: { data: txt } })
        .catch(function () {});
    }
    cfg.el.addEventListener("keydown", onKey);
    cfg.el.addEventListener("paste", onPaste);

    sess.refit = function () {
      var f = term.fit();
      if (sess.id) api("/api/term/" + sess.id + "/resize", { body: f }).catch(function () {});
      return f;
    };
    sess.close = function () {
      if (spin) { clearInterval(spin); spin = null; }
      cfg.el.removeEventListener("keydown", onKey);
      cfg.el.removeEventListener("paste", onPaste);
      if (sess.es) sess.es.close();
      if (sess.id) api("/api/term/" + sess.id + "/close", { body: {} }).catch(function () {});
      sess.dead = true;
    };
    return sess;
  }

  function closeShell() {
    var s = S.shell;
    S.shell = null;
    if (s) { try { s.close(); } catch (e) { console.error(e); } }
  }

  function closeDrawer() {
    var d = $("#drawerHost");
    if (d) d.remove();
    var s = S.drawerSess;
    S.drawerSess = null;
    S.drawerName = null;
    if (s) { try { s.close(); } catch (e) { console.error(e); } }
  }

  /* The shell slides out inside the card you clicked, so you keep the
     instance's numbers in view while you type. */
  function toggleDrawer(name) {
    if (S.drawerName === name) { closeDrawer(); return; }
    closeDrawer();
    var card = document.querySelector('.mc[data-name="' + cssq(name) + '"]');
    if (!card) return;
    var host = document.createElement("div");
    host.id = "drawerHost";
    host.className = "drawer";
    host.innerHTML = '<div class="drawer-head"><span id="drawerHead">starting\u2026</span>' +
      '<div class="spacer" style="flex:1"></div>' +
      '<button class="iconbtn" id="drawerFit" title="Fit to size">' + I.fit + "</button>" +
      '<button class="iconbtn" id="drawerPop" title="Open the full shell view">' + I.open + "</button>" +
      '<button class="iconbtn" id="drawerClose" title="Close">' + I.close + "</button></div>" +
      '<pre class="term" id="drawerTerm" tabindex="0" style="outline:none"></pre>';
    card.appendChild(host);
    S.drawerName = name;
    S.drawerSess = attachTerm({ el: $("#drawerTerm"), head: $("#drawerHead"), name: name, rows: 20 });
    $("#drawerFit").onclick = function () {
      var f = S.drawerSess.refit();
      toast("Resized", f.cols + "\u00d7" + f.rows);
    };
    $("#drawerClose").onclick = closeDrawer;
    $("#drawerPop").onclick = function () { closeDrawer(); openTerm(name); };
    host.scrollIntoView({ block: "nearest", behavior: "smooth" });
  }

  function openTerm(name) {
    closeShell();
    show("shell");
    $("#shTitle").textContent = name;
    var el = $("#shTerm");
    el.innerHTML = "";
    S.shell = attachTerm({ el: el, head: $("#shHead"), name: name, rows: 28 });
    S.termName = name;
  }

  /* ---------------------------------------------------------------- host */
  function renderHost() {
    renderHostLife();
    renderSpace();
    api("/api/doctor").then(function (d) {
      var hst = d.host;
      $("#hostChecks").innerHTML = d.checks.map(function (c) {
        var bad = !c.ok && c.severity !== "info";
        return '<div class="link-row' + (bad ? "" : "") + '" style="' +
          (bad ? "border-color:rgba(255,107,126,.4)" : "") + '">' +
          '<span class="ico">' + (c.ok ? "✅" : (c.severity === "info" ? "ℹ️" : "⚠️")) + "</span>" +
          '<div style="flex:1;min-width:0"><div class="what">' + h(c.name) + "</div>" +
          '<div style="font-size:13px">' + h(c.detail) + "</div>" +
          (!c.ok && c.fix ? '<div style="font-size:12px;color:var(--dim-2)">fix: ' + h(c.fix) + "</div>" : "") +
          "</div></div>";
      }).join("");
      $("#hostFacts").innerHTML = "<dl class=\"kv\">" +
        ["hostname", "os_pretty", "kernel", "arch", "cpus", "docker_version", "storage_driver",
         "backing_fs", "cgroup", "python"].map(function (k) {
          return "<dt>" + h(k.replace(/_/g, " ")) + "</dt><dd>" + h(hst[k]) + "</dd>";
        }).join("") +
        "<dt>memory</dt><dd>" + mb(hst.mem_avail_mb) + " free of " + mb(hst.mem_total_mb) + "</dd>" +
        "<dt>disk</dt><dd>" + mb(hst.disk_free_mb) + " free of " + mb(hst.disk_total_mb) + "</dd>" +
        "<dt>docker root</dt><dd>" + h(hst.docker_root) + "</dd></dl>";
    }).catch(function (e) {
      $("#hostChecks").innerHTML = '<div class="warnbox bad">' + h(e.message) + "</div>";
    });
  }

  /* ----------------------------------------------------------- lifecycle */
  /* After a reboot or a crash the server knows which desktops were running;
     offer to start them again, and show whether the UI starts on boot. */
  function pollLife() {
    api("/api/lifecycle").then(renderLife).catch(function () {}).then(function () {
      setTimeout(pollLife, 90000);
    });
  }

  function renderLife(L) {
    S.life = L;
    var bar = $("#lifeBar");
    var ls = L && L.last_stop;
    if (ls && !ls.dismissed && ls.restore && ls.restore.length) {
      var n = ls.restore.length;
      bar.className = "updbar life" + (ls.clean ? "" : " warn");
      bar.innerHTML = '<span class="ic">' + I.restart + "</span>" +
        '<div class="msg"><b>Last stop: ' + h(ls.label || "the web UI stopped") + "</b><small>" + n +
        " desktop" + (n === 1 ? " that was" : "s that were") + " running then " + (n === 1 ? "is" : "are") +
        " stopped now: " + h(ls.restore.map(function (x) { return x.replace(/^forge-/, ""); }).join(", ")) + "</small></div>" +
        '<button class="btn primary sm" id="lifeRestore" type="button">Start ' + (n === 1 ? "it" : "them") + " again</button>" +
        '<button class="iconbtn" id="lifeHide" type="button" title="Dismiss">' + I.close + "</button>";
      bar.hidden = false;
      $("#lifeRestore").onclick = function () {
        var b = $("#lifeRestore");
        b.disabled = true; b.textContent = "Starting\u2026";
        api("/api/restore", { body: {} }).then(function (r) {
          toast("Started again", (r.started || []).join(", ") || "nothing needed starting", "ok");
          bar.hidden = true; S.instKey = ""; refreshInstances();
        }).catch(function (e) { toast("Could not start them", e.message, "bad"); b.disabled = false; });
      };
      $("#lifeHide").onclick = function () {
        bar.hidden = true;
        api("/api/last-stop/dismiss", { body: {} }).catch(function () {});
      };
    } else {
      bar.hidden = true;
    }
    if (S.view === "host") renderHostLife();
  }

  function renderSpace() {
    var el = $("#hostSpace");
    if (!el) return;
    api("/api/space").then(function (r) {
      var g = r.groups || {};
      var sum = function (list, used) {
        return (list || []).filter(function (x) { return used === undefined || x.in_use === used; })
          .reduce(function (a, x) { return a + (x.size_mb || 0); }, 0);
      };
      var row = function (k, list, note) {
        var n = (list || []).length;
        return "<dt>" + h(k) + "</dt><dd>" + n + (n ? " \u00b7 " + mb(sum(list)) : "") +
          (note ? ' <span class="muted">' + h(note) + "</span>" : "") + "</dd>";
      };
      el.innerHTML = '<dl class="kv">' +
        row("Forge layers", g.layers, "a few KB on top of each image") +
        row("Built desktops", g.built, mb(sum(g.built, false)) + " unused") +
        row("Pulled desktops", g.pulled, mb(sum(g.pulled, false)) + " unused") +
        row("Base images", g.bases) +
        "<dt>Build cache</dt><dd>" + mb(r.build_cache_mb || 0) + "</dd>" +
        "<dt>Orphan volumes</dt><dd>" + (r.orphan_volumes || []).length +
        ' <span class="muted">files of removed desktops you chose to keep</span></dd></dl>' +
        '<div class="row" style="margin-top:12px"><button class="btn sm" id="spClean">Tidy up (' +
        mb(r.reclaimable_mb || 0) + ")</button>" +
        '<button class="btn sm ghost" id="spCleanAll">Remove everything unused (' + mb(r.reclaimable_all_mb || 0) +
        ")</button></div>" +
        '<p class="sub" style="font-size:12px;margin:8px 0 0">Nothing a desktop uses is ever removed. ' +
        "Kept files of removed desktops stay unless you delete them from the terminal (selkies-cli clean).</p>";
      var go = function (all) {
        if (all && !confirm("Remove every desktop image no desktop uses, and Docker's build cache?\n\n" +
            "They download or rebuild again if you forge those desktops later.")) return;
        el.querySelectorAll("button").forEach(function (b) { b.disabled = true; });
        api("/api/space/clean", { body: { all: all } }).then(function (x) {
          toast("Cleaned up", (x.removed_images || []).length + " images removed", "ok");
          renderSpace();
        }).catch(function (x) { toast("Clean-up failed", x.message, "bad"); renderSpace(); });
      };
      $("#spClean").onclick = function () { go(false); };
      $("#spCleanAll").onclick = function () { go(true); };
    }).catch(function (x) { el.innerHTML = '<div class="warnbox bad">' + h(x.message) + "</div>"; });
  }

  function renderHostLife() {
    var el = $("#hostLife");
    if (!el) return;
    var L = S.life || {};
    var b = L.boot || {}, ls = L.last_stop;
    el.innerHTML = toggle("bootToggle", !!b.enabled, "Start the web UI when this machine boots",
        b.enabled ? ("on, through " + (b.method === "systemd" ? "a systemd user service" : "cron") +
          (b.method === "systemd" && b.linger === false ? "; it waits for you to log in until linger is on " +
            "(sudo loginctl enable-linger $USER)" : "")) : "off: start it yourself with selkies-cli") +
      (ls ? '<p class="sub" style="margin:12px 0 0">Last stop: ' + h(ls.label || ls.reason) +
        (ls.at ? " \u00b7 " + h(new Date(ls.at * 1000).toLocaleString()) : "") + "</p>" : "");
    $("#bootToggle").onchange = function (ev) {
      var on = ev.target.checked;
      ev.target.disabled = true;
      api("/api/autostart-ui", { body: { enable: on } }).then(function (r) {
        toast(on ? "Starts on boot" : "No longer starts on boot",
          r.needs ? "run: " + r.needs + " so it starts before anyone logs in" : (r.method || ""), r.needs ? "" : "ok");
        return api("/api/lifecycle").then(renderLife);
      }).catch(function (e) {
        toast("Could not change that", e.message, "bad");
        ev.target.checked = !on;
      }).then(function () { ev.target.disabled = false; });
    };
  }

  /* ------------------------------------------------------------- updates */
  /* The server checks GitHub every 5 minutes and installs new builds on its
     own; this just asks the local server whether one is waiting. */
  function pollUpdate() {
    api("/api/update").then(renderUpdate).catch(function () {}).then(function () {
      setTimeout(pollUpdate, 60000);
    });
  }

  function renderUpdate(u) {
    var bar = $("#updBar");
    if (!u || S.restarting) return;
    if (u.restart_needed) {
      bar.className = "updbar";
      bar.innerHTML = '<span class="ic">' + I.upd + "</span>" +
        '<div class="msg"><b>Selkies Forge ' + h(u.installed_version || "update") +
        " is installed</b><small>Restart the web UI to start using it. Your desktops keep running.</small></div>" +
        '<button class="btn primary sm" id="updRestart" type="button">Restart now</button>' +
        '<button class="iconbtn" id="updHide" type="button" title="Later">' + I.close + "</button>";
      bar.hidden = S.updHidden === "r:" + u.installed_version;
    } else if (u.available && u.error) {
      bar.className = "updbar warn";
      bar.innerHTML = '<span class="ic">' + I.upd + "</span>" +
        '<div class="msg"><b>An update' + (u.remote_version ? " (" + h(u.remote_version) + ")" : "") +
        " is available</b><small>It could not install by itself: " + h(u.error) + "</small></div>" +
        '<button class="btn sm" id="updRetry" type="button">Try again</button>' +
        '<button class="iconbtn" id="updHide" type="button" title="Later">' + I.close + "</button>";
      bar.hidden = S.updHidden === "a:" + u.remote_version;
    } else {
      bar.hidden = true;
      return;
    }
    var hide = $("#updHide");
    if (hide) hide.onclick = function () {
      S.updHidden = u.restart_needed ? "r:" + u.installed_version : "a:" + u.remote_version;
      bar.hidden = true;
    };
    var rs = $("#updRestart");
    if (rs) rs.onclick = restartForUpdate;
    var rt = $("#updRetry");
    if (rt) rt.onclick = function () {
      rt.disabled = true;
      rt.textContent = "Installing\u2026";
      api("/api/update/check", { body: {} }).then(renderUpdate)
        .catch(function (e) { toast("Update failed", e.message, "bad"); rt.disabled = false; });
    };
  }

  function restartForUpdate() {
    S.restarting = true;
    var bar = $("#updBar");
    bar.className = "updbar";
    bar.innerHTML = '<span class="ic">' + I.restart + '</span><div class="msg"><b>Restarting the web UI\u2026</b>' +
      "<small>This page reloads by itself in a few seconds.</small></div>";
    api("/api/update/restart", { body: {} }).catch(function () {});
    var tries = 0;
    function waitForIt() {
      tries++;
      fetch("/api/update", { cache: "no-store" })
        .then(function (r) { return r.json(); })
        .then(function (u) {
          if (!u.restart_needed) location.reload();
          else if (tries < 90) setTimeout(waitForIt, 1500);
        })
        .catch(function () { if (tries < 90) setTimeout(waitForIt, 1500); });
    }
    setTimeout(waitForIt, 3000);
  }

  /* ------------------------------------------------------------ routing */
  function show(view) {
    S.view = view;
    $$(".view").forEach(function (v) { v.classList.toggle("on", v.id === "v-" + view); });
    $$("#rail button[data-view]").forEach(function (b) {
      var on = b.dataset.view === view || (view === "configure" && b.dataset.view === "browse");
      b.classList.toggle("on", on);
    });
    closeMenus();
    if (view === "manager") { S.instKey = ""; refreshInstances(); }
    if (view === "host") renderHost();
    if (view === "addons" && window.ForgeAddons) window.ForgeAddons.show();
    $(".main").scrollTop = 0;
  }

  /* ------------------------------------------------------------- events */
  function wire() {
    $("#rail").addEventListener("click", function (ev) {
      var b = ev.target.closest("button[data-view]");
      if (b) show(b.dataset.view);
    });
    $("#liteBtn").addEventListener("click", function () { applyLite(!S.lite); });
    $("#themes").addEventListener("click", function (ev) {
      var b = ev.target.closest("[data-theme-id]");
      if (b) applyTheme(b.dataset.themeId);
    });

    /* browse */
    var qTimer = null;
    $("#q").addEventListener("input", function () {
      var v = this.value;
      clearTimeout(qTimer);
      qTimer = setTimeout(function () {
        S.filters.q = v;
        if (S.view !== "browse") show("browse");
        renderGrid();
      }, 120);
    });
    $("#sort").addEventListener("change", function () { S.filters.sort = this.value; renderGrid(); });
    $("#famSel").addEventListener("change", function () { S.filters.family = this.value; renderGrid(); });
    $("#weightSeg").addEventListener("click", function (ev) {
      var b = ev.target.closest("button[data-w]");
      if (!b) return;
      S.filters.weight = b.dataset.w;
      renderFilters(); renderGrid();
    });
    $("#kindSeg").addEventListener("click", function (ev) {
      var b = ev.target.closest("button[data-kind]");
      if (!b) return;
      S.filters.kind = b.dataset.kind;
      renderFilters(); renderGrid();
    });
    $("#grid").addEventListener("click", function (ev) {
      var c = ev.target.closest(".card");
      if (c) openDetail(c.dataset.id);
    });
    $("#grid").addEventListener("keydown", function (ev) {
      if (ev.key !== "Enter" && ev.key !== " ") return;
      var c = ev.target.closest(".card");
      if (c) { ev.preventDefault(); openDetail(c.dataset.id); }
    });

    /* smart chooser */
    $("#tasteSeg").addEventListener("click", function (ev) {
      var b = ev.target.closest("button[data-taste]");
      if (!b) return;
      S.smart.taste = b.dataset.taste;
      renderSmartControls();
      runSmart();
    });
    $("#purposeSel").addEventListener("change", function () {
      S.smart.purpose = this.value;
      runSmart();
    });
    $("#smartBtn").addEventListener("click", runSmart);
    $("#smartOut").addEventListener("click", function (ev) {
      var u = ev.target.closest("[data-use]");
      if (u) return openDetail(u.dataset.use);
      var g = ev.target.closest("[data-go]");
      if (g) return openDetail(g.dataset.go, true);
    });

    /* detail page */
    $("#dGallery").addEventListener("click", function (ev) {
      var f = ev.target.closest("[data-shot]");
      if (f) openShot(Number(f.dataset.shot));
    });

    /* lightbox */
    $("#lbClose").addEventListener("click", closeShot);
    $("#lbPrev").addEventListener("click", function () { openShot(S.shotIdx - 1); });
    $("#lbNext").addEventListener("click", function () { openShot(S.shotIdx + 1); });
    $("#lightbox").addEventListener("click", function (ev) {
      if (ev.target.id === "lightbox" || ev.target.classList.contains("lb-img")) closeShot();
    });

    /* Close buttons: caught in the capture phase on the document, so no other
       handler (or an error in one) can swallow the click. */
    document.addEventListener("click", function (ev) {
      var b = ev.target.closest && ev.target.closest("#modalClose, #modalX, #drawerClose, #shClose, #lbClose, .toast .x, #updHide");
      if (!b) return;
      if (b.id === "modalClose" || b.id === "modalX") closeModal();
      else if (b.id === "drawerClose") closeDrawer();
      else if (b.id === "lbClose") closeShot();
      else if (b.id === "shClose") { closeShell(); show("manager"); }
      else if (b.classList.contains("x")) { var t = b.closest(".toast"); if (t) t.remove(); }
      else if (b.id === "updHide") { $("#updBar").hidden = true; return; }
      ev.stopPropagation();
      ev.preventDefault();
    }, true);
    /* modal: its own listeners, so nothing can swallow the close click */
    $("#modal").addEventListener("click", function (ev) {
      if (ev.target.id === "modal") closeModal();
    });

    /* everything rendered on the fly */
    document.addEventListener("click", function (ev) {
      var t = ev.target;
      var mbtn = t.closest("[data-menu]");
      if (mbtn) {
        var menu = mbtn.parentNode.querySelector(".menu");
        var wasOpen = !menu.hidden;
        closeMenus();
        if (!wasOpen) {
          menu.hidden = false;
          // The card clips its contents (rounded corners), so fit the menu in
          // the room above the button and let it scroll if it is longer.
          var card = mbtn.closest(".mc");
          if (card) {
            var room = mbtn.getBoundingClientRect().top - card.getBoundingClientRect().top - 14;
            menu.style.maxHeight = Math.max(160, room) + "px";
          }
          closeMenus(menu);
        }
        return;
      }
      if (!t.closest(".menu")) closeMenus();

      var x;
      if ((x = t.closest("[data-open]"))) { openDesktop(x.dataset.open); return; }
      if ((x = t.closest("[data-drawer]"))) { toggleDrawer(x.dataset.drawer); return; }
      if ((x = t.closest("[data-copy]"))) { copy(x.dataset.copy); return; }
      if ((x = t.closest("[data-back]"))) { show(x.dataset.back); return; }
      if ((x = t.closest("[data-term]"))) { openTerm(x.dataset.term); return; }
      if ((x = t.closest("[data-logs]"))) { closeMenus(); showLogs(x.dataset.logs); return; }
      if ((x = t.closest("[data-tune]"))) { closeMenus(); showTune(x.dataset.tune); return; }
      if ((x = t.closest("[data-reveal]"))) {
        var nm = x.dataset.reveal;
        var inst = S.instances.filter(function (i) { return i.name === nm; })[0];
        var val = document.querySelector('[data-secret="' + cssq(nm) + '"]');
        if (inst && inst.auth && val) {
          var shown = x.classList.toggle("on");
          val.innerHTML = "<span>" + h(inst.auth.user) + '</span><span class="muted"> / ' +
            (shown ? h(inst.auth.password) : "••••••••") + "</span>";
        }
        return;
      }
      if ((x = t.closest("[data-jobcancel]"))) {
        x.disabled = true;
        api("/api/job/" + x.dataset.jobcancel + "/cancel", { body: {} }).then(function (r) {
          toast(r.cancelled ? "Cancelling\u2026" : "Could not cancel it", "", r.cancelled ? "" : "bad");
          setTimeout(refreshJobs, 1500);
        }).catch(function (e) { toast("Cancel failed", e.message, "bad"); });
        return;
      }
      if ((x = t.closest("[data-act]"))) {
        var card = x.closest(".mc");
        closeMenus();
        if (card) instAction(card.dataset.name, x.dataset.act);
        return;
      }
      var id = t.id || (t.closest("button") || {}).id;
      if (id === "goBtn" || id === "goBtn2" || id === "retryBtn") { startLaunch(); return; }
      if (id === "dfBtn") {
        var o = $("#dfOut");
        var open = o.style.display === "none";
        o.style.display = open ? "block" : "none";
        $("#dfBtn").textContent = open ? "Hide Dockerfile" : "Show Dockerfile";
      }
    });

    document.addEventListener("input", function (ev) {
      var t = ev.target;
      if (t.type !== "range" || !S.plan || !t.closest("#cfgTune")) return;
      syncRange(t);
      if (t.id === "sMem") { S.plan.memory_mb = Number(t.value); $("#sMemV").textContent = mb(t.value); }
      if (t.id === "sCpu") { S.plan.cpus = Number(t.value); $("#sCpuV").textContent = Number(t.value).toFixed(1) + " cores"; }
      if (t.id === "sShm") { S.plan.shm_mb = Number(t.value); $("#sShmV").textContent = mb(t.value); }
      if (t.id === "sDisk") { S.plan.disk_mb = Number(t.value); $("#sDiskV").textContent = mb(t.value); }
      updateGoSummary();
    });

    document.addEventListener("change", function (ev) {
      if (ev.target.id === "oAuth") $("#authFields").style.display = ev.target.checked ? "block" : "none";
      if (ev.target.id === "oDisplay" || ev.target.id === "tDisplay") {
        var p = ev.target.id.charAt(0), pref = ev.target.dataset.pref || (S.sel && S.sel.display) || "fit";
        var v = ev.target.value;
        $("#" + p + "ResWrap").style.display = (v === "fixed" || (v === "auto" && pref === "fixed")) ? "block" : "none";
      }
    });

    /* shell view */
    $("#shFit").addEventListener("click", function () {
      if (!S.shell) return;
      var f = S.shell.refit();
      toast("Resized", f.cols + "×" + f.rows);
    });


    var rsz = null;
    window.addEventListener("resize", function () {
      clearTimeout(rsz);
      rsz = setTimeout(function () {
        if (S.shell && S.view === "shell") S.shell.refit();
        if (S.drawerSess) S.drawerSess.refit();
      }, 220);
    });

    window.addEventListener("keydown", function (ev) {
      if (!$("#lightbox").hidden) {
        if (ev.key === "Escape") { closeShot(); ev.preventDefault(); }
        if (ev.key === "ArrowLeft") openShot(S.shotIdx - 1);
        if (ev.key === "ArrowRight") openShot(S.shotIdx + 1);
        return;
      }
      if (ev.key === "Escape") {
        if ($("#modal").style.display === "grid") { closeModal(); return; }
        closeMenus();
      }
      // A page shortcut must never eat a keystroke meant for a shell or a field.
      var tag = ev.target.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
      if (ev.target.closest && ev.target.closest(".term")) return;
      if (ev.key === "/") { ev.preventDefault(); $("#q").focus(); }
      if (ev.key === "1") show("browse");
      if (ev.key === "2") show("manager");
      if (ev.key === "3") show("host");
      if (ev.key === "4") show("addons");
    });
  }

  // addons.js builds the Addons view with the same helpers.
  window.Forge = {
    api: api, sse: sse, h: h, toast: toast, copy: copy, ago: ago, I: I,
    openModal: openModal, closeModal: closeModal, show: show,
    linkChooser: linkChooser, networkUrl: networkUrl,
    view: function () { return S.view; }
  };

  document.addEventListener("DOMContentLoaded", function () { wire(); boot(); });
})();
