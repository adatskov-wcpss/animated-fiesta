
# =========================================================================
#  engine plumbing
# =========================================================================

engine() { "$PY" "$FORGE_APP/engine.py" "$@"; }

ensure_dirs() { mkdir -p "$FORGE_HOME" "$FORGE_APP" "$FORGE_STATE" "$FORGE_LOGS"; }

# A second copy of the forge must not fight the first one over ports.
singleton_check() {
  local sj="$FORGE_STATE/server.json" pid url
  [ -f "$sj" ] || return 0
  pid=$("$PY" -c "import json;print(json.load(open('$sj')).get('pid',''))" 2>/dev/null)
  url=$("$PY" -c "import json;print(json.load(open('$sj')).get('url',''))" 2>/dev/null)
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    title "Already running" "a forge web UI is live as pid $pid"
    info "$url"
    local act
    act=$(menu_choose "What now?" \
      $'open\tUse the running one\tprint the link and exit' \
      $'kill\tStop it and carry on\tfrees the port' \
      $'ignore\tLeave it, start another\ta second UI on another port')
    case "$act" in
      open) printf '\n'; ok "web UI: $url"; exit 0 ;;
      kill) kill "$pid" 2>/dev/null; sleep 1; rm -f "$sj"; ok "stopped pid $pid" ;;
      *) : ;;
    esac
  else
    rm -f "$sj"
  fi
}

# =========================================================================
#  launching, with a live progress bar
# =========================================================================

render_result() {
  "$PY" - "$1" <<'PYEOF'
import json, sys, os
d = json.loads(sys.argv[1])
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s):
    return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
rows = []
tun = d.get("tunnel") or {}
if tun.get("url"):
    rows.append(("public link", tun["url"],
                 "serveo " + tun.get("mode", "http") +
                 (" (anonymous TCP tunnels are short lived)" if tun.get("mode") == "tcp" else "")))
rows.append(("on this box", d.get("local_url"), "no tunnel needed"))
if d.get("https_url"):
    rows.append(("local https", d["https_url"], "for other devices on your LAN"))
cred = d.get("credentials")
if cred:
    rows.append(("sign in", "%s / %s" % (cred["user"], cred["password"]), ""))
plan = d.get("plan") or {}
rows.append(("container", d.get("name"), "docker name"))
rows.append(("ports", ", ".join(str(p) for p in d.get("ports") or []), "picked free on this host"))
rows.append(("memory", "%d MB" % plan.get("memory_mb", 0), "hard cap"))
rows.append(("cpu", "%s cores" % plan.get("cpus"), "hard cap"))
rows.append(("shared mem", "%d MB" % plan.get("shm_mb", 0), "/dev/shm"))
rows.append(("storage", "%d MB" % plan.get("disk_mb", 0),
             "enforced" if d.get("quota_enforced") else "tracked, not enforced here"))
rows.append(("image", d.get("image"), ""))
sess = d.get("session") or {}
if sess.get("wm"):
    rows.insert(0, ("desktop", "%s is up" % sess["wm"],
                    "screen " + ("follows your window" if d.get("display") == "fit"
                                 else (d.get("display") or "") + ", scaled to fit")))
print()
if d.get("warning"):
    print("  " + c("1;38;5;221", "▰ STARTED, WITH A PROBLEM") + "  " + c("2", (d.get("entry") or {}).get("name", "")))
else:
    print("  " + c("1;38;5;79", "▰ READY") + "  " + c("2", (d.get("entry") or {}).get("name", "")))
print("  " + c("2", "─" * 66))
if d.get("warning"):
    import textwrap
    for ln in textwrap.wrap(d["warning"], 70):
        print("  " + c("38;5;221", ln))
    for ln in ((sess.get("log") or "").strip().splitlines()[-8:]):
        print("    " + c("2", ln[:100]))
    print("  " + c("2", "─" * 66))
fx = {"memory": "gave it more memory", "shm": "more shared memory", "seccomp": "relaxed seccomp",
      "slow": "waited longer for a slow first boot", "restart": "restarted it once"}
if d.get("fixes"):
    print("  %s %s" % (c("38;5;79", "\u2714 fixed on the way:"), ", ".join(fx.get(f, f) for f in d["fixes"])))
for k, v, note in rows:
    if not v:
        continue
    line = "  %s %s" % (c("2", "%-12s" % k), c("1;38;5;75", v) if "link" in k or "http" in str(v)[:5] else v)
    if note:
        line += "  " + c("2", "· " + note)
    print(line)
print()
print("  " + c("2", "next:") + "  open the link above, or run this script again for the manager")
print()
PYEOF
}

stream_launch() {
  local id="$1"; shift
  stream_job_view launch "Forging $id" launch "$id" "$@"
}

# Run an engine command that streams a job (launch, clone, backup, restore)
# and draw it: a progress bar, the log scrolling above it, then the result.
# Ctrl-C reaches the engine, which cancels the job and cleans up.
stream_job_view() {
  local kind="$1" heading="$2"; shift 2
  local -a eargs=("$@")
  local pct=0 phase="working" result="" failed=0
  local log="$FORGE_LOGS/$kind-$(date +%Y%m%d-%H%M%S).log"

  title "$heading" "live output below, full log at $log"
  printf '%s' "$HIDE"

  while IFS= read -r line; do
    printf '%s' "$line" >>"$log"
    printf '\n' >>"$log"
    case "$line" in
      P\ *)
        local _t p ph rest
        read -r _t p ph rest <<<"$line"
        pct="$p"; phase="${rest:-$ph}"
        bar "$pct" "$phase"
        ;;
      L\ *)
        printf '%s  %s%s%s\n' "$CLRL" "$DIM" "$(printf '%.160s' "${line#L }")" "$NC"
        bar "$pct" "$phase"
        ;;
      D\ *) result="${line#D }" ;;
      E\ *) failed=1; printf '%s' "$CLRL"; bad "${line#E }" ;;
      H\ *) printf '%s' "$CLRL"; info "try: ${line#H }" ;;
      *) : ;;
    esac
  done < <(engine "${eargs[@]}" 2>&1)

  printf '%s%s' "$CLRL" "$SHOW"
  if [ -n "$result" ]; then
    case "$kind" in
      launch|clone) FORGE_COLOR=$COLOR render_result "$result" ;;
      addon) printf '%s' "$result" | "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
what = "linked" if d.get("adopted") else "done"
print("  \u2714 %s: %s" % (d.get("name") or d.get("id") or "addon", what))
for w in d.get("warnings") or []:
    print("  ! %s" % w)
if d.get("open_url"):
    print("    open it: %s" % d["open_url"])
' ;;
      *) printf '%s' "$result" | "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
b = d.get("backup") or {}
if b:
    print("  \u2714 backed up %s: %s (%.1f MB)" % (d.get("name"), b.get("file"), (b.get("size") or 0) / 1048576.0))
elif d.get("safety"):
    print("  \u2714 restored %s from %s" % (d.get("name"), d.get("file")))
    print("    the files from before are kept in %s" % d["safety"])
else:
    print("  \u2714 done")
' ;;
    esac
    printf '\n'
    return 0
  fi
  [ "$failed" = 1 ] && printf '\n  %sthe full log is at %s%s\n\n' "$DIM" "$log" "$NC"
  return 1
}

