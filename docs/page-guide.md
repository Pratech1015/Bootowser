# Making a page for Bootowser

This is the hands-on guide: how to give your kiosk page shell commands it
can run on the device, with nothing more than HTML and a little shell.
The full API reference lives in [control.md](control.md); this page gets
you from zero to a working page.

## What you are building

```
your page (START_URL)  ──fetch()──►  http://127.0.0.1:29500
                                        │
                                        ├─ /v1/exec   runs a shell command as the kiosk user
                                        └─ /v1/root   runs one of your root-owned scripts as root
```

You need three things:

1. **The page** — any HTML served over `http://` or `https://` from a real
   origin (a URL with a host in it).
2. **The commands** — either shell text your page sends directly, or small
   scripts you drop into `/usr/lib/bootowser/commands/` for root to run.
3. **One config line** — `ALLOWED_ORIGINS` in
   `/etc/bootowser/control.conf`, so the sidecar knows your page is
   allowed to call it.

## Step 1: serve your page

Any web server will do — nginx, Apache, a NAS share, even
`python3 -m http.server 8000` on the device while you develop. What
matters is the URL, because you will need its **origin**: scheme, host
and port, **no path**.

| your page is at | its origin |
| --- | --- |
| `https://start.example.com/kiosk.html` | `https://start.example.com` |
| `http://192.168.1.50:8000/index.html` | `http://192.168.1.50:8000` |
| `file:///opt/kiosk/index.html` | *none — file:// does not work, see below* |

`file://` and `about:blank` pages have no usable origin: the browser
sends `Origin: null` and the sidecar refuses it. Serve over HTTP.

Point the kiosk at it and allow the same origin, then restart:

```ini
# /etc/bootowser/bootowser.conf
START_URL="http://192.168.1.50:8000/index.html"
```

```ini
# /etc/bootowser/control.conf
ALLOWED_ORIGINS=http://192.168.1.50:8000
```

```sh
sudo systemctl restart bootowser
```

`ALLOWED_ORIGINS` accepts a comma-separated list if you have more than
one origin (say, a development laptop and production). The default
`https://start.example.com` matches nothing real — if you forget to
change it, every call gets a `403` and nothing else fails, which is the
most common setup mistake.

