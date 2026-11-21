#!/usr/bin/env bash
# Wilds — Minecraft 26.3 (Paper + EduGeyser: Java, Bedrock, Education) on a bare
# machine. One file, no Docker, no build step on the host.
#
#   sudo bash install.sh wilds-mc-26.3.zip   install everything and start
#   sudo bash install.sh restart             save the world, then restart
#   sudo bash install.sh stop                stop the control plane and Paper
#   sudo bash install.sh status              pid, health, tail of the log
#
# What it installs, once, into /opt/wilds and /data:
#   Java 25 (Temurin, in /opt/jdk-25 — the machine's Java 21 is untouched)
#   a private Python venv, the playit agent, .env, and an InstaBox boot hook.
# Then it runs the server under a supervisor that restarts it if it dies.
# Re-running is safe: .env is never overwritten.
set -euo pipefail

ROOT="${WILDS_ROOT:-/opt/wilds}"
DATA="${WILDS_DATA:-/data}"
JDK="${WILDS_JDK:-/opt/jdk-25}"
VENV="$ROOT/.venv"
ENV_FILE="$ROOT/.env"
PID_FILE="$ROOT/run/supervisor.pid"
LOG="${WILDS_LOG:-$DATA/logs/wilds.log}"
PORT="${CONTROL_PORT:-7860}"
HOOK="/usr/local/lib/instabox/data-init.d/50-wilds.sh"
JDK_URL="https://api.adoptium.net/v3/binary/latest/25/ga/linux/x64/jdk/hotspot/normal/eclipse"
PLAYIT_URL="https://github.com/playit-cloud/playit-agent/releases/download/v2.0.2/playit-cli-linux-amd64"

say() { printf '[wilds] %s\n' "$*"; }
die() { printf '[wilds] %s\n' "$*" >&2; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 || "${WILDS_SKIP_ROOT:-0}" == "1" ]] \
    || die "run as root: sudo bash install.sh <bundle.zip>   (or set WILDS_SKIP_ROOT=1)"
}

# ------------------------------------------------------------------ services

do_start() {
  mkdir -p "$ROOT/run" "$DATA/logs"
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    say "already running (pid $(cat "$PID_FILE"))"
    return 0
  fi
  [[ -x "$JDK/bin/java" ]] || die "Java 25 missing at $JDK — run the installer first"
  [[ -x "$VENV/bin/python" ]] || die "venv missing at $VENV — run the installer first"
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE — run the installer first"

  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  PORT="${CONTROL_PORT:-7860}"

  export PATH="$JDK/bin:$VENV/bin:$PATH"
  export APP_DIR="$ROOT" PYTHON="$VENV/bin/python" WILDS_ROOT="$ROOT"

  # Own process group (setsid) so stop can signal wake proxy + uvicorn + playit
  # in one go; the loop restarts the control plane if uvicorn ever exits.
  setsid bash -c '
    trap "exit 0" INT TERM
    while :; do
      bash "$APP_DIR/scripts/entrypoint.sh" || true
      sleep 5
    done
  ' >>"$LOG" 2>&1 &
  echo $! >"$PID_FILE"
  sleep 2

  if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    rm -f "$PID_FILE"
    tail -n 25 "$LOG" >&2 2>/dev/null || true
    die "control plane exited immediately (log above)"
  fi
  say "started, pid $(cat "$PID_FILE"), log $LOG"
}

do_stop() {
  if [[ ! -f "$PID_FILE" ]]; then
    say "not running"
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    say "not running (stale pid $pid)"
    return 0
  fi
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 45); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE"
      say "stopped"
      return 0
    fi
    sleep 1
  done
  kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  rm -f "$PID_FILE"
  say "killed after 45s"
}

do_restart() {
  local token
  token="$(cat "$DATA/admin.token" 2>/dev/null || true)"
  if [[ -n "$token" ]] && curl -fsS -m 25 -X POST "http://127.0.0.1:$PORT/api/sleep" \
      -H "x-admin-token: $token" >/dev/null 2>&1; then
    say "world saved and Paper stopped"
  fi
  do_stop
  do_start
}

do_status() {
  local pid="none"
  if [[ -f "$PID_FILE" ]]; then pid="$(cat "$PID_FILE")"; fi
  say "pid $pid, root $ROOT, data $DATA"
  if curl -fsS -m 5 "http://127.0.0.1:$PORT/health" 2>/dev/null; then
    echo
  else
    say "health: no answer on :$PORT"
  fi
  if [[ -f "$LOG" ]]; then tail -n 8 "$LOG" || true; fi
  return 0
}

# ------------------------------------------------------------------ install