# Ask about resources, then launch.
configure_and_launch() {
  local id="$1"
  local info_json plan_mem plan_cpu plan_shm plan_disk name ram_free cores
  info_json=$(engine info "$id" 2>/dev/null)
  [ -n "$info_json" ] || { bad "unknown entry: $id"; return 1; }

  eval "$("$PY" - "$info_json" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
p = d["plan"]
def q(s): return str(s).replace("'", "")
print("E_NAME='%s'" % q(d["name"]))
print("E_DESC='%s'" % q(d["desc"][:150]))
print("E_KIND='%s'" % q(d["kind"]))
print("E_PROFILE='%s'" % q(d["profile"]))
print("E_DL=%d" % d["dl_mb"])
print("E_DISK=%d" % d["disk_mb"])
print("E_RAMMIN=%d" % d["ram_min"])
print("P_MEM=%d" % p["memory_mb"])
print("P_CPU=%s" % p["cpus"])
print("P_SHM=%d" % p["shm_mb"])
print("P_DISK=%d" % p["disk_mb"])
PYEOF
)"

  title "$E_NAME" "$E_DESC"
  info "$([ "$E_KIND" = pull ] && echo "prebuilt image" || echo "built on this machine") · about $((E_DL)) MB to download · roughly $((E_DISK)) MB on disk"
  printf '\n'

  local disk_gb=$((P_DISK / 1024))
  if confirm "Use the suggested resources (${P_MEM} MB RAM, ${P_CPU} cores, ${disk_gb} GB storage)?" y; then
    :
  else
    P_MEM=$(ask "memory in MB (floor ${E_RAMMIN})" "$P_MEM")
    P_CPU=$(ask "cpu cores" "$P_CPU")
    P_SHM=$(ask "shared memory in MB" "$P_SHM")
    P_DISK=$(ask "storage budget in MB" "$P_DISK")
  fi
  name=$(ask "name for this instance (blank = auto)" "")

  local -a args=(--memory "$P_MEM" --cpus "$P_CPU" --shm "$P_SHM" --disk "$P_DISK")
  [ -n "$name" ] && args+=(--name "$name")

  # Sign-in. Without this anyone who reaches the URL is already inside.
  local want_auth=n
  [ "$E_PROFILE" = "kasm" ] && want_auth=y
  if confirm "Set a username and password for this desktop?" "$want_auth"; then
    local u pw
    if [ "$E_PROFILE" = "kasm" ]; then
      u="kasm_user"
      info "this image always signs you in as kasm_user"
    else
      u=$(ask "username" "forge")
    fi
    pw=$(ask "password (blank generates one)" "")
    if [ -z "$pw" ]; then
      pw=$("$PY" -c "import secrets,string
a = string.ascii_letters + string.digits
print(''.join(secrets.choice(a) for _ in range(16)))")
      info "generated password: $pw"
      warn "write it down, it is set inside the container and cannot be read back"
    fi
    args+=(--user "$u" --password "$pw")
  fi
  if [ "$NO_TUNNEL" = 1 ]; then
    args+=(--no-tunnel)
  elif ! confirm "Open a public serveo tunnel?" y; then
    args+=(--no-tunnel)
  fi
  if confirm "Start it automatically whenever Docker starts (after a reboot)?" n; then
    args+=(--autostart)
  fi
  stream_launch "$id" "${args[@]}"
}

# =========================================================================
#  catalog pickers
# =========================================================================

catalog_menu_items() {  # args passed to `engine list`
  engine list "$@" --format tsv 2>/dev/null | "$PY" -c '
import sys
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    if len(f) < 12:
        continue
    eid, name, fam, de, kind, weight, dl, ram, cpu, beauty, sub, desc = f[:12]
    dl = int(dl); ram = int(ram)
    tag = "ready" if kind == "pull" else "build"
    hint = "%-9s %5s MB dl  %5s MB ram  %s cores  %s" % (weight, dl, ram, cpu, tag)
    print("%s\t%s\t%s" % (eid, "%s  (%s)" % (name, de), hint))
'
}

pick_quick() {
  local -a items
  mapfile -t items < <(catalog_menu_items --quick --runnable)
  [ ${#items[@]} -eq 0 ] && { bad "no catalog entries run on this architecture"; return 1; }
  local choice
  choice=$(menu_choose "Hand picked desktops" "${items[@]}") || return 1
  [ -n "$choice" ] && configure_and_launch "$choice"
}

pick_family() {
  local -a fams
  mapfile -t fams < <(engine list --runnable 2>/dev/null | "$PY" -c '
import json, sys, collections
d = json.load(sys.stdin)
c = collections.Counter(e["family"] for e in d["entries"])
lab = {}
for e in d["entries"]:
    lab[e["family"]] = e["family_label"]
for fam, n in c.most_common():
    print("%s\t%s\t%d desktops" % (fam, lab[fam], n))
')
  local fam
  fam=$(menu_choose "Which family?" "${fams[@]}") || return 1
  local -a items
  mapfile -t items < <(catalog_menu_items --runnable --family "$fam")
  local choice
  choice=$(menu_choose "$fam desktops" "${items[@]}") || return 1
  [ -n "$choice" ] && configure_and_launch "$choice"
}

pick_search() {
  local term
  term=$(ask "search for" "")
  [ -z "$term" ] && return 1
  local -a items
  mapfile -t items < <(catalog_menu_items --runnable | grep -i -- "$term")
  if [ ${#items[@]} -eq 0 ]; then warn "nothing matched '$term'"; return 1; fi
  local choice
  choice=$(menu_choose "Matches for '$term'" "${items[@]}") || return 1
  [ -n "$choice" ] && configure_and_launch "$choice"
}

cmd_smart() {
  title "Let it choose" "scored against this machine's free memory, cores and disk"
  local taste purpose
  taste=$(menu_choose "What matters most?" \
    $'balanced\tBalanced\tan even trade between looks and lightness' \
    $'beautiful\tBeautiful\tthe prettiest thing that still runs well' \
    $'lightest\tLightest\tsmallest footprint that is still pleasant' \
    $'fastest\tFastest\tlowest latency over the stream') || return 1
  purpose=$(menu_choose "What for?" \
    $'general\tAnything\tno particular slant' \
    $'dev\tWriting code\tfavours tooling-friendly bases' \
    $'security\tSecurity work\tKali and Parrot style images' \
    $'retro\tRetro and tiny\told school window managers' \
    $'media\tMedia\tricher desktops') || return 1

  spin_start "weighing every entry against this machine"
  local out
  out=$(engine smart --taste "$taste" --purpose "$purpose" --limit 3 2>/dev/null)
  spin_stop

  local -a items
  mapfile -t items < <(printf '%s' "$out" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
for p in d["picks"]:
    e = p["entry"]
    print("%s\t%s  (%s)\tscore %.0f  ·  %s" % (
        p["id"], e["name"], e["de_label"], p["score"], p["why"][0]))
')
  if [ ${#items[@]} -eq 0 ]; then
    warn "nothing in the catalog fits this machine right now"
    return 1
  fi
  printf '%s' "$out" | "$PY" -c '
import json, sys, os
d = json.load(sys.stdin)
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
print()
for i, p in enumerate(d["picks"]):
    e = p["entry"]
    print("  %s %s  %s" % (c("1;38;5;141", "%d." % (i + 1)), c("1", e["name"]),
                           c("2", "score %.0f" % p["score"])))
    for w in p["why"]:
        print("     %s %s" % (c("2", "·"), w))
    pl = p["plan"]
    print("     %s" % c("2", "plan: %d MB RAM · %s cores · %d MB shm" % (
        pl["memory_mb"], pl["cpus"], pl["shm_mb"])))
    print()
' FORGE_COLOR=$COLOR
  local choice
  choice=$(menu_choose "Forge which one?" "${items[@]}") || return 1
  [ -n "$choice" ] && configure_and_launch "$choice"
}

# =========================================================================
#  manager
# =========================================================================

print_instances() {
  engine instances 2>/dev/null | "$PY" -c '
import json, sys, os
d = json.load(sys.stdin)
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
items = d["instances"]
if not items:
    print("\n  nothing forged yet\n")
    raise SystemExit(0)
print()
for i in items:
    state = "running" if i["running"] else (i.get("status") or "stopped")
    dot = c("38;5;79", "●") if i["running"] else c("2", "○")
    print("  %s %s  %s" % (dot, c("1", i["title"]), c("2", i["name"])))
    print("     %s %s" % (c("2", "%-9s" % "state"), state))
    if i.get("local_url"):
        print("     %s %s" % (c("2", "%-9s" % "local"), c("38;5;75", i["local_url"])))
    t = i.get("tunnel") or {}
    if t.get("url"):
        print("     %s %s %s" % (c("2", "%-9s" % "tunnel"), c("38;5;75", t["url"]),
                                 "" if t.get("alive") else c("38;5;203", "(down)")))
    lim = i.get("limits") or {}
    print("     %s %s MB ram cap · %s cores · ports %s" % (
        c("2", "%-9s" % "limits"), lim.get("memory_mb"), lim.get("cpus"),
        ", ".join(str(v) for v in (i.get("ports") or {}).values())))
    print()
' FORGE_COLOR=$COLOR
}

cmd_manager() {
  while :; do
    title "Manager" "every desktop this forge has built"
    print_instances
    local -a items
    mapfile -t items < <(engine instances 2>/dev/null | "$PY" -c '
import json, sys
for i in json.load(sys.stdin)["instances"]:
    st = "running" if i["running"] else (i.get("status") or "stopped")
    print("%s\t%s\t%s · %s" % (i["name"], i["title"], st, i["name"]))
')
    if [ ${#items[@]} -eq 0 ]; then
      confirm "Nothing to manage. Forge one now?" y && { pick_quick; continue; }
      return 0
    fi
    items+=($'__stats\tLive stats\tcpu, memory and bandwidth right now')
    items+=($'__back\tBack\treturn to the main menu')
    local pick
    pick=$(menu_choose "Pick an instance" "${items[@]}") || return 0
    case "$pick" in
      __back|"") return 0 ;;
      __stats)
        spin_start "sampling docker stats"
        local s; s=$(engine stats 2>/dev/null)
        spin_stop
        printf '%s' "$s" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)["stats"]
if not d:
    print("\n  no running instances\n"); raise SystemExit
print()
print("  %-26s %7s %12s %12s %12s" % ("instance", "cpu", "memory", "net in", "net out"))
print("  " + "-" * 74)
def human(n):
    n = float(n or 0)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024: return "%.1f %s" % (n, u)
        n /= 1024
    return "%.1f PB" % n
for name, v in sorted(d.items()):
    print("  %-26s %6.1f%% %12s %12s %12s" % (
        name[:26], v["cpu"], "%d/%d MB" % (v["mem_mb"], v["mem_limit_mb"]),
        human(v["rx_total"]), human(v["tx_total"])))
print()
'
        [ -n "$TTY_IN" ] && read -r -p "  press enter " _ <"$TTY_IN"
        ;;
      *)
        local act
        act=$(menu_choose "$pick" \
          $'open\tShow its links\tlocal and tunnel URLs' \
          $'shell\tOpen a shell in it\tdocker exec' \
          $'tunnel\tOpen or replace the tunnel\tfresh serveo URL' \
          $'untunnel\tDrop the tunnel\tkeep it local only' \
          $'limits\tChange limits\tmemory, cpu, shared memory, storage' \
          $'autostart\tToggle auto-start\tcome back after a reboot, or not' \
          $'restart\tRestart it\t' \
          $'stop\tStop it\t' \
          $'start\tStart it\t' \
          $'logs\tShow recent logs\tlast 120 lines' \
          $'events\tWhat happened to it\tlaunches, crashes, heals, repairs' \
          $'backup\tBack up its files\ta copy of its home folder' \
          $'clone\tClone it\ta second desktop with a copy of its files' \
          $'idle\tStop it when idle\twhen nobody has had it open for a while' \
          $'repair\tRepair it\trecreate on the newest forge layer; files are kept' \
          $'remove\tRemove it\tasks about the data volume too' \
          $'back\tBack\t') || continue
        case "$act" in
          back|"") : ;;
          open) print_instances ;;
          shell)
            printf '\n'; info "handing you a shell inside $pick, type exit to come back"; printf '\n'
            if [ -z "$TTY_IN" ]; then
              warn "a shell needs a terminal; run this script from one"
            else
              docker exec -it "$pick" /bin/sh -c 'if command -v bash >/dev/null 2>&1; then exec bash -l; else exec /bin/sh -l; fi' <"$TTY_IN"
            fi
            ;;
          logs) engine logs "$pick" --tail 120 | sed 's/^/    /' ;;
          events) engine events --name "$pick" --limit 30 | sed 's/^/    /' ;;
          backup) cmd_backup "$pick" ;;
          clone) cmd_clone "$pick" "$(ask "name for the copy" "${pick#forge-}-copy")" ;;
          idle) cmd_idle "$pick" "$(ask "minutes with nobody watching (0 = never)" "60")" ;;
          limits)
            local cur; cur=$(engine instances 2>/dev/null | "$PY" -c "
import json,sys
for i in json.load(sys.stdin)['instances']:
    if i['name']=='$pick':
        l=i.get('limits') or {}
        print(l.get('memory_mb') or 1024, l.get('cpus') or 1, l.get('shm_mb') or 256, i.get('disk_cap_mb') or 10240)")
            local cm cc cs cd nm nc ns nd
            read -r cm cc cs cd <<<"$cur"
            nm=$(ask "memory in MB" "$cm"); nc=$(ask "cpu cores" "$cc")
            ns=$(ask "shared memory in MB (browsers want 512+)" "$cs"); nd=$(ask "storage in MB" "$cd")
            if [ "$ns" != "$cs" ] || [ "$nd" != "$cd" ]; then
              info "shared memory and storage need the desktop recreated; files in /config are kept"
            fi
            spin_start "applying limits to $pick"
            local r; r=$(engine retune "$pick" --memory "$nm" --cpus "$nc" --shm "$ns" --disk "$nd" 2>&1)
            spin_stop
            if printf '%s' "$r" | grep -q '"error"'; then bad "$r"
            elif printf '%s' "$r" | grep -q '"recreated": true'; then ok "recreated $pick with the new limits"
            else ok "limits applied live"; fi
            ;;
          autostart)
            local now; now=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$pick" 2>/dev/null)
            if [ "$now" = "no" ] || [ -z "$now" ]; then
              engine retune "$pick" --autostart on >/dev/null && ok "$pick now starts with Docker"
            else
              engine retune "$pick" --autostart off >/dev/null && ok "$pick only starts when you start it"
            fi
            ;;
          remove)
            if confirm "Remove $pick?" n; then
              local purge=""
              confirm "Also delete its saved /config volume?" n && purge="--purge"
              engine do "$pick" remove $purge >/dev/null && ok "removed $pick"
            fi
            ;;
          *)
            spin_start "$act $pick"
            local r; r=$(engine do "$pick" "$act" 2>&1)
            spin_stop
            if printf '%s' "$r" | grep -q '"error"'; then
              bad "$(printf '%s' "$r" | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("error",""))' 2>/dev/null)"
            else
              ok "$act done"
              printf '%s' "$r" | "$PY" -c '
