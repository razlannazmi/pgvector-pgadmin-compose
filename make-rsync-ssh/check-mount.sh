#!/usr/bin/env bash
#
# check-mount.sh
# Safety net: refuse to start Postgres unless the capped filesystem is
# actually mounted. Without this, an unmounted data dir would let the
# Postgres image run initdb on a bare directory and appear to "lose" your
# data.
#
# Skipped when CAPPED=false (see volume.conf.example) — uncapped setups use
# the plain host filesystem directly, so there's no mount to verify. Reads
# the same CAPPED setting as setup-volume.sh (volume.conf, env, or flags),
# so the two scripts always agree on which mode is active.
#
set -euo pipefail

cd "$(dirname "$0")"

CAPPED="true"
MOUNT_POINT="/var/lib/postgresql/18/data"

if [[ -f volume.conf ]]; then
  source volume.conf
fi

for arg in "$@"; do
  case "$arg" in
    --capped)   CAPPED="true" ;;
    --uncapped) CAPPED="false" ;;
    *)
      echo "Unknown argument: $arg (expected --capped or --uncapped)" >&2
      exit 1
      ;;
  esac
done

if [[ "$CAPPED" != "true" ]]; then
  echo ">> CAPPED=false — skipping mount check (using plain host filesystem)."
  exit 0
fi

if ! mountpoint -q "$MOUNT_POINT"; then
  echo "REFUSING TO START: ${MOUNT_POINT} is not a mounted filesystem." >&2
  echo "The capped loopback volume is not mounted. Run: sudo ./setup-volume.sh" >&2
  exit 1
fi

echo ">> Mount check passed: ${MOUNT_POINT} is mounted."
