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

Note:
  This script must be run on the Proxmox host with sudo privileges.

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

# === Check for Proxmox Node ===
if [[ ! -d "/etc/pve" || ! -x "/usr/bin/pveversion" ]]; then
  echo "❌ This script must be run on a Proxmox node."
  echo "🔑 Please ensure you are running this script on a valid Proxmox host."
  exit 1
fi

# === Check for sudo privileges ===
if ! sudo -n true 2>/dev/null; then
  echo "❌ This script requires sudo privileges to run."
  echo "🔑 Please ensure you have sudo access and try again."
  exit 1
fi

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
PULL_SCRIPT="/tmp/${SERVICE}-guest-pull.sh" # Generate the script in /tmp
TAR_FILE="/tmp/ceph-${SERVICE}.tar.gz"

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

# 🔐 Ceph Client Capabilities for $CLIENT_NAME
#
# This access policy grants:
# - Full read/write/map access to RBD images in the `client name` namespace only
# - Read-only + map (no write) access to the root namespace of the pool
#
# This prevents accidental access to other namespaces while allowing mapping
# of images in the intended namespace without requiring broad pool-level privileges.
#
# Notes:
# - Required to avoid mapping failures when using the `--namespace` flag or
#   image paths like `pool/portainer/image`
# - `allow rx` on the pool ensures Ceph can resolve and map images cleanly,
#   even when operating solely in a namespace
# - No access is granted to any namespace other than `client name`
#
# - This does mean dont store images in the root namespace of the pool as all clients could mount those as read
#
# Cap command:

ceph auth get-or-create "$CLIENT_NAME" \
  mon "allow r" \
  osd "allow rwx pool=$POOL namespace=$NS, allow rx pool=$POOL" \
  -o "$KEYRING_PATH"
echo "✅ Keyring saved to: $KEYRING_PATH"

# === Generate base64 secret for libcephfs mounting
SECRET=$(grep 'key = ' "$KEYRING_PATH" | awk '{print $3}')
echo -n "$SECRET" > "$SECRET_PATH"
chmod 600 "$SECRET_PATH"
echo "✅ Secret saved to: $SECRET_PATH"

# === Generate service-specific Ceph configuration file
SERVICE_CONF_PATH="/etc/ceph/${SERVICE}.conf"
FSID=$(ceph fsid) # Retrieve the Ceph FSID dynamically

echo "📃 Generating service-specific Ceph configuration file: $SERVICE_CONF_PATH"
cat > "$SERVICE_CONF_PATH" <<EOF
[global]
fsid = $FSID

[client.$SERVICE]
keyfile = /etc/ceph/$SERVICE.secret
EOF

chmod 644 "$SERVICE_CONF_PATH"
echo "✅ Service configuration file saved to: $SERVICE_CONF_PATH"


# === Generate guest-side pull helper script
echo "📃 Generating guest pull helper script: $PULL_SCRIPT"
cat > "$PULL_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

SERVICE="$SERVICE"
TMP_DIR="/tmp/ceph-\${SERVICE}"
CEPH_DIR="/etc/ceph"
SERVICE_CONF="\${CEPH_DIR}/\${SERVICE}.conf"
GLOBAL_CONF="\${CEPH_DIR}/ceph.conf"

# Step 1: Move the secret and keyring to /etc/ceph
echo "🔐 Moving secret and keyring to \$CEPH_DIR..."
sudo mv "\$TMP_DIR/\$SERVICE.secret" "\$CEPH_DIR/"
sudo mv "\$TMP_DIR/ceph.client.\$SERVICE.keyring" "\$CEPH_DIR/"

# Step 2: Handle the service.conf and ceph.conf
if [[ ! -f "\$GLOBAL_CONF" ]]; then
  echo "📃 No global ceph.conf found. Moving \$SERVICE.conf to \$CEPH_DIR..."
  sudo mv "\$TMP_DIR/\$SERVICE.conf" "\$GLOBAL_CONF"
else
  echo "📃 Global ceph.conf exists. Checking FSID..."
  NEW_FSID=\$(grep '^fsid' "\$TMP_DIR/\$SERVICE.conf" | awk '{print \$3}')
  CURRENT_FSID=\$(grep '^fsid' "\$GLOBAL_CONF" | awk '{print \$3}' || true)

  if [[ "\$NEW_FSID" != "\$CURRENT_FSID" ]]; then
    echo "⚠️ FSID mismatch detected!"
    read -p "Do you want to overwrite the FSID in \$GLOBAL_CONF with the new FSID? (y/N): " OVERWRITE_FSID
    if [[ "\$OVERWRITE_FSID" =~ ^[Yy]$ ]]; then
      echo "🔄 Overwriting FSID in \$GLOBAL_CONF..."
      sudo sed -i "s/^fsid = .*/fsid = \$NEW_FSID/" "\$GLOBAL_CONF"
    else
      echo "❌ FSID mismatch not resolved. Exiting."
      exit 1
    fi
  fi

  echo "📃 Checking for [client.\$SERVICE] section in \$GLOBAL_CONF..."
  if ! grep -q "^\[client.\$SERVICE\]" "\$GLOBAL_CONF"; then
    echo "🔄 Adding [client.\$SERVICE] section to \$GLOBAL_CONF..."
    sudo cat >> "\$GLOBAL_CONF" <<EOF2