import json,sys
try:
    t=(json.load(sys.stdin).get("tunnel") or {}).get("url")
    if t: print("    " + t)
except Exception: pass
' 2>/dev/null
            fi
            ;;
        esac
        [ -n "$TTY_IN" ] && read -r -p "  press enter " _ <"$TTY_IN"
        ;;
    esac
  done
}

# =========================================================================
#  web UI
# =========================================================================

cmd_webui() {
  title "Web UI" "the full catalog, live build output and the instance manager"
  local args=(serve --port "$WEBUI_PORT" --bind "$WEBUI_BIND")
  [ "$WEBUI_EXPOSE" = 1 ] && args+=(--tunnel)

  if [ "$WEBUI_BIND" != "127.0.0.1" ] || [ "$WEBUI_EXPOSE" = 1 ]; then
    warn "this exposes docker control beyond localhost; anyone who can reach it controls docker"
  fi

  # Always start it detached, then decide whether to sit on it or hand the
  # shell back. setsid keeps it alive if this script exits.
  local log="$FORGE_LOGS/webui.log"
  : > "$log"
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$PY" "$FORGE_APP/engine.py" "${args[@]}" >>"$log" 2>&1 </dev/null &
  else
    nohup "$PY" "$FORGE_APP/engine.py" "${args[@]}" >>"$log" 2>&1 </dev/null &
  fi
  disown 2>/dev/null

  spin_start "starting the engine"
  local info_json="" i=0
  while [ "$i" -lt 900 ]; do
    info_json=$(grep -m1 '^{' "$log" 2>/dev/null)
    [ -n "$info_json" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  spin_stop

  if [ -z "$info_json" ]; then
    bad "the web UI did not start"
    [ -s "$log" ] && sed 's/^/    /' "$log" | tail -12
    return 1
  fi

  local srv_pid srv_url
  srv_pid=$(printf '%s' "$info_json" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["pid"])')
  srv_url=$(printf '%s' "$info_json" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["url"])')

  printf '%s' "$info_json" | "$PY" -c '
import json, sys, os
d = json.load(sys.stdin)
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
print()
print("  " + c("1;38;5;79", "▰ WEB UI IS UP"))
print("  " + c("2", "─" * 56))
print("  %s %s" % (c("2", "%-10s" % "local"), c("1;38;5;75", d["url"])))
if d.get("tunnel"):
    print("  %s %s" % (c("2", "%-10s" % "public"), c("1;38;5;75", d["tunnel"])))
if d.get("tunnel_error"):
    print("  %s %s" % (c("2", "%-10s" % "tunnel"), "failed: " + d["tunnel_error"]))
print("  %s %s" % (c("2", "%-10s" % "pid"), d["pid"]))
print()
' FORGE_COLOR=$COLOR

  command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ] && \
    xdg-open "$srv_url" >/dev/null 2>&1 &

  ask_boot_once

  # Background, or hold the terminal until ctrl-c?
  local mode="$WEBUI_MODE"
  if [ -z "$mode" ]; then
    if [ -n "$TTY_IN" ]; then
      mode=$(menu_choose "Leave it running?" \
        $'bg\tRun it in the background\tyou get your shell back, the UI keeps serving' \
        $'fg\tHold this terminal\tstays in the foreground until ctrl-c') || mode="bg"
    else
      mode="fg"
    fi
  fi

  if [ "$mode" = "bg" ]; then
    printf '\n'
    ok "running in the background as pid $srv_pid"
    info "open:          $srv_url"
    info "stop it with:  $FORGE_RUN --stop"
    info "           or:  kill $srv_pid"
    info "log:           $log"
    printf '\n  %syour shell is back · the forge menu has exited so the prompt is yours%s\n\n' \
      "$DIM" "$NC"
    # Leaving the menu running would just redraw it over the shell we were
    # asked to hand back, which looks like the whole thing restarted.
    exit 0
  fi

  printf '\n  %sholding this terminal · ctrl-c stops the web UI%s\n' "$DIM" "$NC"
  printf '  %srunning desktops are not affected%s\n\n' "$DIM" "$NC"
  local stopping=0
  trap 'stopping=1' INT
  while kill -0 "$srv_pid" 2>/dev/null; do
    [ "$stopping" = 1 ] && break
    sleep 1
  done
  trap - INT
  if [ "$stopping" = 1 ]; then
    engine stop-request ctrl-c >/dev/null 2>&1
    kill "$srv_pid" 2>/dev/null
    printf '\n'
    ok "web UI stopped"
  else
    warn "the web UI exited on its own, see $log"
  fi
  [ "$FORGE_FROM_MENU" = 1 ] && printf '  %sback to the forge menu%s\n' "$DIM" "$NC"
  printf '\n'
}