java_major() { "$1" -version 2>&1 | awk -F'"' '/version/ {print $2}' | cut -d. -f1; }

install_java() {
  if [[ -x "$JDK/bin/java" ]] && [[ "$(java_major "$JDK/bin/java")" == "25" ]]; then
    say "Java 25 already at $JDK"
    return 0
  fi
  say "downloading Temurin 25 (the system Java 21 is left alone)"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$JDK_URL" -o "$tmp/jdk25.tar.gz" || die "could not download JDK 25"
  mkdir -p "$JDK"
  tar -xzf "$tmp/jdk25.tar.gz" -C "$JDK" --strip-components=1
  rm -rf "$tmp"
  [[ "$(java_major "$JDK/bin/java")" == "25" ]] || die "JDK 25 did not unpack correctly"
  say "java: $("$JDK/bin/java" -version 2>&1 | head -n 1)"
}

install_python() {
  local py="${PYTHON_BIN:-python3}"
  command -v "$py" >/dev/null 2>&1 || die "python3 is missing from this machine"
  say "python: $("$py" -c 'import sys; print(sys.version.split()[0])')"
  if [[ ! -x "$VENV/bin/python" ]]; then
    if ! "$py" -m venv "$VENV" >/dev/null 2>&1; then
      say "python3-venv missing, installing it"
      apt-get install -y -qq --no-install-recommends python3-venv >/dev/null 2>&1 || true
      "$py" -m venv "$VENV" >/dev/null 2>&1 || die "could not create a venv (install python3-venv)"
    fi
  fi
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet fastapi uvicorn httpx PyYAML
  say "dependencies installed in $VENV"
}

install_playit() {
  if command -v playit >/dev/null 2>&1; then
    say "playit already installed"
  elif curl -fsSL "$PLAYIT_URL" -o /usr/local/bin/playit; then
    chmod +x /usr/local/bin/playit
    say "playit agent installed"
  else
    say "WARNING playit download failed; set PLAYIT_SECRET after installing it, or Java/Bedrock stay unreachable"
  fi
}

write_env() {
  mkdir -p "$DATA"
  if [[ -f "$ENV_FILE" ]]; then
    say "keeping existing $ENV_FILE"
    return 0
  fi
  cat >"$ENV_FILE" <<'ENVEOF'
# Server settings. Edit, then: sudo bash /opt/wilds/install.sh restart
DATA_DIR=/data
CONTROL_PORT=7860

# Player-facing name: the server-list MOTD, the /start page and the dashboard.
SERVER_NAME=Trust Republic SMP

# 8 GiB machine: leaves ~2 GiB for Python, playit and the page cache.
MC_MEMORY=5G
MC_MIN_MEMORY=2G
MAX_PLAYERS=20

# Players start the world: the wake proxy answers on 25565 and boots Paper on the
# first join attempt (~40s). The run cap closes the world before InstaBox pauses
# the VM. Set AUTO_SLEEP=false to keep Paper up for the whole window instead.
AUTO_SLEEP=true
IDLE_SLEEP_MINUTES=10
WAKE_ON_BOOT=true
RUN_CAP_MINUTES=470
RUN_CAP_MARGIN_MINUTES=8

# Java players: fill the recipe book (recipes are server-owned since 1.21.2).
UNLOCK_ALL_RECIPES=true
EXTRA_PLUGINS=

# edu = EduGeyser + EduFloodgate: Java + Bedrock + Minecraft Education.
CROSSPLAY=edu
MC_VERSION=26.3
MC_PROTOCOL=777

# Public connectivity: playit dials out, so no inbound port is needed.
# Java: "Minecraft Java" tunnel -> 127.0.0.1:25565.
# Bedrock/Education: "Minecraft Bedrock (NetherNet)" tunnel; paste its Geyser
# settings into plugins/Geyser-Spigot/config.yml. There is no UDP port to open.
PLAYIT_SECRET=
MC_PUBLIC_ADDRESS=
BEDROCK_PUBLIC_ADDRESS=

TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
TELEGRAM_BACKUP_HOURS=12
SPACE_PUBLIC_URL=
ENVEOF
  say "wrote $ENV_FILE"
}

install_hook() {
  mkdir -p "$(dirname "$HOOK")" 2>/dev/null || true
  if cat >"$HOOK" 2>/dev/null <<HOOKEOF
#!/usr/bin/env bash
# InstaBox runs this on every machine start/resume.
exec bash "$ROOT/install.sh" start
HOOKEOF
  then
    chmod +x "$HOOK" 2>/dev/null || true
    say "boot hook: $HOOK"
  else
    say "WARNING could not install the boot hook; start the server manually with: sudo bash $ROOT/install.sh start"
  fi
}

