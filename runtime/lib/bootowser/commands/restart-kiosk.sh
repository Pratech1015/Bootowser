#!/bin/sh
# Root hook: restart the kiosk browser session.
#
# Arguments are untrusted (the kiosk page can send any). This command takes
# none, so anything extra is a misuse worth refusing loudly.
set -eu

[ "$#" -eq 0 ] || { echo "usage: restart-kiosk" >&2; exit 2; }

systemctl restart bootowser.service