cmd_stop() {
  local sj="$FORGE_STATE/server.json" pid
  if [ ! -f "$sj" ]; then
    warn "no web UI is recorded as running"
    return 1
  fi
  pid=$("$PY" -c "import json;print(json.load(open('$sj')).get('pid',''))" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # Tell it why, so the next start can say "you stopped it" rather than guess.
    engine stop-request "${FORGE_STOP_REASON:-user}" >/dev/null 2>&1
    kill "$pid" 2>/dev/null
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    ok "stopped the web UI (pid $pid)"
  else
    warn "the recorded web UI (pid ${pid:-?}) is not running"
  fi
  rm -f "$sj"
  info "running desktops are untouched; use --manager to see them"
}

# =========================================================================
#  doctor / uninstall
# =========================================================================

cmd_doctor() {
  title "This machine" "what the forge checked before offering you anything"
  engine doctor | "$PY" -c '
import json, sys, os
d = json.load(sys.stdin)
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
for ch in d["checks"]:
    if ch["ok"]:
        mark = c("38;5;79", "✔")
    elif ch.get("severity") == "info":
        mark = c("38;5;75", "·")
    else:
        mark = c("38;5;221", "!")
    print("  %s %-14s %s" % (mark, ch["name"], ch["detail"]))
    if not ch["ok"] and ch.get("fix") and ch.get("severity") != "info":
        print("    %s" % c("2", "fix: " + ch["fix"]))
h = d["host"]
print()
print("  " + c("2", "%s · %s · %d cores · %d MB free of %d MB · docker %s" % (
    h.get("os_pretty"), h["arch"], h["cpus"], h["mem_avail_mb"], h["mem_total_mb"],
    h.get("docker_version"))))
print()
' FORGE_COLOR=$COLOR
}

cmd_uninstall() {
  title "Uninstall" "removes containers, images and the forge directory"
  warn "this deletes every desktop this forge created"
  confirm "Really remove everything?" n || return 0
  local names
  names=$(docker ps -aq --filter "label=io.selkiesforge.entry" 2>/dev/null)
  if [ -n "$names" ]; then
    spin_start "removing containers"
    docker rm -f $names >/dev/null 2>&1
    spin_stop
    ok "containers removed"
  fi
  if confirm "Also delete the built images and data volumes?" n; then
    spin_start "removing images and volumes"
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^selkies-forge/' | \
      xargs -r docker rmi -f >/dev/null 2>&1
    docker volume ls -q 2>/dev/null | grep '^forge-config-' | xargs -r docker volume rm -f >/dev/null 2>&1
    spin_stop
    ok "images and volumes removed"
  fi
  local cli; cli=$(cat "$FORGE_STATE/cli-path" 2>/dev/null)
  if [ -n "$cli" ] && grep -q 'Installed by docker.sh' "$cli" 2>/dev/null; then
    rm -f "$cli" && ok "removed the selkies-cli command ($cli)"
  fi
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$rc" ] && grep -q '# >>> selkies-forge >>>' "$rc" 2>/dev/null; then
      sed -i '/# >>> selkies-forge >>>/,/# <<< selkies-forge <<</d' "$rc" && ok "cleaned the PATH line from $rc"
    fi
  done
  engine boot disable >/dev/null 2>&1
  rm -rf "$FORGE_HOME"
  ok "removed $FORGE_HOME"
  printf '\n  %sthanks for using the forge%s\n\n' "$DIM" "$NC"
}

# =========================================================================
#  main menu
# =========================================================================

# Older versions created every desktop with --restart unless-stopped, so they
# all came back whenever Docker or the machine restarted. Offer to undo that once.
review_autostart() {
  local marker="$FORGE_STATE/autostart-reviewed"
  [ -f "$marker" ] && return 0
  local names
  names=$(docker ps -a --filter "label=io.selkiesforge.entry" \
    --format '{{.Names}}' 2>/dev/null | while read -r n; do
      [ -n "$n" ] || continue
      p=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$n" 2>/dev/null)
      [ "$p" != "no" ] && [ -n "$p" ] && printf '%s ' "$n"
    done)
  if [ -z "$names" ]; then touch "$marker"; return 0; fi
  title "Desktops that start on their own" "these come back every time Docker or this machine restarts"
  for n in $names; do info "$n"; done
  if confirm "Stop them starting automatically? (you can turn it back on per desktop)" y; then
    for n in $names; do docker update --restart no "$n" >/dev/null 2>&1 && ok "$n: auto-start off"; done
  else
    info "left as they are; change any of them later in the manager"
  fi
  # Only remember the question once it has actually been answered.
  touch "$marker"
}

# =========================================================================
#  the selkies-cli command
# =========================================================================

# A small wrapper on your PATH that runs the copy of this front end unpacked
# next to the engine. That copy exists even after "curl ... | bash", where no
# copy of this script is ever saved to disk.
cli_bin_dir() {
  if [ -n "${FORGE_BIN_DIR:-}" ]; then printf '%s' "$FORGE_BIN_DIR"; return; fi
  local d
  for d in "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in
      *":$d:"*) if [ -d "$d" ] && [ -w "$d" ]; then printf '%s' "$d"; return; fi ;;
    esac
  done
  if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then printf '%s' /usr/local/bin; return; fi
  printf '%s' "$HOME/.local/bin"
}

add_path_to_rc() {
  local dir="$1" rc added=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || [ "$rc" = "$HOME/.bashrc" ] || continue
    grep -q '# >>> selkies-forge >>>' "$rc" 2>/dev/null && continue
    {
      printf '\n# >>> selkies-forge >>>\n'
      printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$dir" "$dir"
      printf '# <<< selkies-forge <<<\n'
    } >>"$rc" 2>/dev/null && added=1
  done
  [ "$added" = 1 ] && CLI_RC_ADDED=1
  return 0
}

install_cli() {
  local dir target body
  dir=$(cli_bin_dir)
  target="$dir/selkies-cli"
  body="#!/usr/bin/env bash
# selkies-cli: brings Selkies Forge back up. Installed by docker.sh.
export FORGE_HOME=\"\${FORGE_HOME:-$FORGE_HOME}\"
if [ ! -f \"\$FORGE_HOME/app/selkies-cli\" ]; then
  echo \"selkies-cli: Selkies Forge is no longer installed in \$FORGE_HOME.\" >&2
  echo \"Reinstall it with: curl -fsSL $FORGE_URL | bash\" >&2
  exit 1
fi
exec bash \"\$FORGE_HOME/app/selkies-cli\" \"\$@\""

  if [ -e "$target" ] && ! grep -q 'Installed by docker.sh' "$target" 2>/dev/null; then
    warn "$target already exists and is not ours, so selkies-cli was not installed"
    return 1
  fi
  # The command belongs to whichever install made it. A second install in
  # another FORGE_HOME (a test copy, say) must not quietly take it over;
  # it only does if that other install is gone, or you named the folder.
  if [ -f "$target" ] && [ -z "${FORGE_BIN_DIR:-}" ]; then
    local other
    other=$(sed -n 's/^export FORGE_HOME="\${FORGE_HOME:-\(.*\)}"$/\1/p' "$target" 2>/dev/null)
    if [ -n "$other" ] && [ "$other" != "$FORGE_HOME" ] && [ -f "$other/app/selkies-cli" ]; then
      CLI_PATH="$FORGE_APP/selkies-cli"
      FORGE_RUN="bash $CLI_PATH"
      return 0
    fi
  fi
  if [ -f "$target" ] && [ "$(cat "$target")" = "$body" ]; then
    CLI_PATH="$target"
  else
    mkdir -p "$dir" 2>/dev/null
    if ! printf '%s\n' "$body" >"$target" 2>/dev/null; then
      warn "could not write $target, so selkies-cli was not installed"
      return 1
    fi
    chmod 755 "$target"
    CLI_PATH="$target"
    CLI_NEW=1
  fi
  printf '%s' "$CLI_PATH" >"$FORGE_STATE/cli-path"
  case ":$PATH:" in
    *":$dir:"*) FORGE_RUN="selkies-cli" ;;
    *)
      # A directory you picked yourself (FORGE_BIN_DIR) is your business;
      # only the default location gets a PATH line in your shell profile.
      [ -z "${FORGE_BIN_DIR:-}" ] && add_path_to_rc "$dir"
      FORGE_RUN="$CLI_PATH"
      ;;
  esac
  return 0
}

