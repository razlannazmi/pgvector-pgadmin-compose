#!/usr/bin/env bash
#
# setup-volume.sh
#
# Creates (or reuses) a size-capped loopback filesystem for the Postgres data
# directory and mounts it at MOUNT_POINT, OR — if CAPPED=false — uses the
# plain host filesystem at MOUNT_POINT directly, with no size limit.
#
# This script is safe to re-run, AND it supports switching modes after the
# fact: if you already set it up capped and now want uncapped (or vice
# versa), it migrates whatever data is currently live at MOUNT_POINT into
# the new mode. It never deletes your old data — the previous copy is always
# kept on disk (as the old .img file, or a renamed backup directory), so a
# bad switch is always recoverable.
#
# Stop the stack before switching modes:  sudo docker compose down  (or: make down)
#
# Mode is controlled by CAPPED, set (in order of precedence):
#   1. --capped / --uncapped on the command line
#   2. volume.conf (cp volume.conf.example volume.conf)
#   3. the default below
#
set -euo pipefail

cd "$(dirname "$0")"

# ===== CONFIG — override via volume.conf (cp volume.conf.example volume.conf) ====
CAPPED="true"                               # false = plain host filesystem, no size cap
IMG_PATH="/var/lib/pgvector18.img"          # the loopback file (holds the real bytes)
MOUNT_POINT="/var/lib/postgresql/18/data"   # where docker-compose bind-mounts from
CAP_SIZE="10G"                              # HARD storage ceiling for Postgres (CAPPED=true only)
MIGRATE_MOUNT="/mnt/pgvector18-migrate"     # scratch mountpoint used only while switching modes
# =================================================================================

if [[ -f volume.conf ]]; then
  source volume.conf
fi

ASSUME_YES="false"
for arg in "$@"; do
  case "$arg" in
    --capped)   CAPPED="true" ;;
    --uncapped) CAPPED="false" ;;
    -y|--yes)   ASSUME_YES="true" ;;
    *)
      echo "Unknown argument: $arg (expected --capped, --uncapped, or -y/--yes)" >&2
      exit 1
      ;;
  esac
done

# --- must be root: creating/mounting a filesystem is privileged --------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (mount is privileged). Re-run with sudo." >&2
  exit 1
fi

confirm() {
  [[ "$ASSUME_YES" == "true" ]] && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' is required for switching modes but is not installed." >&2
    exit 1
  fi
}

refuse_if_stack_running() {
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'pgvector18'; then
    echo "ERROR: the pgvector18 container is still running." >&2
    echo "Stop the stack first: sudo docker compose down   (or: make down)" >&2
    exit 1
  fi
}

# --- figure out what's actually live right now, independent of CAPPED -------
currently_capped="false"
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
  currently_capped="true"
fi

# =================================================================================
# CASE 1: desired mode already matches what's live -> plain idempotent setup
# =================================================================================
if [[ "$CAPPED" == "$currently_capped" ]]; then

  if [[ "$CAPPED" != "true" ]]; then
    echo ">> CAPPED=false — plain host filesystem at ${MOUNT_POINT} (no size limit)"
    mkdir -p "$MOUNT_POINT"
    echo ">> Success."
    df -h "$MOUNT_POINT"
    exit 0
  fi

  echo ">> CAPPED=true — size-capped loopback volume"

  # 1. create the image file only if it does not exist
  if [[ ! -f "$IMG_PATH" ]]; then
    echo ">> Allocating ${CAP_SIZE} image at ${IMG_PATH}"
    if ! fallocate -l "$CAP_SIZE" "$IMG_PATH"; then
      echo "ERROR: could not allocate ${CAP_SIZE}. Not enough free disk?" >&2
      df -h "$(dirname "$IMG_PATH")" >&2
      exit 1
    fi
    echo ">> Formatting ${IMG_PATH} as ext4"
    mkfs.ext4 -q "$IMG_PATH"
  else
    echo ">> Image ${IMG_PATH} already exists — NOT reformatting (protects your data)"
  fi

  # 2. ensure the mount point exists
  mkdir -p "$MOUNT_POINT"

  # 3. add fstab entry BEFORE mounting, with ordering + safety options
  #   nofail                          : boot doesn't hang if the image is missing
  #   x-systemd.before=docker.service : force this mount to complete before Docker
  FSTAB_LINE="${IMG_PATH}  ${MOUNT_POINT}  ext4  loop,nofail,x-systemd.before=docker.service  0  0"
  if ! grep -qF "$IMG_PATH" /etc/fstab; then
    echo ">> Adding fstab entry (with Docker ordering + nofail)"
    echo "$FSTAB_LINE" >> /etc/fstab
    systemctl daemon-reload 2>/dev/null || true
  else
    echo ">> fstab entry already present — leaving it as-is"
  fi

  # 4. mount now (if not already mounted)
  if mountpoint -q "$MOUNT_POINT"; then
    echo ">> ${MOUNT_POINT} already mounted — skipping"
  else
    echo ">> Mounting via 'mount -a' (uses the fstab entry we just wrote)"
    mount -a
  fi

  # 5. verify
  if ! mountpoint -q "$MOUNT_POINT"; then
    echo "ERROR: ${MOUNT_POINT} is not mounted after setup. Aborting." >&2
    exit 1
  fi

  echo ">> Success. Capped volume is mounted:"
  df -h "$MOUNT_POINT"
  exit 0
