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
      if (F.view() === "addons" && !A.list) $("#addonList").innerHTML = '<div class="warnbox bad">' + h(e.message) + "</div>";
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
    var main = "";
    if (!a.installed) {
      main = '<button class="btn primary" data-ad="install" data-id="' + h(a.id) + '"' + (busy || a.problems.length ? " disabled" : "") + ">" +
        (found ? F.I.plug + " Link it" : F.I.save + " Install") + "</button>";
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
    menu.push('<button data-ad="update" data-id="' + h(a.id) + '">' + F.I.upd + (a.installed ? "Update" : "Fetch again") + "</button>");
    (a.links || []).forEach(function (l) {
      menu.push('<a href="' + h(l.url) + '" target="_blank" rel="noopener">' + F.I.open + h(l.label) + "</a>");
    });
    if (a.homepage) menu.push('<a href="' + h(a.homepage) + '" target="_blank" rel="noopener">' + F.I.globe + "Homepage</a>");
    menu.push("<hr>");
    if (a.installed) menu.push('<button class="danger" data-ad="uninstall" data-id="' + h(a.id) + '">' + F.I.unplug + "Uninstall</button>");
    else menu.push('<button class="danger" data-ad="remove" data-id="' + h(a.id) + '">' + F.I.trash + "Remove from the list</button>");

    return '<article class="ad' + (a.installed ? " on" : "") + (busy ? " busy" : "") + '" data-id="' + h(a.id) + '">' +
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
      (a.installed && st.detail && st.state !== "error" ? '<div class="ad-status mono">' + h(st.detail) + "</div>" : "") +
      '<div class="ad-foot">' + main +
        (a.update_pending ? '<button class="btn" data-ad="update" data-id="' + h(a.id) + '">' + F.I.upd + " Update</button>" : "") +
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
      log: function (d) { line(d.line, d.stream === "err" ? "e" : ""); },
      phase: function (d) { prog(d.progress, d.label); line("▸ " + d.label, "i"); },
      progress: function (d) { prog(d.progress); },
      done: function (d) { finish(true, d); },
      error: function (d) { if (d && d.message) { line(d.message, "e"); finish(false, d); } },
      final: function (s) { if (s.status === "done") finish(true, s.result); else if (s.status !== "running") finish(false, s.error); }
    });
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
    if (what === "install") installForm(a);
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