announce_cli() {
  [ "$CLI_NEW" = 1 ] || return 0
  printf '\n'
  ok "installed ${B}selkies-cli${NC}: run it from any terminal to come back here"
  if [ "$CLI_RC_ADDED" = 1 ]; then
    info "added $(dirname "$CLI_PATH") to your PATH in your shell profile;"
    info "open a new terminal first, or run:  export PATH=\"$(dirname "$CLI_PATH"):\$PATH\""
  fi
}

# Quiet when everything is already in place, which is the normal case for
# selkies-cli; the full installers only speak up when something is missing.
preflight() {
  if [ "$FORGE_AS_CLI" = 1 ] && find_python && docker_usable; then
    return 0
  fi
  install_python
  install_docker
  install_extras
}

# =========================================================================
#  status + home screen
# =========================================================================

forge_status_json() { engine status 2>/dev/null || printf '{}'; }

# Turns the status JSON into shell variables the menu can branch on.
status_vars() {
  "$PY" - "$1" <<'PYEOF'
import json, sys
try:
    d = json.loads(sys.argv[1] or "{}")
except Exception:
    d = {}
w = d.get("webui") or {}
def q(v): return "'" + str(v if v is not None else "").replace("'", "") + "'"
print("UI_STATE=" + q(w.get("state", "down")))
print("UI_URL=" + q(w.get("url", "")))
print("UI_PID=" + q(w.get("pid", "")))
print("UI_PORT=" + q(w.get("port", "")))
print("UI_BIND=" + q(w.get("bind", "")))
print("UI_EXPOSED=" + q(1 if w.get("tunnel") else 0))
print("UI_RESTART=" + q(1 if w.get("restart_needed") else 0))
print("UI_LOG=" + q(w.get("log", "")))
print("DOCKER_OK=" + q(1 if d.get("docker") else 0))
print("RUNNING=" + q(d.get("running", 0)))
print("STOPPED=" + q(d.get("stopped", 0)))
print("TOTAL=" + q(len(d.get("desktops") or [])))
ls = d.get("last_stop") or {}
print("LAST_REASON=" + q(ls.get("reason", "")))
print("LAST_CLEAN=" + q(1 if ls.get("clean") else 0))
print("LAST_DISMISSED=" + q(1 if ls.get("dismissed") else 0))
print("RESTORE_N=" + q(len(ls.get("restore") or [])))
b = d.get("boot") or {}
print("BOOT_ON=" + q(1 if b.get("enabled") else 0))
print("BOOT_ASKED=" + q(1 if b.get("asked") else 0))
print("BOOT_METHOD=" + q(b.get("method") or ""))
print("BOOT_LINGER=" + q("" if b.get("linger") is None else (1 if b.get("linger") else 0)))
PYEOF
}

render_status() {
  FORGE_COLOR=$COLOR "$PY" - "$1" <<'PYEOF'
import json, os, sys
try:
    d = json.loads(sys.argv[1] or "{}")
except Exception:
    d = {}
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
def dur(s):
    s = int(s or 0)
    if s < 60: return "%ds" % s
    if s < 3600: return "%dm" % (s // 60)
    if s < 86400: return "%dh %dm" % (s // 3600, s % 3600 // 60)
    return "%dd %dh" % (s // 86400, s % 86400 // 3600)
def short(url):
    if not url: return ""
    host = url.split("://", 1)[-1].split("/")[0]
    head, _, tail = host.partition(".")
    return (head[:8] + "…." + tail) if len(head) > 10 and tail else host

w = d.get("webui") or {}
st = w.get("state", "down")
print()
print("  " + c("1;38;5;255", "Status"))
print("  " + c("2", "─" * 64))
if not d.get("docker", True):
    print("  %s %s  %s" % (c("2", "%-9s" % "Docker"), c("38;5;203", "!"),
                           c("38;5;203", "not answering: " + str(d.get("docker_error") or "")[:60])))
if st == "up":
    print("  %s %s  running at %s  %s" % (c("2", "%-9s" % "Web UI"), c("38;5;79", "●"),
          c("1;38;5;75", w.get("url", "")), c("2", "· up " + dur(w.get("uptime_s")))))
    if w.get("restart_needed"):
        print("  %s %s  %s" % (c("2", "%-9s" % "Update"), c("38;5;141", "\u2726"),
              "a new version is installed; restart the web UI to use it"))
elif st == "stale":
    print("  %s %s  %s  %s" % (c("2", "%-9s" % "Web UI"), c("38;5;221", "!"),
          c("38;5;221", "stopped unexpectedly"), c("2", "· " + (w.get("why") or ""))))
else:
    print("  %s %s  %s" % (c("2", "%-9s" % "Web UI"), c("2", "○"), "not running"))

import time as _t
def when(ts):
    if not ts: return ""
    ago = _t.time() - float(ts)
    stamp = _t.strftime("%H:%M", _t.localtime(float(ts))) if ago < 86400 else \
        _t.strftime("%a %d %b %H:%M", _t.localtime(float(ts)))
    return "%s, %s ago" % (stamp, dur(ago))
ls = d.get("last_stop") or {}
if ls and not ls.get("dismissed"):
    clean = ls.get("clean")
    col = "38;5;79" if clean else ("38;5;203" if ls.get("reason") in ("host-crash", "crash", "oom", "error") else "38;5;221")
    head = "Last time" if st == "up" else "Stopped"
    print("  %s %s  %s  %s" % (c("2", "%-9s" % head), c(col, "●" if clean else "!"),
          ls.get("label", ""), c("2", "· " + when(ls.get("at") or ls.get("last_seen")))))
    if ls.get("boot_changed") and ls.get("boot_time"):
        print("  %s    %s" % (" " * 9, c("2", "machine up since " + _t.strftime("%a %H:%M", _t.localtime(ls["boot_time"])))))
    if ls.get("detail") and not clean and ls.get("reason") != "host-crash":
        print("  %s    %s" % (" " * 9, c("2", str(ls["detail"])[:70])))
    if ls.get("restore"):
        n = len(ls["restore"])
        print("  %s    %s" % (" " * 9, c("38;5;221", "%d desktop%s that %s running then %s stopped now" % (
            n, "" if n == 1 else "s", "was" if n == 1 else "were", "is" if n == 1 else "are"))))
b = d.get("boot") or {}
if b.get("enabled"):
    extra = ""
    if b.get("method") == "systemd" and b.get("linger") is False:
        extra = c("38;5;221", " · only after you log in (linger is off)")
    print("  %s %s  %s%s" % (c("2", "%-9s" % "On boot"), c("38;5;79", "●"),
          "the web UI starts by itself (%s)" % b.get("method"), extra))

items = d.get("desktops") or []
run, stop = d.get("running", 0), d.get("stopped", 0)
if not items:
    print("  %s %s  %s" % (c("2", "%-9s" % "Desktops"), c("2", "○"), "none yet"))
else:
    print("  %s %s  %d running · %d stopped" % (c("2", "%-9s" % "Desktops"),
          c("38;5;79", "●") if run else c("2", "○"), run, stop))
    for i in sorted(items, key=lambda x: (not x["running"], x["title"]))[:6]:
        dot = c("38;5;79", "●") if i["running"] else c("2", "○")
        where = i.get("local_url") or "" if i["running"] else c("2", "stopped")
        pub = (c("2", "  public ") + short(i["public_url"])) if i.get("public_url") else ""
        print("     %s %-22.22s %s%s" % (dot, i["title"], where.replace("http://", ""), pub))
    if len(items) > 6:
        print("     " + c("2", "and %d more" % (len(items) - 6)))
print("  " + c("2", "─" * 64))
PYEOF
}

cmd_status() {
  local js; js=$(forge_status_json)
  render_status "$js"
  printf '\n'
}

cmd_open() {
  local js; js=$(forge_status_json)
  eval "$(status_vars "$js")"
  if [ "$UI_STATE" != "up" ]; then
    warn "the web UI is not running"
    if confirm "Start it in the background now?" y; then
      WEBUI_MODE="bg" cmd_webui
    fi
    return 0
  fi
  printf '\n  %s%s%s\n\n' "$B$BLU" "$UI_URL" "$NC"
  if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    xdg-open "$UI_URL" >/dev/null 2>&1 &
    ok "opened in your browser"
  else
    info "open that link in your browser"
  fi
  printf '\n'
}

cmd_restart() {
  local js; js=$(forge_status_json)
  eval "$(status_vars "$js")"
  # Come back on the same address, unless you asked for a different one.
  if [ -n "$UI_PORT" ] && [ "$WEBUI_PORT_SET" != 1 ]; then WEBUI_PORT="$UI_PORT"; fi
  if [ -n "$UI_BIND" ] && [ "$WEBUI_BIND" = "127.0.0.1" ]; then WEBUI_BIND="$UI_BIND"; fi
  [ "$UI_EXPOSED" = 1 ] && WEBUI_EXPOSE=1
  [ "$UI_STATE" = "down" ] || FORGE_STOP_REASON="${FORGE_STOP_REASON:-restart}" cmd_stop >/dev/null 2>&1
  WEBUI_MODE="${WEBUI_MODE:-bg}" cmd_webui
}

cmd_ui_log() {
  local log="$FORGE_LOGS/webui.log"
  title "Web UI log" "$log"
  if [ -s "$log" ]; then tail -n 25 "$log" | sed 's/^/    /'; else info "the log is empty"; fi
  [ -n "$TTY_IN" ] && read -r -p "  press enter " _ <"$TTY_IN"
}

cmd_update() {
  title "Update" "git pull from GitHub, fast-forward only"
  local js; js=$(forge_status_json)
  eval "$(status_vars "$js")"
  spin_start "checking GitHub"
  local r
  r=$(engine check-update --install 2>/dev/null)
  spin_stop
  printf '%s' "$r" | FORGE_COLOR=$COLOR "$PY" -c '
import json, os, sys
d = json.loads(sys.stdin.read() or "{}")
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
via = "git pull" if d.get("method") == "git" else "download"
commit = (d.get("installed_commit") or d.get("remote_commit") or "")[:7]
tag = c("2", "(" + via + (", " + commit if commit else "") + ")")
if d.get("just_installed"):
    print("  %s updated to %s %s" % (c("38;5;79", "\u2714"), d.get("installed_version"), tag))
elif d.get("error"):
    print("  %s %s" % (c("38;5;221", "!"), d["error"]))
else:
    print("  %s already up to date: %s %s" % (c("38;5;79", "\u2714"), d.get("installed_version"), tag))
'
  if printf '%s' "$r" | grep -q '"just_installed": true' && [ "$UI_STATE" = "up" ] && \
     confirm "Restart the web UI so it runs the new version?" y; then
    exec bash "$FORGE_APP/selkies-cli" restart
  fi
}

# selkies-cli keeps itself current: at most once every 5 minutes it asks
# GitHub for a newer build, installs it, and reruns itself on the new code.
# FORGE_AUTO_UPDATE=0 turns this off.
auto_update_cli() {
  [ "${FORGE_AUTO_UPDATE:-1}" = 0 ] && return 0
  local r
  r=$(engine check-update --install --max-age 300 2>/dev/null) || return 0
  if printf '%s' "$r" | grep -q '"just_installed": true'; then
    local v
    v=$(printf '%s' "$r" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("installed_version") or "")' 2>/dev/null)
    ok "updated Selkies Forge to ${v:-the latest version}"
    FORGE_JUST_UPDATED=1 exec bash "$FORGE_APP/selkies-cli" "$@"
  fi
}

pick_new() {
  local choice
  choice=$(menu_choose "Forge a new desktop" \
    $'quick\tFrom the hand picked list\tone strong choice per taste' \
    $'smart\tLet it choose for me\tscored against this machine' \
    $'family\tBrowse by distro family\tUbuntu, Debian, Arch, Alpine, Kali...' \
    $'search\tSearch the catalog\tby name, desktop or tag' \
    $'back\tBack\t') || return 0
  case "$choice" in
    quick) pick_quick ;;
    smart) cmd_smart ;;
    family) pick_family ;;
    search) pick_search ;;
  esac
}

