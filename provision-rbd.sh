#!/bin/bash
set -euo pipefail

# === Help Message ===
show_help() {
cat <<EOF
📘 Ceph RBD Provisioning Script (per-service namespace-based)

Usage:
  \$0 <service> [size-in-MiB] [image-name] [pool-name]

Arguments:
  <service>        Name of the service (namespace + client ID)
  [size-in-MiB]    Optional size of the image (default: 10240 = 10 GiB)
  [image-name]     Optional image name within the namespace (default: 'data')
  [pool-name]      Optional pool name (default: 'docker-bind-rbd')

Examples:
  \$0 portainer
  \$0 redis 20480
  \$0 postgres 30720 data rbd-alt
EOF
}

# === Exit early on help flag
for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    show_help
    exit 0
  fi
done

# === Positional Args
SERVICE="${1:-}"
IMAGE_SIZE="${2:-10240}"
IMAGE_NAME="${3:-data}"
POOL="${4:-docker-bind-rbd}"

if [[ -z "$SERVICE" ]]; then
  echo "❌ Missing required argument: <service>"
  echo
  show_help
  exit 1
fi

# === Derived Values
NS="$SERVICE"
FULL_IMAGE="$POOL/$NS/$IMAGE_NAME"
CLIENT_NAME="client.$SERVICE"
KEYRING_PATH="/etc/pve/priv/ceph/ceph.$CLIENT_NAME.keyring"
SECRET_PATH="/etc/pve/priv/ceph/$SERVICE.secret"
PULL_SCRIPT="/etc/pve/priv/ceph/${SERVICE}-guest-pull.sh"

echo "📦 Creating RBD image for service: $SERVICE"
echo "⚒️  Image: $FULL_IMAGE"
echo "🔐 Client: $CLIENT_NAME"
echo

# === Ensure namespace exists
if ! rbd namespace list "$POOL" | grep -q "^$NS\$"; then
  echo "📁 Creating RBD namespace: $NS"
  rbd namespace create "$POOL/$NS"
else
  echo "📁 RBD namespace already exists: $NS"
fi

# === Create RBD image
if rbd info "$FULL_IMAGE" --namespace "$NS" --pool "$POOL" &>/dev/null; then
  echo "⚠️  Image already exists: $FULL_IMAGE"
else
  rbd create "$FULL_IMAGE" --size "$IMAGE_SIZE"
  echo "✅ RBD image created: $FULL_IMAGE (${IMAGE_SIZE}MiB)"
fi

# === Create client key with guaranteed working caps
echo "🔐 Ensuring Ceph client $CLIENT_NAME exists with full access and metadata read caps"
ceph auth get-or-create "$CLIENT_NAME" \
  mon "allow r" \
  osd "allow rwx pool=$POOL namespace=$NS, allow r pool=$POOL" \
  -o "$KEYRING_PATH"
echo "✅ Keyring saved to: $KEYRING_PATH"

# === Generate base64 secret for libcephfs/virtiofs mounting
SECRET=$(grep 'key = ' "$KEYRING_PATH" | awk '{print $3}')
echo -n "$SECRET" > "$SECRET_PATH"
chmod 600 "$SECRET_PATH"
echo "✅ Secret saved to: $SECRET_PATH"

# === Generate guest-side pull helper script (single-login scp-based)
echo "📃 Generating guest pull helper script: $PULL_SCRIPT"
cat > "$PULL_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

HOST="\${1:-pve1}"
SERVICE="$SERVICE"
CONTROL_SOCKET="/tmp/ssh_mux_\${HOST}_22_root"
FILES=("\$SERVICE.secret" "ceph.client.\$SERVICE.keyring" "minimal-ceph.conf")
PERMS=("600" "600" "644")
TARGET_NAMES=("\$SERVICE.secret" "ceph.client.\$SERVICE.keyring" "ceph.conf")

SSH_OPTS="-o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=\$CONTROL_SOCKET -o ControlPersist=30s"

# Create persistent SSH connection
ssh \$SSH_OPTS -Nf root@"\$HOST"

# Fetch files over single connection
for i in "\${!FILES[@]}"; do
  f="\${FILES[\$i]}"
  p="\${PERMS[\$i]}"
  t="\${TARGET_NAMES[\$i]}"
  scp -o ControlPath=\$CONTROL_SOCKET root@"\$HOST":/etc/pve/priv/ceph/"\$f" /tmp/"\$t"
  sudo install -m "\$p" -o root -g root /tmp/"\$t" /etc/ceph/"\$t"
done

# Close the persistent SSH connection
ssh -O exit -S "\$CONTROL_SOCKET" root@"\$HOST"

# Try to map the RBD image
#if sudo modprobe rbd && sudo rbd map $POOL/$NS/$IMAGE_NAME --id $SERVICE --keyfile /etc/ceph/$SERVICE.secret --namespace $NS; then
#  echo "🛂 RBD image mapped successfully using kernel driver."
#else
#  echo "⚠️ Kernel RBD map failed, falling back to rbd-nbd..."
#  if command -v rbd-nbd &>/dev/null; then
#    sudo apt-get install -y rbd-nbd
#    sudo rbd-nbd map $POOL/$NS/$IMAGE_NAME --id $SERVICE --keyfile /etc/ceph/$SERVICE.secret
#    echo "🛂 RBD image mapped successfully using rbd-nbd."
#  else
#    echo "❌ rbd-nbd is not installed and kernel RBD map failed. Manual intervention required."
#    exit 1
#  fi
#fi
#EOF

# Don't chmod the file (ignored in /etc/pve/priv), guest will run via `bash`
echo
cat <<EOF

📋 Done provisioning RBD for '$SERVICE'!

🔐 Auth + secret files:
  - $KEYRING_PATH
  - $SECRET_PATH

📂 Image created: $FULL_IMAGE

🗓 Guest pull helper:
  From your guest VM, run this one-liner to install Ceph config:

    scp root@<proxmox-host>:/etc/pve/priv/ceph/${SERVICE}-guest-pull.sh /tmp/ && bash /tmp/${SERVICE}-guest-pull.sh <proxmox-host>

EOF