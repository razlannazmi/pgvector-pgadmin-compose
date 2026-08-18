#!/usr/bin/env bash
#
# up.sh — alternative to `make up` for those who prefer a plain script.
# Runs the volume setup (capped or uncapped, per volume.conf), verifies it,
# then starts the stack.
#
set -euo pipefail

sudo ./setup-volume.sh   # create/mount the volume in whichever mode is configured (idempotent)
sudo ./check-mount.sh    # refuse to continue if a capped volume is configured but not mounted

sudo docker compose up -d
echo ""
echo "Stack is up. pgAdmin: http://127.0.0.1:5050/pgadmin4  (localhost only)"
