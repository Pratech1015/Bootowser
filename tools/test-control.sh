#!/usr/bin/env bash
#
# test-control.sh - exercise the bootowser-control sidecar end to end.
#
# Runs the built binary against a throwaway config and walks the whole API
# matrix: origin gate, token gate, exec semantics, limits, admin console,
# bind-address refusal. Needs no root; the one root-dependent path (sudo
# hooks) is probed and skipped with a note when sudo cannot run passwordless.
#
# Usage:
#   tools/test-control.sh [path/to/bootowser-control]
#   BOOTOWSER_CONTROL_BIN=/path/to/bin tools/test-control.sh
#
set -euo pipefail

BIN="${1:-${BOOTOWSER_CONTROL_BIN:-}}"
if [ -z "$BIN" ]; then
  for c in /usr/lib/bootowser/bootowser-control \
           "$(dirname -- "$0")/../obj-bootowser/dist/bin/bootowser-control"; do
    [ -x "$c" ] && BIN="$c" && break
  done
fi
[ -x "${BIN:-}" ] || {
  echo "error: bootowser-control not found; pass its path as the first argument" >&2
  exit 1
}

PORT=$(( 29600 + RANDOM % 400 ))
ORIGIN="https://start.example.com"
BASE="http://127.0.0.1:${PORT}"

WORK="$(mktemp -d /tmp/bowtest-XXXXXX)"
DAEMON_PID=""
PASS=0
FAIL=0
SKIP=0

cleanup() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }

# assert <name> <expected-status> <curl args...>
assert() {
  local name="$1" want="$2"; shift 2
  local got
  got=$(curl -sS -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || echo 000)
  if [ "$got" = "$want" ]; then ok "$name"; else
    bad "$name (want HTTP $want, got $got)"
  fi
}

mkdir -p "$WORK/commands"
cat > "$WORK/commands/echo.sh" <<'EOF'
#!/bin/sh
echo "stdout:$*"
echo "stderr-side" >&2
EOF
chmod 0755 "$WORK/commands/echo.sh"
cat > "$WORK/commands/exit42.sh" <<'EOF'
#!/bin/sh
exit 42
EOF
chmod 0755 "$WORK/commands/exit42.sh"
cat > "$WORK/commands/long.sh" <<'EOF'
#!/bin/sh
head -c 2000 /dev/zero | tr '\000' x
EOF
chmod 0755 "$WORK/commands/long.sh"

cat > "$WORK/control.conf" <<EOF
PORT=${PORT}
BIND=127.0.0.1
ALLOWED_ORIGINS=${ORIGIN}
TOKEN=
COMMANDS_DIR=${WORK}/commands
DEFAULT_TIMEOUT_MS=30000
MAX_TIMEOUT_MS=60000
MAX_OUTPUT_BYTES=1024
MAX_BODY_BYTES=1048576
MAX_CONCURRENT=4
ALLOW_NO_ORIGIN=0
ALLOW_NONLOOPBACK=0
EOF

set -a
# shellcheck disable=SC1090
. "$WORK/control.conf"
set +a

"$BIN" &
DAEMON_PID=$!

# --- boot -----------------------------------------------------------------
ready=0
for _ in {1..50}; do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.1
done
if [ "$ready" -ne 1 ]; then
  echo "error: daemon did not become ready on $BASE" >&2
  exit 1
fi
ok "healthz comes up on $BASE"

# --- origin and token gates ------------------------------------------------
assert "allowed origin passes /v1"        200 -H "Origin: $ORIGIN" -X POST "$BASE/v1/exec" -d 'cmd=exit 0'
assert "missing origin is refused"        403 -X POST "$BASE/v1/exec" -d 'cmd=exit 0'
assert "foreign origin is refused"        403 -H 'Origin: https://evil.example' -X POST "$BASE/v1/exec" -d 'cmd=exit 0'
assert "own origin (admin console) works" 200 -H "Origin: $BASE" "$BASE/"
assert "unknown path is 404"              404 "$BASE/nope"
assert "preflight is answered"            204 -X OPTIONS -H "Origin: $ORIGIN" \
       -H 'Access-Control-Request-Method: POST' "$BASE/v1/exec"
acao=$(curl -sS -D - -o /dev/null -H "Origin: $ORIGIN" -X POST "$BASE/v1/exec" -d 'cmd=exit 0' \
       | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2}')
[ "$acao" = "$ORIGIN" ] && ok "preflight CORS echoes origin" || bad "preflight CORS header missing (got '$acao')"

# --- exec semantics --------------------------------------------------------
body=$(curl -sS -H "Origin: $ORIGIN" -X POST "$BASE/v1/exec" -d "cmd=printf 'out123'")
case "$body" in *'"stdout":"out123"'*) ok "stdout is captured" ;; *) bad "stdout capture: $body" ;; esac

body=$(curl -sS -H "Origin: $ORIGIN" -X POST "$BASE/v1/exec" --data-urlencode "cmd=$WORK/commands/long.sh")
case "$body" in
  *'"truncated":true'*) ok "output is truncated at MAX_OUTPUT_BYTES" ;;
  *) bad "truncation flag missing: $body" ;;