# Start the web UI when this machine boots? Asked once, the first time the
# web UI is started from an interactive terminal; `selkies-cli boot` changes it.
ask_boot_once() {
  [ -n "$TTY_IN" ] || return 0
  [ "${FORGE_BOOT:-0}" = 1 ] && return 0
  local b; b=$(engine boot status 2>/dev/null)
  printf '%s' "$b" | grep -q '"asked": true' && return 0
  printf '%s' "$b" | grep -q '"enabled": true' && return 0
  printf '\n'
  if confirm "Start the web UI automatically whenever this machine boots?" y; then
    cmd_boot on
  else
    engine boot asked >/dev/null 2>&1
    info "it will not start on boot; turn it on later with: ${B}selkies-cli boot on${NC}"
  fi
}

cmd_boot() {
  local act="${1:-status}"
  case "$act" in
    on|enable)
      [ -n "${UI_PORT:-}" ] || eval "$(status_vars "$(forge_status_json)")"
      local -a a=(boot enable --port "${UI_PORT:-$WEBUI_PORT}" --bind "${UI_BIND:-$WEBUI_BIND}")
      [ "${UI_EXPOSED:-0}" = 1 ] || [ "$WEBUI_EXPOSE" = 1 ] && a+=(--expose)
      local r; r=$(engine "${a[@]}" 2>&1)
      if ! printf '%s' "$r" | grep -q '"ok": true'; then
        bad "could not set that up: $(printf '%s' "$r" | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("error",""))
except Exception: print("")')"
        return 1
      fi
      local method; method=$(printf '%s' "$r" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("method",""))')
      ok "the web UI will start by itself when this machine boots ($method)"
      if printf '%s' "$r" | grep -q '"needs"'; then
        warn "systemd only starts your services at boot once \"linger\" is on for your user"
        if confirm "Turn it on now? (runs: sudo loginctl enable-linger $USER)" y; then
          if run_root loginctl enable-linger "$USER"; then
            ok "linger is on: it now starts at boot, even before anyone logs in"
          else
            warn "that did not work; until it does, it starts when you log in"
          fi
        else
          info "until then it starts when you log in, not at boot"
        fi
      fi
      ;;
    off|disable)
      engine boot disable >/dev/null 2>&1 && ok "the web UI will no longer start on boot"
      ;;
    *)
      local r; r=$(engine boot status 2>/dev/null)
      if printf '%s' "$r" | grep -q '"enabled": true'; then
        ok "starts on boot ($(printf '%s' "$r" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("method"))'))"
      else
        info "does not start on boot · turn it on with: selkies-cli boot on"
      fi
      ;;
  esac
}

# What the forge uses on disk, and tidying it up. Nothing a desktop uses is
# ever removed; images come back by themselves when you forge again.
cmd_clean() {
  title "Disk" "what the forge uses, and what it can give back"
  local r; r=$(engine space 2>/dev/null)
  printf '%s' "$r" | FORGE_COLOR=$COLOR "$PY" -c '
import json, os, sys
d = json.loads(sys.stdin.read() or "{}")
C = os.environ.get("FORGE_COLOR") == "1"
def c(code, s): return "\033[%sm%s\033[0m" % (code, s) if C else str(s)
def mb(x):
    x = float(x or 0)
    return "%.1f GB" % (x / 1024) if x >= 1024 else "%d MB" % x
g = d.get("groups") or {}
for key, label in (("layers", "forge layers"), ("built", "built desktops"),
                   ("pulled", "pulled desktops"), ("bases", "base images")):
    rows = g.get(key) or []
    unused = [r for r in rows if not r.get("in_use")]
    print("  %s %3d  %9s   %s" % (c("2", "%-16s" % label), len(rows),
          mb(sum(r["size_mb"] for r in rows)), c("2", "%s unused" % mb(sum(r["size_mb"] for r in unused)))))
print("  %s      %9s" % (c("2", "%-16s" % "build cache"), mb(d.get("build_cache_mb"))))
print("  %s %3d   %s" % (c("2", "%-16s" % "orphan volumes"), len(d.get("orphan_volumes") or []),
      c("2", "files of removed desktops you chose to keep")))
print()
print("  tidy up frees %s; removing everything unused frees %s" % (
    c("1", mb(d.get("reclaimable_mb"))), c("1", mb(d.get("reclaimable_all_mb")))))
'
  printf '\n'
  local act
  act=$(menu_choose "Clean up?" \
    $'tidy\tTidy up\told forge layers only; nothing to download again' \
    $'all\tRemove everything unused\tunused desktop images and the build cache' \
    $'vols\tAlso delete kept files\torphan volumes of removed desktops (cannot be undone)' \
    $'no\tLeave it\t') || return 0
  local -a a=(space --clean)
  case "$act" in
    tidy) : ;;
    all) a+=(--all) ;;
    vols) confirm "Delete the kept files of removed desktops for good?" n || return 0; a+=(--all --volumes) ;;
    *) return 0 ;;
  esac
  spin_start "cleaning up"
  r=$(engine "${a[@]}" 2>/dev/null)
  spin_stop
  printf '%s' "$r" | "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
