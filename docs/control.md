# The control sidecar

Bootowser can run shell commands on behalf of the kiosk page: a button on
your page can restart the kiosk, clear the profile or run a root-owned
script you shipped. This document is how that works, what stops it from
being a hole, and how to test it. To skip straight to building the page
and adding commands, start with [page-guide.md](page-guide.md).

## Why a sidecar

The obvious place to put a command API would be in the browser itself, and
it is not possible there:

- `bootowser.service` runs Firefox with `NoNewPrivileges=true` and
  `ProtectSystem=strict`. Nothing in that process can ever `exec` a setuid
  binary, so `sudo` from inside Firefox cannot work — the kernel drops the
  privilege bit before exec. No amount of patching changes that; it is the
  unit's sandbox, deliberately.
- An `xpcshell` helper would have to be launched *by* the browser, inheriting
  that same sandbox, and could not escape it either.

So the API is a separate process — `bootowser-control` — in its own systemd
unit, built from the Firefox tree (the same way `pingsender` is: a
`GeckoProgram` in `toolkit/`, landing in `dist/bin/`), and installed at the
stable path `/usr/lib/bootowser/bootowser-control`.

The browser patch series does not carry the API itself. The *page* only
needs `fetch()`, which every Firefox has. What the patched browser plus
managed policy contribute is making those fetches actually work (see
[Local Network Access](#local-network-access) below).

## Architecture

```
kiosk page ──fetch()──► 127.0.0.1:29500 ──► bootowser-control (User=bootowser)
                                              │  /v1/exec  → sh -c (kiosk user)
                                              │  /v1/root  → sudo -n → commands/*
curl / admin console ──►                     └─  /v1/commands, /healthz, /
```

- **`bootowser-control.service`** — `User=bootowser`, reads
  `/etc/bootowser/control.conf` via `EnvironmentFile=`, binds loopback only.
- **`bootowser.service`** pulls it in with `Wants=`/`After=`, so the API is
  listening before the page loads. The sidecar carries
  `ConditionPathExists=/usr/lib/bootowser/bootowser-control`: an install
  without a patched tree (system-browser fallback) simply runs without the
  feature instead of failing.
- One process, one thread per connection, process-group kill on timeout.
  Every request is audited to the journal:
  `bootowser-control: exec origin=… exit=… ms=… cmd=…`.

## API

All responses are JSON. `/v1/*` requires an allowed `Origin` header or the
configured token.

| method | path | body | does |
| --- | --- | --- | --- |
| `GET` | `/healthz` | | `{"ok":true,"api":1}` |
| `GET` | `/v1/commands` | | the root hooks in `COMMANDS_DIR` (root-owned only) |
| `POST` | `/v1/exec` | `cmd=…&timeout_ms=…` | runs `sh -c cmd` **as the kiosk user** |
| `POST` | `/v1/root` | `name=…&arg=…&arg=…` | runs `sudo -n /usr/lib/bootowser/commands/<name> args…` **as root** |
| `GET` | `/` | | a small same-origin admin console for manual testing |
| `OPTIONS` | any | | CORS preflight |

Status codes:

| code | when |
| --- | --- |
| `200` | executed (check `exit` in the body) |
| `204` | preflight answered |
| `400` | missing/invalid `cmd`, `name` or `timeout_ms`; every `/v1/root` refusal |
| `403` | origin not allowed, or token wrong/missing |
| `404` | unknown path |
| `405` | wrong method for a known path |
| `413` | body larger than `MAX_BODY_BYTES` |
| `500` | the command could not be started at all |
| `503` | too many concurrent requests, or `sudo` not installed (for `/v1/root`) |

A failed command is still `200` with `"ok":true` and a non-zero `"exit"` —
HTTP describes the request, `exit` describes the command.

Example:

```sh
curl -sS -H 'Origin: https://start.example.com' \
     -d 'cmd=systemctl is-active bootowser' \
     http://127.0.0.1:29500/v1/exec
# {"ok":true,"exit":0,"timed_out":false,...,"stdout":"active\n",...}
```

## Configuration — `/etc/bootowser/control.conf`

| key | default | meaning |
| --- | --- | --- |
| `PORT` | `29500` | loopback port |
| `BIND` | `127.0.0.1` | bind address; anything non-loopback needs `ALLOW_NONLOOPBACK=1` and is refused otherwise (exit 2) |
| `ALLOWED_ORIGINS` | `https://start.example.com` | comma-separated origins allowed to hit `/v1/*`; must match the origin of your `START_URL` exactly |
| `TOKEN` | *(empty)* | shared secret for callers without an `Origin` (curl); empty rejects them |
| `COMMANDS_DIR` | `/usr/lib/bootowser/commands` | where root hooks live |
| `DEFAULT_TIMEOUT_MS` | `30000` | per-request budget when `timeout_ms=` is absent |
| `MAX_TIMEOUT_MS` | `300000` | upper bound a request may ask for (larger values are clamped) |
| `MAX_OUTPUT_BYTES` | `1048576` | per stream; the response sets `"truncated":true` |
| `MAX_BODY_BYTES` | `1048576` | request body limit |
| `MAX_CONCURRENT` | `16` | in-flight requests before `503` |
| `ALLOW_NO_ORIGIN` | `0` | `1` lets origin-less callers through without a token |
| `ALLOW_NONLOOPBACK` | `0` | `1` allows a non-loopback `BIND` (do not) |

The sidecar also always accepts its *own* origin
(`http://127.0.0.1:PORT`, `http://localhost:PORT`), so the admin console
works without being listed.

## The origin gate

The security boundary is the `Origin` header: only pages served from
`ALLOWED_ORIGINS` may call the API. That is the right boundary because
`Origin` is set by the browser from the *document*, not forgeable by the
page, and the kiosk only ever displays pages from your `START_URL` (plus
whatever the navigation allow-list lets through — see
[security.md](security.md)).

Practical consequences:

- A page on another origin cannot call the API, even if it guesses the port.
- `curl` and scripts send no `Origin`; give them `TOKEN=` and pass
  `X-Bootowser-Token: …`. Anyone who can read `/etc/bootowser/control.conf`
  can use the token — that is the same privilege as reading it, so it buys
  ergonomics, not isolation.
- The token and the origin list are both checked with constant-time-ish
  comparison; the API never authenticates anyone *out* of being the kiosk
  user. `/v1/exec` is not a privilege escalation: it runs as the user the
  page already is.

## Local Network Access

Firefox 156 gates `fetch()` from an `https` page to `http://127.0.0.1`
behind a **Local Network Access** check (`network.lna.enabled`,
`network.lna.blocking`). Without intervention the kiosk page's calls to the
sidecar are refused or gated behind a permission prompt that nobody is
watching the screen to click — which presents as "the API is broken".

The sidecar cannot switch this off. The managed policy can:

```json
"network.lna.enabled":   { "Value": false, "Status": "locked" },
"network.lna.blocking":  { "Value": false, "Status": "locked" }
```

Both are in `runtime/etc/bootowser/policies/managed/policies.json` and CI
asserts they stay locked. Do not remove them; if you upgrade Firefox and
calls start failing with a network error in the page, check these first.

## Root hooks

`/v1/root` does **not** run arbitrary commands as root — that would be the
page owning the machine. It runs scripts from `COMMANDS_DIR` through:

```
/usr/bin/sudo -n /usr/lib/bootowser/commands/<name> [args…]
```

backed by the shipped sudoers rule (`/etc/sudoers.d/bootowser`):

```
bootowser ALL=(root) NOPASSWD: /usr/lib/bootowser/commands/* *
```

The wildcard matches everything *directly inside* the directory (a `/` is
never matched by a sudoers wildcard) and the trailing ` *` passes the
arguments. The sidecar re-checks, before every run:

- the name is a plain filename (no `/`, no `..`)
- the file exists, is a regular file, is executable
- it is **owned by root**
- it is not group- or world-writable

so a script that becomes writable by the wrong user stops being runnable
even if the sudoers rule is still there.

Rules for writing hooks:

1. **Validate your arguments like the untrusted input they are.** The page
   can send any `arg=`. Quote everything; never build a command string from
   an argument.
2. Keep scripts root-owned, mode `0755`, in that one directory.
3. Ship only what you need. Every file there is world-callable by design.

Two examples ship in `runtime/lib/bootowser/commands/`:
`whoami-root.sh` (prove the escalation path) and `restart-kiosk.sh`.

## Unit hardening

The interesting decisions in `bootowser-control.service`:

- **`NoNewPrivileges=false`** — explicitly false, because setuid exec is the
  entire point. In system mode this is safe *and* intentional: systemd only
  forces NNP for its seccomp filters when the manager is unprivileged; PID 1
  has `CAP_SYS_ADMIN` and installs them without it.
- **`SystemCallFilter=@system-service`** — an allow-list that includes
  `@setuid` (`setuid`, `setresuid`, `setgroups`, …) and `capset`, which is
  everything `sudo` needs to drop privileges correctly. After changing the
  set, re-check with `systemd-analyze syscall-filter @system-service`.
- **`RestrictSUIDSGID` is deliberately absent.** It only stops the unit from
  *creating* setuid files, and a `bootowser`-owned setuid file could escalate
  to nothing but `bootowser` — which the page already is. Leaving it out also
  means `sudo` never depends on a filter edge case we cannot test before the
  sudoers rule exists.
- **`MemoryDenyWriteExecute=true`** — the defence that matters for a
  network-facing parser. On kernels older than 6.3 (Debian 12's 6.1, for
  example) this falls back to a seccomp filter that `sudo`'s children
  inherit. If root hooks ever fail with an `mprotect`/`mmap` error in the
  journal, flip this line first.
- **`ReadWritePaths=-/run/sudo -/var/lib/sudo`** — `ProtectSystem=strict`
  would otherwise make sudo's ticket directory read-only.
- **`IPAddressDeny=any` + `IPAddressAllow=localhost`** — no outbound
  connections, ever; loopback only for the API itself.
- The unit omits nothing else the browser unit uses: `ProtectSystem=strict`,
  `ProtectHome`, `PrivateTmp`, `ProtectKernel*`, `RestrictRealtime`,
  `RestrictNamespaces`, `LockPersonality`, `SystemCallArchitectures=native`.

## Testing

```sh
tools/test-control.sh /path/to/bootowser-control
```

Walks the whole matrix against a throwaway config: origin gate, token gate,
preflight/CORS, stdout capture, exit codes, timeouts, truncation, every
`/v1/root` refusal, the non-loopback bind guard. It needs no root; the two
root-dependent checks (sudo escalation, world-writable refusal) are skipped
with a `skip` line when `sudo -n` is unavailable. Run it after every change
to `toolkit/bootowser-control/`.

Device-side, once installed:

```sh
systemctl status bootowser-control
journalctl -fu bootowser-control
curl -fsS http://127.0.0.1:29500/healthz
sudo -n /usr/lib/bootowser/commands/whoami-root.sh   # must print uid 0
```

## Troubleshooting

| symptom | cause |
| --- | --- |
| Page fetch fails with a network/CORS error | `ALLOWED_ORIGINS` does not match the page's origin exactly (scheme, host, port), or the LNA prefs were removed — see above |
| `403` from curl | no `Origin` and no (or wrong) `X-Bootowser-Token` |
| `400 … must be owned by root` | the hook is not root-owned, or is group/world-writable |
| `503 … sudo is not installed` | install `sudo`, or you do not need root hooks |
| `sudo: a password is required` in the journal | the sudoers rule is missing or fails `visudo -cf /etc/sudoers.d/bootowser` |
| unit not running at all | `ConditionPathExists` failed — no `/usr/lib/bootowser/bootowser-control`, i.e. the tree was installed without a patched build |
| root hook dies with `mprotect`/`mmap` errors | `MemoryDenyWriteExecute` on a kernel < 6.3 — comment it out in the unit |
