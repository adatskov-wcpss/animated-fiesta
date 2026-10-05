/* Selkies Forge - the Addons view. Uses app.js's helpers (window.Forge).
   An addon is a repository with a forge-addon.json; see docs/addons.md. */
(function () {
  "use strict";
  var F = window.Forge;
  if (!F) return;
  var $ = function (s, r) { return (r || document).querySelector(s); };
  var h = F.h;
  var EXAMPLE = "https://github.com/adatskov-wcpss/animated-fiesta/tree/main/addons/hello-forge";
  var A = { list: null, timer: null, jobs: {}, busy: {}, es: null };

  /* -------------------------------------------------------------- data */
  function load() {
    return F.api("/api/addons").then(function (r) {
      A.list = r.addons || [];
      $("#tagAddons").textContent = A.list.length ? A.list.filter(function (a) { return a.installed; }).length + "/" + A.list.length : "0";
      if (F.view() === "addons") render();
    }).catch(function (e) {
      if (window.console) console.error("addons:", e);
      if (F.view() === "addons") $("#addonList").innerHTML = '<div class="warnbox bad">' + h(e.message) + "</div>";
    });
  }

  function schedule() {
    clearTimeout(A.timer);
    A.timer = setTimeout(function () { load().then(schedule); }, F.view() === "addons" ? 10000 : 60000);
  }

  /* -------------------------------------------------------------- render */
  function statePill(a) {
    var st = a.status || {};
    if (A.busy[a.id]) return '<span class="pill busy"><i></i>' + h(A.busy[a.id]) + "</span>";
    if (!a.installed) return a.detected && a.detected.found
      ? '<span class="pill found"><i></i>on this machine</span>' : '<span class="pill"><i></i>not installed</span>';
    if (st.state === "running") return '<span class="pill up"><i></i>running</span>';
    if (st.state === "stopped") return '<span class="pill bad"><i></i>stopped</span>';
    if (st.state === "error") return '<span class="pill bad" title="' + h(st.detail || "") + '"><i></i>error</span>';
    return '<span class="pill up"><i></i>installed</span>';
  }

  function card(a) {
    var st = a.status || {};
    var busy = !!A.busy[a.id];
    var found = !a.installed && a.detected && a.detected.found;
    var hasUpdate = !a.update_pending && a.remote && a.remote.up_to_date === false;
    var main = "";
    if (!a.installed) {
      main = '<button class="btn primary" data-ad="install" data-id="' + h(a.id) + '"' + (busy || a.problems.length ? " disabled" : "") + ">" +
        (found ? F.I.plug + " Link it" : F.I.save + " Install") + "</button>";
    } else if (a.ways) {
      main = '<button class="btn primary" data-ad="open" data-id="' + h(a.id) + '">' + F.I.open + " Open</button>";
    } else if (a.open_url) {
      main = '<a class="btn primary" href="' + h(a.open_url) + '" target="_blank" rel="noopener">' + F.I.open + " Open</a>";
    }
    var menu = [];
    if (a.installed) {
      a.actions.forEach(function (x) {
        menu.push('<button data-ad="action" data-id="' + h(a.id) + '" data-action="' + h(x.id) + '" data-confirm="' + h(x.confirm || "") + '">' + F.I.restart + h(x.label) + "</button>");
      });
      if (a.settings.length) menu.push('<button data-ad="install" data-id="' + h(a.id) + '">' + F.I.tune + "Settings and reinstall</button>");
    }
    menu.push('<button data-ad="check" data-id="' + h(a.id) + '">' + F.I.upd + "Check for updates</button>");
    (a.links || []).forEach(function (l) {
      menu.push('<a href="' + h(l.url) + '" target="_blank" rel="noopener">' + F.I.open + h(l.label) + "</a>");
    });
    if (a.homepage) menu.push('<a href="' + h(a.homepage) + '" target="_blank" rel="noopener">' + F.I.globe + "Homepage</a>");
    menu.push("<hr>");
    if (a.installed) menu.push('<button class="danger" data-ad="uninstall" data-id="' + h(a.id) + '">' + F.I.unplug + "Uninstall</button>");
    else menu.push('<button class="danger" data-ad="remove" data-id="' + h(a.id) + '">' + F.I.trash + "Remove from the list</button>");

    return '<article class="ad' + (a.installed ? " on" : "") + (busy ? " busy" : "") + (hasUpdate ? " has-update" : "") + '" data-id="' + h(a.id) + '">' +
      '<div class="ad-head">' +
        '<div class="ad-logo">' + (a.logo ? '<img src="' + h(a.logo) + '" alt="" loading="lazy">' : "<span>" + h(a.name.charAt(0)) + "</span>") + "</div>" +
        '<div class="ad-t"><div class="ad-name">' + h(a.name) + ' <span class="ad-ver">v' + h(a.installed && a.installed_version ? a.installed_version : a.version) + "</span></div>" +
          '<div class="ad-by">' + (a.author ? "by " + h(a.author) + " · " : "") + '<span class="mono" title="' + h(a.source) + '">' + h(shortSource(a.source)) + "</span></div></div>" +
        statePill(a) +
      "</div>" +
      '<p class="ad-desc">' + h(a.description || "No description.") + "</p>" +
      (a.problems.length ? '<div class="warnbox bad ad-note">This machine ' + h(a.problems.join("; ")) + ".</div>" : "") +
      (found ? '<div class="ad-note found">' + F.I.eye + "<span>Already on this machine" + (a.detected.detail ? ": " + h(a.detected.detail) : "") +
        ". <b>Link it</b> keeps it as it is and brings it under the forge.</span></div>" : "") +
      (a.update_pending ? '<div class="ad-note">' + F.I.upd + "<span>New code (v" + h(a.version) + ") is fetched; <b>Update</b> installs it.</span></div>" : "") +
      (hasUpdate ? '<div class="ad-note update"><span class="new-chip">NEW</span>' +
        "<span>Commit <b class=\"mono\">" + h(String(a.remote.commit || "").slice(0, 7)) + "</b> is available to update to" +
        (a.remote.version && a.remote.version !== a.version ? " (v" + h(a.remote.version) + ")" : "") + ".</span></div>" : "") +
      (a.installed && st.detail && st.state !== "error" ? '<div class="ad-status mono">' + h(st.detail) + "</div>" : "") +
      '<div class="ad-foot">' + main +
        (a.update_pending ? '<button class="btn" data-ad="update" data-id="' + h(a.id) + '">' + F.I.upd + " Update</button>"
          : hasUpdate ? '<button class="btn upd" data-ad="check" data-id="' + h(a.id) + '">' + F.I.upd + " Update</button>" : "") +
        '<span class="spacer"></span>' +
        '<div class="menu-wrap"><button class="iconbtn" data-menu title="More" aria-label="More">' + F.I.more + "</button>" +
        '<div class="menu" hidden>' + menu.join("") + "</div></div>" +
      "</div></article>";
  }

  function shortSource(s) {
    return String(s || "").replace(/^https?:\/\/(www\.)?/, "").replace(/^github\.com\//, "").replace(/\/tree\/[^/]+\//, " / ");
  }

  function render() {
    var box = $("#addonList");
    if (!A.list) return;
    if (!A.list.length) {
      box.innerHTML = '<div class="panel empty ad-empty"><div class="big">✚</div><h3>No addons yet</h3>' +
        '<p class="sub">Paste a repository link above. Not sure where to start? The example addon is a tiny web app that shows your desktops; ' +
        'it installs in a second and uninstalls cleanly.</p>' +
        '<button class="btn primary" type="button" data-ad="example">Add the example addon</button></div>';
      return;
    }
    // keep an open menu open across the refresh
    var open = document.querySelector("#addonList .menu:not([hidden])");
    if (open) return;
    box.innerHTML = A.list.map(card).join("");
  }

  /* -------------------------------------------------------------- add */
  function addSource(src) {
    var btn = $("#addonAdd"), msg = $("#addonAddMsg");
    src = (src || "").trim();
    if (!src) { $("#addonSrc").focus(); return; }
    btn.disabled = true;
    btn.textContent = "Fetching…";
    msg.innerHTML = "";
    return F.api("/api/addons/add", { body: { source: src } }).then(function (r) {
      var a = r.addon;
      $("#addonSrc").value = "";
      F.toast("Added " + a.name, a.detected.found ? "It is already on this machine: Link it to bring it under the forge." : "Nothing is installed until you press Install.", "ok");
      return load();
    }).catch(function (e) {
      msg.innerHTML = '<div class="warnbox bad add-err">' + h(e.message) + "</div>";
    }).then(function () { btn.disabled = false; btn.textContent = "Add"; });
  }

  /* -------------------------------------------------------------- install */
  function settingField(s) {
    var id = "as_" + s.key, v = s.value == null ? "" : s.value;
    var icon = s.icon ? '<img class="set-ico" src="' + h(s.icon) + '" alt="">' : "";
    var help = s.help ? "<small>" + h(s.help) + "</small>" : "";
    if (s.type === "bool") {
      return '<label class="toggle ad-set">' + '<input type="checkbox" id="' + id + '" data-key="' + h(s.key) + '"' + (v ? " checked" : "") + "><i></i>" +
        icon + "<span>" + h(s.label) + help + "</span></label>";
    }
    var input;
    if (s.type === "select") {
      input = '<select id="' + id + '" data-key="' + h(s.key) + '">' + s.options.map(function (o) {
        return '<option value="' + h(o.value) + '"' + (String(v) === o.value ? " selected" : "") + ">" + h(o.label) + "</option>";
      }).join("") + "</select>";
    } else {
      input = '<input id="' + id + '" data-key="' + h(s.key) + '" type="' + (s.type === "password" ? "password" : s.type === "number" ? "number" : "text") + '"' +
        (s.min != null ? ' min="' + s.min + '"' : "") + (s.max != null ? ' max="' + s.max + '"' : "") +
        ' value="' + h(v) + '"' + (s.type === "password" && v ? ' placeholder="unchanged"' : "") + ">";
    }
    return '<label class="field ad-set">' + "<span>" + icon + h(s.label) + (s.required ? " *" : "") + "</span>" + input + help + "</label>";
  }

  function installForm(a) {
    var found = !a.installed && a.detected && a.detected.found;
    var verb = a.installed ? "Reinstall" : found ? "Link" : "Install";
    var html = '<div class="ad-modal-head"><div class="ad-logo lg">' + (a.logo ? '<img src="' + h(a.logo) + '" alt="">' : "") + "</div>" +
      "<div><b>" + h(a.name) + '</b> <span class="ad-ver">v' + h(a.version) + "</span><p>" + h(a.description) + "</p></div></div>" +
      (found ? '<div class="ad-note found">' + F.I.eye + "<span>" + h(a.name) + " is already on this machine. Linking keeps its data and settings and updates its code to this version.</span></div>" : "") +
      (a.settings.length ? '<div class="ad-sets">' + a.settings.map(settingField).join("") + "</div>" : "") +
      '<div class="warnbox ad-trust">It runs <span class="mono">' + h(shortSource(a.source)) + "</span>'s install script as you on this machine.</div>" +
      '<div class="row end"><button class="btn ghost" type="button" id="adCancel">Cancel</button>' +
      '<button class="btn primary" type="button" id="adGo">' + h(verb) + "</button></div>";
    F.openModal(verb + " " + a.name, html);
    $("#adCancel").onclick = F.closeModal;
    $("#adGo").onclick = function () {
      var settings = {};
      Array.prototype.forEach.call(document.querySelectorAll("#modalBody [data-key]"), function (el) {
        settings[el.dataset.key] = el.type === "checkbox" ? el.checked : el.value;
      });
      runJob(a, "install", { settings: settings }, verb === "Link" ? "Linking " + a.name : "Installing " + a.name);
    };
  }

  /* -------------------------------------------------------------- jobs */
  function runJob(a, what, body, title) {
    A.busy[a.id] = title;
    render();
    F.api("/api/addons/" + encodeURIComponent(a.id) + "/" + what, { body: body || {} }).then(function (r) {
      watchJob(a, r.job, title);
    }).catch(function (e) {
      delete A.busy[a.id];
      F.toast(title + " failed", e.message, "bad");
      F.closeModal();
      load();
    });
  }

  function watchJob(a, job, title) {
    F.openModal(title, '<div class="ad-run">' +
      '<div class="progress-wrap"><span class="what" id="adWhat">starting</span><div class="progress"><i id="adBar"></i></div>' +
      '<span class="pct" id="adPct">0%</span><button class="btn sm ghost" id="adStop" type="button">Cancel</button></div>' +
      '<div class="term-wrap"><div class="term-head"><span class="lights"><i></i><i></i><i></i></span><span>' + h(a.name) + ' · live output</span></div>' +
      '<pre class="term" id="adTerm"></pre></div><div id="adResult"></div></div>');
    var term = $("#adTerm");
    function line(text, cls) {
      if (!term) return;
      var atEnd = term.scrollTop + term.clientHeight >= term.scrollHeight - 8;
      var span = document.createElement("span");
      if (cls) span.className = cls;
      span.textContent = text + "\n";
      term.appendChild(span);
      while (term.childNodes.length > 1500) term.removeChild(term.firstChild);
      if (atEnd) term.scrollTop = term.scrollHeight;
    }
    function prog(p, label) {
      var pct = Math.round((p || 0) * 100);
      if ($("#adBar")) $("#adBar").style.width = pct + "%";
      if ($("#adPct")) $("#adPct").textContent = pct + "%";
      if (label && $("#adWhat")) $("#adWhat").textContent = label;
    }
    $("#adStop").onclick = function () {
      F.api("/api/job/" + job.id + "/cancel", { body: {} }).then(function () { line("cancelling…", "e"); });
    };
    function finish(ok, data) {
      delete A.busy[a.id];
      if (A.es) { A.es.close(); A.es = null; }
      var stop = $("#adStop");
      if (stop) stop.remove();
      var res = $("#adResult");
      if (!res) return load();
      if (ok) {
        prog(1, "done");
        res.innerHTML = '<div class="ad-done">' + F.I.plug + "<div><b>" + h(a.name) + (data && data.adopted ? " is linked." : " is ready.") + "</b>" +
          ((data && data.warnings && data.warnings.length) ? "<small>" + h(data.warnings.join(" · ")) + "</small>" : "") + "</div>" +
          '<span class="spacer"></span>' + (data && data.open_url ? '<a class="btn primary" href="' + h(data.open_url) + '" target="_blank" rel="noopener">' + F.I.open + " Open " + h(a.name) + "</a>" : "") + "</div>";
      } else {
        res.innerHTML = '<div class="warnbox bad">' + h((data && data.message) || "It did not finish.") + "</div>";
      }
      load();
    }
    A.es = F.sse("/api/job/" + job.id + "/events", {
      snapshot: function (s) { prog(s.progress, s.label); },
      // job events arrive as {seq, t, type, data: {...}}; snapshots and finals are bare
      log: function (e) { var d = e.data || e; line(d.line, d.stream === "err" ? "e" : ""); },
      phase: function (e) { var d = e.data || e; prog(d.progress, d.label); line("▸ " + d.label, "i"); },
      progress: function (e) { var d = e.data || e; prog(d.progress); },
      done: function (e) { finish(true, e.data || e); },
      final: function (s) { if (s.status === "done") finish(true, s.result); else if (s.status !== "running") finish(false, s.error); }
    });
  }

  /* -------------------------------------------------------------- updates */
  function ago(t) {
    if (!t) return "";
    var s = Math.max(0, Date.now() / 1000 - t);
    if (s < 60) return "just now";
    if (s < 3600) return Math.round(s / 60) + " min ago";
    if (s < 86400) return Math.round(s / 3600) + " h ago";
    if (s < 86400 * 60) return Math.round(s / 86400) + " days ago";
    return new Date(t * 1000).toLocaleDateString();
  }
  function commitUrl(source, sha) {
    var m = String(source || "").match(/^(https:\/\/(?:github\.com|codeberg\.org)\/[^/]+\/[^/#]+?)(?:\.git)?(?:\/tree\/.*)?(?:#.*)?$/);
    if (m) return m[1] + "/commit/" + sha;
    m = String(source || "").match(/^(https:\/\/gitlab\.com\/[^/]+\/[^/#]+?)(?:\.git)?(?:\/-\/tree\/.*)?(?:#.*)?$/);
    return m ? m[1] + "/-/commit/" + sha : null;
  }
  function commitLine(c, source) {
    var url = commitUrl(source, c.commit);
    var sha = '<span class="up-sha">' + h(c.short || String(c.commit || "").slice(0, 7)) + "</span>";
    return '<div class="up-commit">' + (url ? '<a href="' + h(url) + '" target="_blank" rel="noopener">' + sha + "</a>" : sha) +
      '<div class="up-msg"><b>' + h(c.subject || "(no message)") + "</b><span>" + h([c.author, ago(c.date)].filter(Boolean).join(" \u00b7 ")) + "</span></div></div>";
  }

  function checkUpdates(a) {
    var logo = '<div class="ad-logo lg">' + (a.logo ? '<img src="' + h(a.logo) + '" alt="">' : "") + "</div>";
    F.openModal("Updates \u00b7 " + a.name, '<div class="upcheck">' +
      '<div class="up-head">' + logo + '<div><b>' + h(a.name) + '</b><span class="mono">' + h(shortSource(a.source)) + "</span></div></div>" +
      '<div class="up-state checking"><span class="spin-sm"></span><div><b>Checking for new commits\u2026</b>' +
      "<span>Asking " + h(String(a.source).replace(/^https?:\/\//, "").split("/")[0] || "the repository") + " what is newest.</span></div></div></div>");
    F.api("/api/addons/" + encodeURIComponent(a.id) + "/check").then(function (r) {
      var body = $("#modalBody .upcheck");
      if (!body) return;
      var st = body.querySelector(".up-state");
      var html, local = r.local || {};
      if (r.kind !== "git") {
        html = '<div class="up-state info">' + F.I.upd + "<div><b>Added from a folder</b><span>" + h(r.note) + "</span></div></div>" +
          '<div class="row end"><button class="btn primary" id="upGo">' + F.I.upd + " Copy it again</button></div>";
      } else if (r.up_to_date) {
        html = '<div class="up-state ok">' + I_CHECK + "<div><b>Up to date</b><span>" +
          (r.note ? h(r.note) : "No new commits since this addon was fetched.") + "</span></div></div>" +
          '<div class="up-k">Installed</div>' + commitLine(local, r.source) +
          '<div class="row end up-foot"><span class="faint">Checked ' + ago(r.checked) + "</span><span class=\"spacer\"></span>" +
          '<button class="btn ghost" id="upAgain">Check again</button><button class="btn" id="upClose">Close</button></div>';
      } else {
        var rem = r.remote || {}, commits = r.commits || [];
        var ver = rem.version && rem.version !== (local.installed_version || local.version)
          ? '<span class="up-ver"><span>v' + h(local.installed_version || local.version) + '</span>\u2192<b>v' + h(rem.version) + "</b></span>" : "";
        html = '<div class="up-state new">' + F.I.upd + "<div><b>Update available <span class=\"new-chip\">NEW</span></b><span>Commit <span class=\"mono\">" + h(rem.short) +
          "</span> is available to update to" + (commits.length > 1 ? ", " + commits.length + (r.more ? "+" : "") + " new commits" : "") + ".</span></div>" + ver + "</div>" +
          '<div class="up-k">New</div>' + commits.slice(0, 8).map(function (c) { return commitLine(c, r.source); }).join("") +
          (commits.length > 8 ? '<div class="faint up-more">and ' + (commits.length - 8) + " more</div>" : "") +
          '<div class="up-k">Installed now</div>' + commitLine(local, r.source) +
          '<div class="row end up-foot"><span class="faint">Checked ' + ago(r.checked) + "</span><span class=\"spacer\"></span>" +
          '<button class="btn ghost" id="upClose">Later</button><button class="btn upd" id="upGo">' + F.I.upd +
          " Update to " + h(rem.short) + "</button></div>";
      }
      st.outerHTML = html;
      var go = $("#upGo"), again = $("#upAgain"), close = $("#upClose");
      if (go) go.onclick = function () { runJob(a, "update", {}, (a.installed ? "Updating " : "Fetching ") + a.name); };
      if (again) again.onclick = function () { checkUpdates(a); };
      if (close) close.onclick = F.closeModal;
      load();
    }).catch(function (e) {
      var st = $("#modalBody .up-state");
      if (st) st.outerHTML = '<div class="up-state bad">' + F.I.close + "<div><b>Could not check</b><span>" + h(e.message) + "</span></div></div>" +
        '<div class="row end"><button class="btn" id="upAgain">Try again</button></div>';
      var again = $("#upAgain");
      if (again) again.onclick = function () { checkUpdates(a); };
    });
  }
  var I_CHECK = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="m8 12.5 2.8 2.8L16 10"/></svg>';

  /* -------------------------------------------------------------- open */
  // The same chooser as a desktop's: this machine, this network, a serveo
  // public link, Burrow. Only for addons whose status script names a port.
  function share(a, via, on) {
    return F.api("/api/addons/" + encodeURIComponent(a.id) + "/share", { body: { via: via, on: on } }).then(function (r) {
      a.ways = r.ways;
      openAddon(a);
      load();
    });
  }

  function openAddon(a) {
    var L = a.ways;
    var rows = [{ icon: "home", label: "This machine", url: L.local }];
    var net = F.networkUrl(L.local);
    if (net && net !== L.local) rows.push({ icon: "plug", label: "This network", url: net });
    var bt = L.burrow && L.burrow.tunnel;
    if (a.open_url && a.open_url !== L.local && a.open_url !== net && !(bt && a.open_url === bt.url)) {
      rows.unshift({ icon: "open", label: "Its own address", url: a.open_url });
    }
    rows.push(L.serveo && L.serveo.alive
      ? { icon: "globe", label: "Public link", url: L.serveo.url, pill: "serveo", buttons: [
          { label: "Drop", cls: "ghost danger", busy: "Dropping…", run: function () { return share(a, "serveo", false); } }] }
      : { icon: "globe", label: "Public link", sub: L.serveo ? "The serveo link went down." : "A random serveousercontent.com address anyone can open.",
          buttons: [{ label: L.serveo ? "Reopen public link" : "Make a public link", icon: "plug", busy: "Opening (up to a minute)…",
                      run: function () { return share(a, "serveo", true); } }] });
    var b = L.burrow || {};
    if (b.installed && a.id !== "burrow") {
      if (!b.running) rows.push({ icon: "lock", label: "Burrow", sub: "Burrow is installed but not answering." });
      else if (bt) rows.push({ icon: "lock", label: "Burrow", url: bt.url, sub: bt.url ? "" : "Getting an address…",
          pill: bt.access === "public" ? "public" : "login", pillCls: bt.access === "public" ? "" : "up",
          buttons: [{ label: "Unpublish", cls: "ghost danger", busy: "Removing…", run: function () { return share(a, "burrow", false); } }] });
      else rows.push({ icon: "lock", label: "Burrow", sub: "Its own address, behind Burrow's login.",
          buttons: [{ label: "Publish through Burrow", icon: "lock", busy: "Publishing…", run: function () { return share(a, "burrow", true); } }] });
    }
    F.linkChooser("Open " + a.name, "", rows);
  }

  function confirmBox(title, text, okLabel, extra, cb) {
    F.openModal(title, "<p class=\"sub\" style=\"margin:0 0 14px\">" + text + "</p>" + (extra || "") +
      '<div class="row end"><button class="btn ghost" type="button" id="cfNo">Cancel</button><button class="btn danger" type="button" id="cfYes">' + h(okLabel) + "</button></div>");
    $("#cfNo").onclick = F.closeModal;
    $("#cfYes").onclick = cb;
  }

  /* -------------------------------------------------------------- events */
  function byId(id) { return (A.list || []).filter(function (a) { return a.id === id; })[0]; }

  document.addEventListener("click", function (ev) {
    var t = ev.target.closest && ev.target.closest("[data-ad]");
    if (!t) return;
    var what = t.dataset.ad;
    if (what === "example") { addSource(EXAMPLE); return; }
    var a = byId(t.dataset.id);
    if (!a) return;
    var menu = t.closest(".menu");
    if (menu) menu.hidden = true;
    if (what === "check") checkUpdates(a);
    else if (what === "open") openAddon(a);
    else if (what === "install") installForm(a);
    else if (what === "update") runJob(a, "update", {}, (a.installed ? "Updating " : "Fetching ") + a.name);
    else if (what === "action") {
      var go = function () { runJob(a, "action", { action: t.dataset.action }, a.name + ": " + t.textContent.trim()); };
      if (t.dataset.confirm) confirmBox(a.name, h(t.dataset.confirm), t.textContent.trim(), "", go); else go();
    } else if (what === "uninstall") {
      confirmBox("Uninstall " + a.name + "?", "Its uninstall script runs and it stops. It stays in the list, so you can install it again.", "Uninstall",
        '<label class="toggle" style="margin-bottom:14px"><input type="checkbox" id="cfPurge"><i></i><span>Also delete its data<small>Logins, settings and anything else it kept. Cannot be undone.</small></span></label>',
        function () { runJob(a, "uninstall", { keep_data: !$("#cfPurge").checked }, "Uninstalling " + a.name); });
    } else if (what === "remove") {
      F.api("/api/addons/" + encodeURIComponent(a.id) + "/remove", { body: {} }).then(function () {
        F.toast("Removed " + a.name, "", "ok"); load();
      }).catch(function (e) { F.toast("Could not remove it", e.message, "bad"); });
    }
  });

  document.addEventListener("DOMContentLoaded", function () {
    $("#addonForm").addEventListener("submit", function (ev) { ev.preventDefault(); addSource($("#addonSrc").value); });
    $("#addonExample").addEventListener("click", function () { $("#addonSrc").value = EXAMPLE; addSource(EXAMPLE); });
    load().then(schedule);
  });

  window.ForgeAddons = {
    show: function () { render(); load(); schedule(); }
  };
})();