unpack() {
  local src="$1"
  if [[ -d "$src" ]]; then
    say "copying $src -> $ROOT"
    mkdir -p "$ROOT"
    tar -C "$src" -cf - --exclude=.git --exclude=.venv --exclude=venv --exclude=data \
      --exclude=__pycache__ --exclude='*.pyc' --exclude=dist . | tar -C "$ROOT" -xf -
  elif [[ -f "$src" ]]; then
    [[ "$src" == /* ]] || src="$PWD/$src"
    say "unpacking $src -> $ROOT"
    mkdir -p "$ROOT"
    python3 - "$src" "$ROOT" <<'PY'
import sys
import zipfile

archive, target = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as zf:
    unsafe = [n for n in zf.namelist() if n.startswith("/") or ".." in n.split("/")]
    if unsafe:
        raise SystemExit("refusing to extract suspicious paths: %s" % unsafe[:3])
    zf.extractall(target)
PY
  else
    die "not found: $src (pass the bundle zip, or run this from the unpacked folder)"
  fi
  [[ -f "$ROOT/app/main.py" ]] || die "bundle is incomplete: no app/main.py in $ROOT"
  [[ -f "$ROOT/scripts/entrypoint.sh" ]] || die "bundle is incomplete: no scripts/entrypoint.sh"
}

do_install() {
  local src="${1:-}"
  need_root
  say "installing to $ROOT, data in $DATA"
  local mem
  mem="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "${mem:-0}" -ge 3800 ]]; then
    say "machine: ${mem} MiB RAM, $(nproc) vCPU, $(df -Pm "$DATA" 2>/dev/null | awk 'NR==2 {print $4}') MiB free"
  else
    say "WARNING ${mem} MiB RAM detected; 26.3 with MC_MEMORY=5G wants 4 GiB or more"
  fi

  if [[ -n "$src" ]]; then
    unpack "$src"
  else
    [[ -f "$ROOT/app/main.py" ]] || die "usage: sudo bash install.sh <bundle.zip>"
    say "using the existing copy in $ROOT"
  fi
  chmod +x "$ROOT/install.sh" 2>/dev/null || true

  install_java
  install_python
  install_playit
  write_env
  install_hook
  do_start

  cat <<DONE

[wilds] ready.
  edit settings .... sudo nano $ENV_FILE      (PLAYIT_SECRET, addresses, tokens)
  restart ......... sudo bash $ROOT/install.sh restart
  log ............. tail -f $LOG
  dashboard ....... instabox port publish <machine> 7860
  ports ........... sudo bash $ROOT/install.sh ports   (what to publish where)
DONE
}

do_ports() {
  local machine="${INSTABOX_MACHINE:-<machine>}"
  cat <<PORTS
What has to be reachable, and how:

  25565/tcp  Java (wake proxy)
      playit tunnel type "Minecraft Java", local 127.0.0.1:25565 — free tier.
      It proxies TCP, so it reaches the wake proxy and Paper can sleep behind it.

  Bedrock + Education — no inbound port at all
      playit tunnel type "Minecraft Bedrock (NetherNet)" — free, experimental.
      This is NOT a UDP forward: open the tunnel, Configuration help -> Geyser
      tab -> Copy, then paste those keys into
        $DATA/server/plugins/Geyser-Spigot/config.yml
      under bedrock:, keeping port 19132 and address 0.0.0.0. Geyser dials out
      itself; the console then prints
        Registered with the external signaling service
      NetherNet joins in two stages: TCP 19132 for signaling, then UDP 19132 for
      the WebRTC media. A UDP-only forward (the plain "Minecraft Bedrock"
      preset) therefore cannot carry it, even though the port number matches.
      The NetherNet tunnel type proxies both stages.
      Managed keys (port, clone-remote-port, motd1, server-name, remote.*) are
      rewritten on boot; the pasted playit keys are left alone.

  7860/tcp   /start page and the API
      instabox port publish $machine 7860      (free; HTTP only)

Why the game ports are not published on the host: InstaBox published ports
serve HTTP(S). Raw TCP (--tcp) is paid and TLS-wrapped, which a Minecraft client
cannot speak, and UDP is not offered.
PORTS
}

# ------------------------------------------------------------------ entry
case "${1:-}" in
  "") die "usage: sudo bash install.sh <bundle.zip> | restart | stop | status | ports" ;;
  start) need_root; do_start ;;
  stop) need_root; do_stop ;;
  restart) need_root; do_restart ;;
  status) do_status ;;
  ports) do_ports ;;
  install) do_install "${2:-}" ;;
  *) do_install "$1" ;;
esac