print("  \u2714 removed %d images%s" % (len(d.get("removed_images") or []),
      ", %d volumes" % len(d["removed_volumes"]) if d.get("removed_volumes") else ""))
for k, v in (d.get("failed") or {}).items():
    print("  ! kept %s: %s" % (k, v[:80]))
'
}

# A desktop by its short name or its container name (forge-...).
resolve_desktop() {
  local n="$1"
  if docker inspect "$n" >/dev/null 2>&1; then printf '%s' "$n"
  elif docker inspect "forge-$n" >/dev/null 2>&1; then printf 'forge-%s' "$n"
  else printf '%s' "$n"; fi
}

cmd_backup() {
  [ -n "${1:-}" ] || die "usage: selkies-cli backup NAME"
  local n; n=$(resolve_desktop "$1")
  stream_job_view backup "Backing up $n" backup "$n"
}

cmd_backups() {
  title "Backups" "in $FORGE_HOME/backups; restore with: selkies-cli restore-backup NAME FILE"
  local -a a=(backups)
  [ -n "${1:-}" ] && a+=(--name "$(resolve_desktop "$1")")
  engine "${a[@]}" | sed 's/^/  /'
  printf '\n'
}

cmd_restore_backup() {
  [ -n "${2:-}" ] || die "usage: selkies-cli restore-backup NAME FILE"
  local n; n=$(resolve_desktop "$1")
  confirm "Replace $n's files with $2? (a safety backup is taken first)" n || return 0
  stream_job_view restore "Restoring $n" restore-backup "$n" "$2"
}

cmd_clone() {
  [ -n "${1:-}" ] || die "usage: selkies-cli clone NAME [NEW-NAME]"
  local n; n=$(resolve_desktop "$1")
  local -a a=(clone "$n")
  [ -n "${2:-}" ] && a+=(--as "$2")
  stream_job_view clone "Cloning $n" "${a[@]}"
}

# Addons: apps that install beside the forge (docs/addons.md).
cmd_addon() {
  local verb="${1:-list}"; [ $# -gt 0 ] && shift
  case "$verb" in
    install|update|uninstall|action)
      [ -n "${1:-}" ] || die "usage: selkies-cli addon $verb ID"
      stream_job_view addon "Addon: $verb $1" addon "$verb" "$@"
      ;;
    list|ls)
      title "Addons" "add one: selkies-cli addon add https://github.com/OWNER/REPO"
      engine addon list | sed 's/^/  /'
      printf '\n'
      ;;
    add|info|status|remove|sync) engine addon "$verb" "$@" | sed 's/^E /  ✘ /; s/^/  /' ;;
    help|-h|--help)
      printf '  selkies-cli addon list | add LINK | info ID | install ID [--set K=V] | update ID\n'
      printf '                    | uninstall ID [--purge] | remove ID | action ID ACTION | status ID\n' ;;
    *) die "unknown addon command: $verb (try: selkies-cli addon help)" ;;
  esac
}

cmd_jobs() {
  title "Jobs" "launches, backups and clones, from the web UI and the terminal"
  engine jobs | sed 's/^/  /'
  printf '\n'
}

cmd_idle() {
  [ -n "${2:-}" ] || die "usage: selkies-cli idle NAME MINUTES|0|default"
  local n; n=$(resolve_desktop "$1")
  local r; r=$(engine idle "$n" "$2" 2>&1)
  if printf '%s' "$r" | grep -q '"error"'; then bad "$r"
  elif [ "$2" = 0 ]; then ok "$n is never stopped for being idle"
  elif [ "$2" = default ]; then ok "$n follows the forge default (FORGE_IDLE_STOP_MIN)"
  else ok "$n stops after $2 minutes with nobody watching (needs the web UI running)"; fi
}

cmd_events() {
  title "What happened" "launches, crashes, heals and repairs, newest last"
  engine events --limit "${1:-40}" | sed 's/^/  /'
  printf '\n'
}

cmd_restore() {
  spin_start "starting the desktops that were running before"
  local r; r=$(engine restore 2>/dev/null)
  spin_stop
  printf '%s' "$r" | "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
for n in d.get("started") or []:
    print("  ✔ started " + n)
if not d.get("started"):
    print("  ! nothing needed starting")
'
}

main_menu() {
  review_autostart
  while :; do
    local js
    js=$(forge_status_json)
    eval "$(status_vars "$js")"
    render_status "$js"

    # Suggestions first: what you most likely want given what is running.
    # "Browse / forge a new desktop" always sits third, wherever the list starts.
    local -a items=()
    local newitem=$'new\tBrowse & forge a new desktop\tpick from 150+ desktops'
    [ "$TOTAL" -eq 0 ] && newitem=$'new\tBrowse & forge your first desktop\tpick from 150+ desktops'
    if [ "$DOCKER_OK" != 1 ]; then
      items+=($'doctor\tFind out why Docker is not answering\tchecks docker, memory, disk')
    fi
    if [ "$RESTORE_N" -gt 0 ] 2>/dev/null && [ "$LAST_DISMISSED" != 1 ]; then
      local why="they were running before it stopped"
      case "$LAST_REASON" in
        host-reboot) why="they were running before the reboot" ;;
        host-shutdown) why="they were running before the shutdown" ;;
        host-crash) why="they were running before the machine went down" ;;
      esac
      items+=("restore"$'\t'"Start the $RESTORE_N desktop(s) again"$'\t'"$why")
    fi
    case "$UI_STATE" in
      up)
        [ "$UI_RESTART" = 1 ] && items+=($'uirestart\tRestart the web UI\ta new version is installed')
        items+=("open"$'\t'"Open the web UI"$'\t'"running at $UI_URL")
        [ "$TOTAL" -gt 0 ] && items+=("manager"$'\t'"Manage desktops"$'\t'"$RUNNING running, $STOPPED stopped")
        items+=($'uistop\tStop the web UI\tyour desktops keep running')
        [ "$UI_RESTART" = 1 ] || items+=($'uirestart\tRestart the web UI\tafter an update, or if it misbehaves')
        ;;
      stale)
        items+=($'uistart\tStart the web UI again\tit stopped unexpectedly')
        items+=($'uilog\tShow why it stopped\tlast lines of its log')
        [ "$TOTAL" -gt 0 ] && items+=("manager"$'\t'"Manage desktops here"$'\t'"$RUNNING running, $STOPPED stopped")
        ;;
      *)
        local hint="browse everything with screenshots"
        [ "$TOTAL" -gt 0 ] && hint="manage your $TOTAL desktop(s) in the browser"
        case "$LAST_REASON" in
          crash|oom|error|host-crash) hint="it stopped unexpectedly last time" ;;
        esac
        items+=("uistart"$'\t'"Start the web UI"$'\t'"$hint")
        [ "$TOTAL" -gt 0 ] && items+=("manager"$'\t'"Manage desktops here"$'\t'"$RUNNING running, $STOPPED stopped")
        case "$LAST_REASON" in
          crash|oom|error) items+=($'uilog\tShow why it stopped\tlast lines of its log') ;;
        esac
        ;;
    esac
    # Slot the browse entry in as the third choice (or last, if the list is shorter).
    if [ "${#items[@]}" -ge 2 ]; then
      items=("${items[@]:0:2}" "$newitem" "${items[@]:2}")
    else
      items+=("$newitem")
    fi
    if [ "$BOOT_ON" = 1 ]; then
      items+=($'bootoff\tStop starting the web UI on boot\tit currently starts by itself')
    else
      items+=($'booton\tStart the web UI on boot\tcomes back by itself after a reboot')
    fi
    [ "$DOCKER_OK" = 1 ] && items+=($'doctor\tCheck this machine\tdocker, memory, disk, tunnels')
    [ "$DOCKER_OK" = 1 ] && items+=($'clean\tFree up disk space\tunused images, old layers, build cache')
    items+=($'update\tUpdate Selkies Forge\tget the latest version from GitHub')
    [ "$RESTORE_N" -gt 0 ] 2>/dev/null && [ "$LAST_DISMISSED" != 1 ] && \
      items+=($'dismiss\tForget about the last stop\tstop suggesting the restart')
    items+=($'quit\tQuit\t')

    local choice
    choice=$(menu_choose "What would you like to do?" "${items[@]}") || { printf '\n'; return 0; }
    case "$choice" in
      open) cmd_open; return 0 ;;
      uistart) FORGE_FROM_MENU=1 cmd_webui ;;
      uistop) cmd_stop ;;
      uirestart) cmd_restart ;;
      uilog) cmd_ui_log ;;
      manager) cmd_manager ;;
      new) pick_new ;;
      restore) cmd_restore ;;
      dismiss) engine dismiss-last-stop >/dev/null 2>&1; ok "ok, it will not ask again" ;;
      booton) cmd_boot on ;;
      bootoff) cmd_boot off ;;
      doctor) cmd_doctor ;;
      clean) cmd_clean ;;
      update) cmd_update ;;
      quit|"") printf '\n  %sbye%s\n\n' "$DIM" "$NC"; return 0 ;;
    esac
  done
}

