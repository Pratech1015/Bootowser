#!/bin/sh
# Root hook: prove the escalation path works.
#
# Prints who it ran as. Expected on a working install:
#   ran as root (uid 0)
set -eu

echo "ran as $(id -un) (uid $(id -u))"