**`https` pages work too.** The sidecar is plain `http` on loopback, but
browsers exempt loopback from mixed-content blocking, and the shipped
policy already turns off Firefox 156's Local Network Access check
(`network.lna.enabled`). Both are required and both are in the default
policy file — if fetches start failing with a network error after a
Firefox upgrade, re-read [control.md](control.md#local-network-access).

## Step 2: add commands

There are two kinds, and which one you use depends on who has to run it.

### Shell commands as the kiosk user — no files needed

Anything the `bootowser` user may do, your page can ask for directly via
`/v1/exec`. The sidecar runs `sh -c` with your text. No setup at all:

```js
const r = await fetch('/v1/exec', {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ cmd: 'df -h /' }),
});
const res = await r.json();
console.log(res.exit, res.stdout);
```

Good for: reading state, deleting the profile cache, calling user-level
tools, anything that must not need root.

### Root hooks — scripts in a fixed directory

Root is **script-shaped**: the sidecar will only ever run a file directly
inside `/usr/lib/bootowser/commands/`, through `sudo -n`, if that file is
root-owned and not group- or world-writable. You cannot send a root shell,
a path, or anything outside that directory.

Create one:

```sh
sudo tee /usr/lib/bootowser/commands/screen-power.sh >/dev/null <<'EOF'
#!/bin/sh
# Turn the display on, off or into standby. Argument 1 must be one of
# exactly three words -- no interpolation, no surprises.
set -eu

case "${1:-}" in
  on|off|standby) ;;
  *) echo "usage: screen-power on|off|standby" >&2; exit 2 ;;
esac

# xset talks to the kiosk's own X display.
export DISPLAY=:0
exec xset dpms force "$1"
EOF
sudo chown root:root /usr/lib/bootowser/commands/screen-power.sh
sudo chmod 0755 /usr/lib/bootowser/commands/screen-power.sh
```

Stop and re-read that `case` block: **an argument from a web page is
attacker-influenced input**, even when the page is yours, because anything
that can change the page gains whatever your script does. Whitelist fixed
words or check `case "$1" in *[!0-9]*)` for numbers — never paste an
argument into a command line unexamined.

Why root-owned matters: the sidecar stat()s the file before every run and
refuses it otherwise, so a script that later becomes group-writable stops
working instead of becoming a hole. If your hook refuses to run, check
`ls -l` first.

Two hooks ship already — `whoami-root.sh` (proves escalation works) and
`restart-kiosk.sh` (restarts the browser session).

### Listing what is available

`GET /v1/commands` returns `{"ok":true,"commands":["screen-power.sh",…]}`.
One catch: browsers do **not** attach an `Origin` header to same-origin
GET requests, and the sidecar refuses requests without one — so from your
page, this GET needs either a token (below) or `ALLOW_NO_ORIGIN=1` in
`control.conf`. That setting is safer than it sounds: a *cross-origin*
page always sends its origin, and the allow-list still refuses it. POSTs
(`/v1/exec`, `/v1/root`) always carry an origin and work out of the box —
which is why the example below only uses POSTs.

## Step 3: the page

A complete, working page. It calls both kinds of command and handles the
failure modes you will actually hit.

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Kiosk</title>
<style>
  body { font: 18px system-ui; background: #111; color: #eee; padding: 2rem; }
  button { font: inherit; padding: .6em 1.2em; margin: .3em; }
  pre { background: #222; padding: 1em; white-space: pre-wrap; }
</style>
</head>
<body>
<h1>Front desk</h1>

<button onclick="diskSpace()">Disk space</button>
<button onclick="rootCall('restart-kiosk.sh')">Restart kiosk</button>
<button onclick="rootCall('screen-power.sh', 'standby')">Screen standby</button>

<pre id="out">idle</pre>

<script>
const out = document.getElementById('out');

async function call(path, body) {
  out.textContent = 'running…';
  const r = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  let res;
  try { res = await r.json(); }
  catch { throw new Error(`sidecar returned HTTP ${r.status}`); }
  if (!r.ok || res.ok === false) throw new Error(res.error || `HTTP ${r.status}`);
  return res;
}

async function diskSpace() {
  try {
    const res = await call('/v1/exec',
                           new URLSearchParams({ cmd: 'df -h /' }));
    out.textContent = res.stdout || '(no output)';
  } catch (e) { out.textContent = 'error: ' + e.message; }
}

async function rootCall(name, ...args) {
  try {
    const body = new URLSearchParams({ name });
    for (const a of args) body.append('arg', a);   // repeated key = list
    const res = await call('/v1/root', body);
    if (res.timed_out) throw new Error('command timed out');
    out.textContent =
      `exit ${res.exit}\n` +
      (res.stdout || '') + (res.stderr || '');
  } catch (e) { out.textContent = 'error: ' + e.message; }
}
</script>
</body>
</html>
```

Notes on the bits that matter:

- `URLSearchParams` produces `application/x-www-form-urlencoded`, which
  is what the sidecar parses. It arrives as a **simple** request, so
  there is no CORS preflight to get wrong, even cross-origin.
- `new URLSearchParams({ arg: a })` only keeps one `arg`, so the example
  `append`s each argument onto the body — the sidecar accepts repeated
  keys, up to 32 arguments of 4 KB each.
- The `cmd` limit is 64 KB; responses are capped at 1 MB per stream with
  `"truncated": true` when hit.
- `restart-kiosk.sh` contains `systemctl restart bootowser.service`, so
  the page that clicked it is about to be torn down — expect the fetch to
  fail *sometimes* even though the restart worked.

## Response shapes

Success (HTTP 200 — check `exit` for the command's own result):

```json
{"ok":true,"exit":0,"timed_out":false,"truncated":false,
 "duration_ms":14,"stdout":"…","stderr":""}
```

Refusal (the command never ran):

```json
{"ok":false,"error":"command must be owned by root"}
```

| HTTP | meaning |
| --- | --- |
| `200` | the command ran; look at `exit` |
| `400` | bad request, or a `/v1/root` refusal (see `error`) |
| `403` | your origin is not in `ALLOWED_ORIGINS` (or token missing) |
| `413` | body too large |
| `500` | the command could not be started at all |
| `503` | sidecar busy (`MAX_CONCURRENT`), or `sudo` not installed |

A command that fails is still `200` with a non-zero `exit` — HTTP
describes the request, `exit` describes the command.

## Calling from curl, and the token

Scripts and curl send no `Origin`, so they need a token. Set one in
`control.conf`:

```ini
TOKEN=change-me
```

```sh
curl -sS -X POST http://127.0.0.1:29500/v1/exec \
     -H 'X-Bootowser-Token: change-me' \
     -d 'cmd=uptime'
```

Anyone who can read `control.conf` can use the token, so treat it as
convenience, not isolation. Browsers cannot see it unless your page
leaks it — do not put it in your HTML.

There is also a small admin console at
`http://127.0.0.1:29500/` (same-origin, so it always works) — the
quickest way to see whether an endpoint behaves before you blame your
page.

## Testing before deploy

```sh
# 1. is the sidecar up?
curl -fsS http://127.0.0.1:29500/healthz          # {"ok":true,"api":1}

# 2. would your page be allowed?
curl -sS -X POST http://127.0.0.1:29500/v1/exec \
     -H 'Origin: http://192.168.1.50:8000' -d 'cmd=true'

# 3. does your root hook escalate?
sudo -n /usr/lib/bootowser/commands/whoami-root.sh  # ran as root (uid 0)

# 4. the full matrix (runs against a built binary, no root needed)
tools/test-control.sh /path/to/bootowser-control
```

Then check the audit trail: `journalctl -fu bootowser-control` logs
every execution with origin, exit code and duration.

## Checklist

- [ ] Page served over `http(s)` from a real origin (not `file://`)
- [ ] `ALLOWED_ORIGINS` contains exactly that origin — scheme, host, port, no path
- [ ] `bootowser.conf` `START_URL` points at the same page
- [ ] Root hooks live in `/usr/lib/bootowser/commands/`, root-owned, `0755`
- [ ] Every hook validates its arguments (whitelist, never splice)
- [ ] Page handles `403`, timeouts and non-zero exits instead of hanging
- [ ] `sudo systemctl restart bootowser`, then watch it work once for real

When something misbehaves, [control.md](control.md#troubleshooting) has
the symptom-by-symptom table.