esac

body=$(curl -sS -H "Origin: $ORIGIN" -X POST "$BASE/v1/exec" -d 'cmd=exit 42')
case "$body" in *'"exit":42'*) ok "exit status propagates" ;; *) bad "exit status: $body" ;; esac

body=$(curl -sS -H "Origin: $ORIGIN" -X POST "$BASE/v1/exec" -d 'cmd=sleep 5' -d 'timeout_ms=700')
case "$body" in
  *'"exit":143,"timed_out":true'*) ok "timeout kills the process group (143)" ;;
  *) bad "timeout behaviour: $body" ;;
esac

assert "empty cmd is a 400" 400 -H "Origin: $ORIGIN" -X POST "$BASE/v1/exec"
assert "non-integer timeout_ms is a 400" 400 -H "Origin: $ORIGIN" \
       -X POST "$BASE/v1/exec" -d 'cmd=true' -d 'timeout_ms=abc'
# A too-large timeout_ms is clamped to MAX_TIMEOUT_MS, not rejected: prove
# the requested value is honoured by killing a 1s sleep with a 1ms budget.
body=$(curl -sS -H "Origin: $ORIGIN" -X POST "$BASE/v1/exec" -d 'cmd=sleep 1' -d 'timeout_ms=1')
case "$body" in
  *'"timed_out":true'*) ok "timeout_ms is honoured (1ms budget kills sleep 1)" ;;
  *) bad "timeout_ms=1 did not fire: $body" ;;
esac

# --- command registry ------------------------------------------------------
# The list only ever shows root-owned hooks; a user-owned script showing up
# would advertise something /v1/root refuses to run anyway.
assert "commands list answers" 200 -H "Origin: $ORIGIN" "$BASE/v1/commands"
body=$(curl -sS -H "Origin: $ORIGIN" "$BASE/v1/commands")
case "$body" in
  *'echo.sh'*|*'exit42.sh'*|*'long.sh'*)
    bad "commands list advertises a user-owned script: $body" ;;
  *) ok "commands list excludes user-owned scripts" ;;
esac

# --- root hook validation --------------------------------------------------
# Every refusal below is a 400 with a distinct message; escalation only ever
# happens after these checks, so each one is a hole if it stops being enforced.
body=$(curl -sS -H "Origin: $ORIGIN" -X POST "$BASE/v1/root" -d 'name=echo.sh' -d 'arg=hi')
case "$body" in
  *'"command must be owned by root"'*) ok "root hook refuses a user-owned script" ;;
  *) bad "user-owned script refusal: $body" ;;
esac
body=$(curl -sS -H "Origin: $ORIGIN" -X POST "$BASE/v1/root" -d 'name=../etc/passwd')
case "$body" in
  *'"invalid command name"'*) ok "root hook refuses a traversal name" ;;
  *) bad "traversal refusal: $body" ;;
esac
body=$(curl -sS -H "Origin: $ORIGIN" -X POST "$BASE/v1/root" -d 'name=does-not-exist.sh')
case "$body" in
  *'"no such command"'*) ok "root hook refuses an unknown script" ;;
  *) bad "unknown script refusal: $body" ;;
esac
# The mode check runs after the uid check, so it needs a root-owned fixture;
# only reachable when this harness itself is root (device-side runs).
if [ "$(id -u)" -eq 0 ]; then
  cp "$WORK/commands/echo.sh" "$WORK/commands/rw.sh"
  chown root:root "$WORK/commands/rw.sh"
  chmod 0666 "$WORK/commands/rw.sh"
  body=$(curl -sS -H "Origin: $ORIGIN" -X POST "$BASE/v1/root" -d 'name=rw.sh')
  case "$body" in
    *'"must not be group or world writable"'*) ok "root hook refuses a world-writable script" ;;
    *) bad "world-writable refusal: $body" ;;
  esac
  rm -f "$WORK/commands/rw.sh"
else
  skip "world-writable refusal needs a root-owned fixture (run as root)"
fi

# --- sudo path (optional) --------------------------------------------------
hook=/usr/lib/bootowser/commands/whoami-root.sh
if ! sudo -n true 2>/dev/null; then
  skip "passwordless sudo unavailable; root-hook escalation not tested"
elif [ ! -f "$hook" ]; then
  skip "no hook installed at $hook"
elif [ "$(stat -c %u "$hook")" != 0 ]; then
  skip "$hook is not root-owned"
else
  body=$(curl -sS -H "Origin: $ORIGIN" -X POST "$BASE/v1/root" -d 'name=whoami-root.sh')
  case "$body" in
    *'"exit":0'*) ok "root hook escalates via sudo" ;;
    *) bad "root hook escalation: $body" ;;
  esac
fi

# --- bind guard ------------------------------------------------------------
# The refusal is synchronous (exit 2 before binding), so no daemon is needed.
set +e
BIND=0.0.0.0 PORT=$((PORT + 1)) ALLOW_NONLOOPBACK=0 "$BIN" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  ok "daemon refuses a non-loopback BIND"
else
  bad "non-loopback BIND guard (want exit 2, got $rc)"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