fi

# =================================================================================
# CASE 2: switching modes — migrate whatever data is live into the new mode.
# Nothing is ever deleted: the previous copy is always left behind as a backup.
# =================================================================================
require rsync
refuse_if_stack_running
STAMP="$(date +%Y%m%d-%H%M%S)"

if [[ "$CAPPED" != "true" ]]; then
  # ---- capped -> uncapped ----
  echo ">> Switching CAPPED volume -> UNCAPPED plain filesystem"
  echo "   Live data at ${MOUNT_POINT} (inside ${IMG_PATH}) will be copied out to a"
  echo "   plain directory at the same path. ${IMG_PATH} is left on disk untouched as"
  echo "   a backup — delete it yourself once you've verified the switch worked."
  confirm ">> Proceed with the switch to uncapped?" || { echo "Aborted."; exit 1; }

  STAGING_DIR="/var/lib/pgvector18-uncapped-data"
  echo ">> Copying live data out to ${STAGING_DIR}"
  mkdir -p "$STAGING_DIR"
  rsync -aHAX --delete "$MOUNT_POINT"/ "$STAGING_DIR"/

  echo ">> Unmounting ${MOUNT_POINT}"
  umount "$MOUNT_POINT"

  echo ">> Removing fstab entry for ${IMG_PATH}"
  sed -i "\#${IMG_PATH}#d" /etc/fstab
  systemctl daemon-reload 2>/dev/null || true

  if [[ -d "$MOUNT_POINT" ]] && [[ -n "$(ls -A "$MOUNT_POINT" 2>/dev/null)" ]]; then
    BACKUP_DIR="${MOUNT_POINT}.pre-uncapped-${STAMP}"
    echo ">> ${MOUNT_POINT} is unexpectedly non-empty after unmount — moving it aside to ${BACKUP_DIR}"
    mv "$MOUNT_POINT" "$BACKUP_DIR"
  fi
  mkdir -p "$MOUNT_POINT"

  echo ">> Moving staged data into ${MOUNT_POINT}"
  rsync -aHAX --remove-source-files "$STAGING_DIR"/ "$MOUNT_POINT"/
  find "$STAGING_DIR" -depth -type d -empty -delete
  rmdir "$STAGING_DIR" 2>/dev/null || true

  echo ">> Success. Now running uncapped on the plain host filesystem:"
  df -h "$MOUNT_POINT"
  echo ">> Old capped image kept at ${IMG_PATH} as a backup (delete manually once verified)."
  exit 0
fi

# ---- uncapped -> capped ----
echo ">> Switching UNCAPPED plain filesystem -> CAPPED volume (limit ${CAP_SIZE})"
echo "   Live data at ${MOUNT_POINT} will be copied into a ${CAP_SIZE} loopback image."
echo "   The old plain directory is kept on disk as a backup, not deleted."
confirm ">> Proceed with the switch to capped (${CAP_SIZE})?" || { echo "Aborted."; exit 1; }

if [[ -f "$IMG_PATH" ]]; then
  echo ">> NOTE: ${IMG_PATH} already exists from a previous capped setup — reusing it"
  echo "   (its contents will be synced to match your current live data)."
else
  echo ">> Allocating ${CAP_SIZE} image at ${IMG_PATH}"
  if ! fallocate -l "$CAP_SIZE" "$IMG_PATH"; then
    echo "ERROR: could not allocate ${CAP_SIZE}. Not enough free disk?" >&2
    df -h "$(dirname "$IMG_PATH")" >&2
    exit 1
  fi
  echo ">> Formatting ${IMG_PATH} as ext4"
  mkfs.ext4 -q "$IMG_PATH"
fi

mkdir -p "$MIGRATE_MOUNT"
echo ">> Mounting the image at ${MIGRATE_MOUNT} to copy data in"
mount -o loop "$IMG_PATH" "$MIGRATE_MOUNT"
rsync -aHAX --delete "$MOUNT_POINT"/ "$MIGRATE_MOUNT"/
umount "$MIGRATE_MOUNT"
rmdir "$MIGRATE_MOUNT" 2>/dev/null || true

BACKUP_DIR="${MOUNT_POINT}.pre-capped-${STAMP}"
echo ">> Moving old plain directory aside to ${BACKUP_DIR}"
mv "$MOUNT_POINT" "$BACKUP_DIR"
mkdir -p "$MOUNT_POINT"

FSTAB_LINE="${IMG_PATH}  ${MOUNT_POINT}  ext4  loop,nofail,x-systemd.before=docker.service  0  0"
if ! grep -qF "$IMG_PATH" /etc/fstab; then
  echo ">> Adding fstab entry (with Docker ordering + nofail)"
  echo "$FSTAB_LINE" >> /etc/fstab
  systemctl daemon-reload 2>/dev/null || true
fi

echo ">> Mounting via 'mount -a'"
mount -a

if ! mountpoint -q "$MOUNT_POINT"; then
  echo "ERROR: ${MOUNT_POINT} is not mounted after setup. Aborting." >&2
  exit 1
fi

echo ">> Success. Now running capped (limit ${CAP_SIZE}):"
df -h "$MOUNT_POINT"
echo ">> Old uncapped data kept at ${BACKUP_DIR} as a backup (delete manually once verified)."