[client.\$SERVICE]
\$(grep -A 1 "^\[client.\$SERVICE\]" "\$TMP_DIR/\$SERVICE.conf" | tail -n +2)
EOF2
  else
    echo "📃 [client.\$SERVICE] section already exists. Verifying..."
    EXISTING_CLIENT_SECTION=\$(grep -A 1 "^\[client.\$SERVICE\]" "\$GLOBAL_CONF" || true)
    NEW_CLIENT_SECTION=\$(grep -A 1 "^\[client.\$SERVICE\]" "\$TMP_DIR/\$SERVICE.conf" || true)

    if [[ "\$EXISTING_CLIENT_SECTION" != "\$NEW_CLIENT_SECTION" ]]; then
      echo "⚠️ [client.\$SERVICE] section differs!"
      read -p "Do you want to overwrite the [client.\$SERVICE] section in \$GLOBAL_CONF? (y/N): " OVERWRITE_CLIENT
      if [[ "\$OVERWRITE_CLIENT" =~ ^[Yy]$ ]]; then
        echo "🔄 Overwriting [client.\$SERVICE] section in \$GLOBAL_CONF..."
        sudo sed -i "/^\[client.\$SERVICE\]/,/^$/d" "\$GLOBAL_CONF"
        sudo cat >> "\$GLOBAL_CONF" <<EOF2

[client.\$SERVICE]
\$(grep -A 1 "^\[client.\$SERVICE\]" "\$TMP_DIR/\$SERVICE.conf" | tail -n +2)
EOF2
      else
        echo "❌ [client.\$SERVICE] section mismatch not resolved. Exiting."
        exit 1
      fi
    else
      echo "✅ [client.\$SERVICE] section matches. No changes needed."
    fi
  fi
fi

# Cleanup
echo "🧹 Cleaning up temporary files created by this script..."
rm -f "\$TMP_DIR/\$SERVICE.secret"
rm -f "\$TMP_DIR/ceph.client.\$SERVICE.keyring"
rm -f "\$TMP_DIR/\$SERVICE.conf"
rm -f "\$TMP_DIR/\${SERVICE}-guest-pull.sh"
rm -f "\/tmp/\${SERVICE}.tar.gz"
rmdir "\$TMP_DIR" 2>/dev/null || true  # Remove the directory if it's empty

echo "✅ Temporary files cleaned up!"

echo "✅ Ceph configuration successfully installed!"
EOF

# Ensure the script is executable
chmod +x "$PULL_SCRIPT"
echo "✅ Guest pull helper script saved to: $PULL_SCRIPT"


# === Create tar.gz file for transfer
TAR_FILE="/etc/pve/priv/ceph/ceph-${SERVICE}.tar.gz"  # Define the tarball path

# Ensure the guest-side script is executable
chmod +x "$PULL_SCRIPT"

# Create a temporary directory for the tarball preparation
TMP_DIR="/tmp/ceph-${SERVICE}"  # Temporary directory for tarball preparation
mkdir -p "$TMP_DIR"  # Ensure the directory exists

# Copy files into the temporary directory with the desired structure
cp "$SECRET_PATH" "$TMP_DIR/$SERVICE.secret"
cp "$KEYRING_PATH" "$TMP_DIR/ceph.client.$SERVICE.keyring"
cp "$SERVICE_CONF_PATH" "$TMP_DIR/$SERVICE.conf"
cp "$PULL_SCRIPT" "$TMP_DIR/${SERVICE}-guest-pull.sh"

# Create the tarball with the correct structure
tar -czf "$TAR_FILE" -C /tmp "ceph-${SERVICE}"

if [[ $? -eq 0 ]]; then
  echo "✅ tar.gz file created: $TAR_FILE"
else
  echo "❌ Failed to create tar.gz file: $TAR_FILE"
  exit 1
fi

# === Clean up the temporary directory and other temporary files
echo "🧹 Cleaning up temporary files and directories..."

# Remove the tarball preparation directory
rm -rf "$TMP_DIR"

# Remove other temporary files created in /tmp
rm -f "/tmp/${SERVICE}-guest-pull.sh"
rm -f "/tmp/ceph-${SERVICE}.tar.gz"

echo "✅ All temporary files cleaned up!"

# === Output instructions for the user
echo
cat <<EOF

📋 Done provisioning RBD for '$SERVICE'!

🔐 Auth + secret files:
  - $KEYRING_PATH
  - $SECRET_PATH

📂 Image created: $FULL_IMAGE

🗓 Guest pull helper:
  From your guest VM, run this one-liner to install Ceph config:

    scp root@<proxmox-host>:/etc/ceph/ceph-${SERVICE}.tar.gz /tmp/ && tar -xzf /tmp/ceph-${SERVICE}.tar.gz -C /tmp && bash /tmp/ceph-${SERVICE}/${SERVICE}-guest-pull.sh

EOF