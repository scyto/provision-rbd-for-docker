#!/bin/bash
set -euo pipefail

# === Defaults ===
POOL="docker-bind-rbd"
IMAGE_NAME="data"
FORCE_DELETE=false

# === Help Message ===
show_help() {
cat <<EOF
🧹 Ceph RBD Service Cleanup Script (Proxmox)

Usage:
  $0 <service-name> [--yes] [--image name] [--pool name]

Arguments:
  <service-name>    Required: the name of the service (e.g., portainer)
  --yes             Optional: skip confirmation prompt
  --image <name>    Optional: image name (default: data)
  --pool <name>     Optional: Ceph pool name (default: docker-bind-rbd)

Examples:
  $0 portainer
  $0 redis --yes --image data
  $0 postgres --image logs --pool rbd-alt
EOF
}

# === Proxmox environment check ===
if [[ ! -d /etc/pve/priv/ceph ]]; then
  echo "❌ This script must be run on a Proxmox host with access to /etc/pve/priv/ceph/"
  exit 1
fi

# === Parse args ===
SERVICE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --yes)
      FORCE_DELETE=true
      shift
      ;;
    --image)
      IMAGE_NAME="$2"
      shift 2
      ;;
    --pool)
      POOL="$2"
      shift 2
      ;;
    *)
      if [[ -z "$SERVICE" ]]; then
        SERVICE="$1"
        shift
      else
        echo "❌ Unexpected argument: $1"
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$SERVICE" ]]; then
  echo "❌ Missing required service name."
  echo
  show_help
  exit 1
fi

# === Derived values ===
NS="$SERVICE"
FULL_IMAGE="$POOL/$NS/$IMAGE_NAME"
CLIENT_NAME="client.$SERVICE"
KEYRING_PATH="/etc/pve/priv/ceph/ceph.$CLIENT_NAME.keyring"
SECRET_PATH="/etc/pve/priv/ceph/$SERVICE.secret"
GUEST_SCRIPT="/etc/pve/priv/ceph/${SERVICE}-guest-pull.sh"
ARCHIVE_PATH="/etc/pve/priv/ceph/ceph-${SERVICE}.tar.gz"

# === Confirm deletion ===
if ! $FORCE_DELETE; then
  echo "⚠️  This will permanently delete:"
  echo "  - RBD image: $FULL_IMAGE"
  echo "  - RBD Namespace (if empty): $NS"
  echo "  - Ceph auth: $CLIENT_NAME"
  echo "  - Files: $KEYRING_PATH, $SECRET_PATH, $GUEST_SCRIPT"
  echo "  - Archive: $ARCHIVE_PATH"
  echo
  read -rp "❓ Are you sure you want to continue? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || {
    echo "❌ Aborted."
    exit 1
  }
fi

# === Try to unmap image (best effort) ===
echo "🔎 Checking for mapped RBD..."
if rbd showmapped | grep -q "$FULL_IMAGE"; then
  DEV=$(rbd showmapped | awk -v img="$FULL_IMAGE" '$3 == img { print $5 }')
  echo "🔌 Unmapping device $DEV"
  sudo rbd unmap "$DEV" || echo "⚠️  Failed to unmap $DEV (maybe busy?)"
fi

# === Delete RBD image ===
if rbd info "$FULL_IMAGE" --namespace "$NS" --pool "$POOL" &>/dev/null; then
  echo "🗑️  Deleting RBD image: $FULL_IMAGE"
  rbd rm "$FULL_IMAGE"
else
  echo "ℹ️  RBD image not found: $FULL_IMAGE"
fi

# === Delete namespace if empty ===
echo "📛 Checking if namespace $NS is empty..."
if [[ -z $(rbd ls --pool "$POOL" --namespace "$NS") ]]; then
  echo "🧼 Namespace is empty, removing: $POOL/$NS"
  rbd namespace rm "$POOL/$NS"
else
  echo "ℹ️  Namespace $NS not empty, skipping deletion"
fi

# === Delete Ceph client auth ===
if ceph auth get "$CLIENT_NAME" &>/dev/null; then
  echo "🗝️  Removing Ceph auth: $CLIENT_NAME"
  ceph auth del "$CLIENT_NAME"
else
  echo "ℹ️  Ceph auth not found: $CLIENT_NAME"
fi

# === Delete secrets, guest script, and archive ===
for f in "$KEYRING_PATH" "$SECRET_PATH" "$GUEST_SCRIPT" "$ARCHIVE_PATH"; do
  if [[ -f "$f" ]]; then
    echo "🧹 Deleting: $f"
    rm -f "$f"
  fi
done

echo "✅ Cleanup complete for service: $SERVICE"