usage() {
  banner
  cat <<USAGE
Usage:
   $FORGE_RUN              interactive menu
   $FORGE_RUN --webui      straight to the web UI
   $FORGE_RUN --bg         web UI in the background, shell back
   $FORGE_RUN --fg         web UI in the foreground until ctrl-c
   $FORGE_RUN --stop       stop a backgrounded web UI
   $FORGE_RUN --cli        straight to the terminal picker
   $FORGE_RUN --smart      let it choose for this machine
   $FORGE_RUN --launch ID  forge one entry and exit
   $FORGE_RUN --list       print the catalog
   $FORGE_RUN --manager    manage running desktops
   $FORGE_RUN --doctor     check this machine
   $FORGE_RUN --uninstall  remove everything it created

After the first run:
   selkies-cli                     home screen: what is running, what to do next
   selkies-cli status              one-shot status of the web UI and desktops
   selkies-cli start | stop        web UI in the background, or stop it
   selkies-cli restart | open      restart it, or print/open its link
   selkies-cli manager | new       manage desktops, or forge a new one
   selkies-cli update              install the latest version from GitHub
   selkies-cli boot on | off       start the web UI by itself when the machine boots
   selkies-cli restore             start the desktops that were running before a reboot
   selkies-cli events              what happened: launches, crashes, heals, repairs
   selkies-cli clean               see and free the disk the forge uses
   selkies-cli jobs                launches, backups and clones in progress or recent
   selkies-cli backup NAME         back up a desktop's files (its home folder)
   selkies-cli backups [NAME]      list backups
   selkies-cli restore-backup NAME FILE   put a backup's files back (safety copy first)
   selkies-cli clone NAME [NEW]    a second desktop with a copy of its files
   selkies-cli idle NAME MIN       stop it after MIN minutes unwatched (0 = never)

Options:
   --port N       web UI port (default 8787, the next free one if taken)
   --expose       serve the web UI beyond localhost (no access control)
   --no-tunnel    skip the public serveo link
   --yes, -y      accept the install prompts (Python, Docker)

USAGE
}

# =========================================================================
#  entry point
# =========================================================================

main() {
  local MODE="menu" LAUNCH_ID="" BOOT_ACT="" EXTRACT_TO=""
  local -a ORIG_ARGS=("$@")
  # Verbs that take desktop names: run them straight after the usual setup.
  case "${1:-}" in
    backup|backups|restore-backup|clone|jobs|idle|addon|addons)
      local verb="$1"; shift
      ensure_dirs; preflight; extract_payload
      case "$verb" in
        addon|addons) cmd_addon "$@" ;;
        backup) cmd_backup "$@" ;;
        backups) cmd_backups "$@" ;;
        restore-backup) cmd_restore_backup "$@" ;;
        clone) cmd_clone "$@" ;;
        jobs) cmd_jobs ;;
        idle) cmd_idle "$@" ;;
      esac
      exit $?
      ;;
  esac
  # Plain words for the common things: selkies-cli status, selkies-cli stop...
  case "${1:-}" in
    status|start|stop|restart|open|update|setup|manager|doctor|list|new|uninstall|help|boot|restore|clean|events)
      local verb="$1"; shift
      case "$verb" in
        start) set -- --bg "$@" ;;
        new) set -- --cli "$@" ;;
        help) set -- --help "$@" ;;
        boot) BOOT_ACT="${1:-status}"; [ $# -gt 0 ] && shift; set -- --boot "$@" ;;
        restore) set -- --restore "$@" ;;
        clean) set -- --clean "$@" ;;
        events) set -- --events "$@" ;;
        *) set -- "--$verb" "$@" ;;
      esac
      ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) MODE="status" ;;
      --boot) MODE="boot" ;;
      --restore) MODE="restore" ;;
      --clean) MODE="clean" ;;
      --events) MODE="events" ;;
      --restart) MODE="restart" ;;
      --open) MODE="open" ;;
      --update) MODE="update" ;;
      --setup) MODE="setup" ;;
      --webui|-w) MODE="webui" ;;
      --cli|-c) MODE="cli" ;;
      --smart|-s) MODE="smart" ;;
      --manager|-m) MODE="manager" ;;
      --doctor) MODE="doctor" ;;
      --list|-l) MODE="list" ;;
      --launch) MODE="launch"; LAUNCH_ID="${2:-}"; shift ;;
      --uninstall) MODE="uninstall" ;;
      --port) WEBUI_PORT="${2:-8787}"; WEBUI_PORT_SET=1; shift ;;
      --bind) WEBUI_BIND="${2:-127.0.0.1}"; shift ;;
      --expose) WEBUI_EXPOSE=1; WEBUI_BIND="0.0.0.0" ;;
      --bg) MODE="webui"; WEBUI_MODE="bg" ;;
      --fg) MODE="webui"; WEBUI_MODE="fg" ;;
      --stop) MODE="stop" ;;
      --no-tunnel) NO_TUNNEL=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --force-extract) FORCE_EXTRACT=1 ;;
      --version|-V) printf 'selkies-forge %s\n' "$FORGE_VERSION"; exit 0 ;;
      --extract-only) MODE="extract"; EXTRACT_TO="${2:-}"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
  done

  # Unpack the engine and web UI somewhere and stop: no installs, no checks.
  # build.py uses this for its self-test; packagers can use it too.
  if [ "$MODE" = extract ]; then
    [ -n "$EXTRACT_TO" ] || die "--extract-only needs a directory"
    mkdir -p "$EXTRACT_TO" || die "cannot create $EXTRACT_TO"
    FORGE_APP="$(cd "$EXTRACT_TO" && pwd)"
    FORCE_EXTRACT=1 extract_payload
    printf '%s\n' "$FORGE_APP"
    exit 0
  fi

  ensure_dirs
  case "$MODE" in
    uninstall|status|boot|events) : ;;
    *) banner ;;
  esac

  preflight
  extract_payload
  install_cli || true
  if [ "$FORGE_AS_CLI" = 1 ] && [ "${FORGE_JUST_UPDATED:-0}" != 1 ]; then
    case "$MODE" in
      update|uninstall|setup) : ;;
      *) auto_update_cli ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} ;;
    esac
  fi

  case "$MODE" in
    setup)
      announce_cli
      printf '\n'
      ok "Selkies Forge $FORGE_VERSION is ready"
      info "run ${B}${FORGE_RUN}${NC} any time to see what is running and pick what to do"
      printf '\n'
      exit 0
      ;;
    status) cmd_status; exit 0 ;;
    boot) cmd_boot "${BOOT_ACT:-status}"; exit $? ;;
    restore) cmd_restore; exit 0 ;;
    clean) cmd_clean; exit 0 ;;
    events) cmd_events; exit 0 ;;
    open) cmd_open; exit 0 ;;
    restart) cmd_restart; exit $? ;;
    update) cmd_update; exit 0 ;;
    stop) cmd_stop; exit $? ;;
    uninstall) cmd_uninstall; exit 0 ;;
    doctor) cmd_doctor; exit 0 ;;
    list) engine list --runnable --format tsv | column -t -s $'\t' 2>/dev/null || engine list --runnable --format tsv; exit 0 ;;
    launch)
      [ -n "$LAUNCH_ID" ] || die "--launch needs a catalog id (see --list)"
      local -a a=()
      [ "$NO_TUNNEL" = 1 ] && a+=(--no-tunnel)
      stream_launch "$LAUNCH_ID" "${a[@]}"
      exit $?
      ;;
  esac

  announce_cli
  case "$MODE" in
    webui) singleton_check ;;
  esac

  case "$MODE" in
    webui) cmd_webui ;;
    cli) pick_quick ;;
    smart) cmd_smart ;;
    manager) cmd_manager ;;
    *) main_menu ;;
  esac
}

main "$@"
