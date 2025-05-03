# 🐘 provision-rbd-for-docker

This script provisions a Ceph RBD image for a given service in a dedicated namespace, sets up authentication, and generates a helper script to configure a guest (e.g., Docker host or VM) with access to the RBD image.

---

## 🚀 Features

- Creates a Ceph RBD namespace and image (if not already present)
- Configures Ceph client authentication with scoped OSD and MON capabilities
- Generates a base64 secret for libcephfs or RBD mount
- Produces a helper script for guests to securely pull credentials and mount the image
- Supports default and custom image sizes, names, and pool selection

---

## 📦 Requirements

- Ceph CLI tools available on the Proxmox host
- Access to the `/etc/pve/priv/ceph/` directory
- An existing Ceph pool (default: `docker-bind-rbd`)
- Guests must support SSH access and have `ceph-common` installed

---

## 📝 Usage (run on any promox node)

```bash
./provision-rbd.sh <service> [size-in-MiB] [image-name] [pool-name]
```

### Arguments

| Argument        | Description                                                               | Default           |
|-----------------|---------------------------------------------------------------------------|-------------------|
| `<service>`     | **Required.** Name of the service. Used for namespace and client ID       | —                 |
| `[size-in-MiB]` | Optional. Size of the image in MiB                                        | `10240` (10 GiB)  |
| `[image-name]`  | Optional. RBD image name within the namespace                             | `data`            |
| `[pool-name]`   | Optional. Ceph pool to use                                                | `docker-bind-rbd` |

---

## 🧪 Examples

```bash
# Create a 10GiB RBD image named 'data' for 'portainer' in default pool
./provision-rbd.sh portainer

# Create a 20GiB RBD image named 'data' for 'redis'
./provision-rbd.sh redis 20480

# Create a 30GiB image named 'data' for 'postgres' in pool 'rbd-alt'
./provision-rbd.sh postgres 30720 data rbd-alt
```

---

## 📁 What It Does

For a given `<service>`, the script will:

- ✅ Create RBD namespace: `$service`
- ✅ Create RBD image: `/pool/service/data`
- ✅ Generate client keyring: `/etc/pve/priv/ceph/ceph.client.$service.keyring`
- ✅ Generate base64 secret: `/etc/pve/priv/ceph/$service.secret`
- ✅ Output guest helper script: `/etc/pve/priv/ceph/${service}-guest-pull.sh`

---

## 🧳 Guest Setup (run on client that wull mount the rbd)

From your guest VM or container host:

```bash
 scp root@<pve-node-name>:/etc/pve/priv/ceph/portainer-guest-pull.sh /tmp/ && bash /tmp/portainer-guest-pull.sh <pve-node-name>
```

Note you will be asked to login multiple times, note if that is local or remote and use the right password.

This will:

- 📥 Pull the Ceph keyring, secret, and config over SSH
- 🔐 Install them into `/etc/ceph/`
- (🔧 Mapping the RBD device is **commented out by default**, but included in the script)

> You can uncomment and adjust the mapping logic depending on whether you're using `rbd` or `rbd-nbd`.

---

## 🔐 Notes

- You must run the script from a Proxmox host with access to `/etc/pve/priv/ceph/`.
- Guests should have SSH access to the Proxmox node to pull credentials.
- The generated guest script supports persistent SSH multiplexing to reduce login prompts.

---

# 🔗 Ceph RBD Provisioning & Mounting Guide

This guide explains how to map, format, and mount a Ceph RBD image after running the provisioning script that installs required configs and authentication.

---

## 💪 Prerequisites

Your have run both the provisioning script above, this uses portainer as the exaample assuming the original script was run as `./provision-rbd.sh portainer`
You ran the client side script as described above and it:

- ✅ Copied `ceph.conf` to `/etc/ceph/ceph.conf`
- ✅ Installed keyring as `/etc/ceph/portainer.secret`
- ✅ Created an RBD image in pool `docker-bind-rbd`, namespace `portainer`
- ✅ Assigned permissions to `client.portainer`

---

## 🚀 Mount and Prepare RBD

### 1. 🗺️ Map the RBD Image

```bash
sudo rbd map docker-bind-rbd/portainer/data --namespace portainer #i need to check this worked
```

Check mapping:

```bash
rbd showmapped
```

Expected output:

```bash
id  pool             namespace  image  snap  device
0   docker-bind-rbd  portainer  data   -     /dev/rbd0
```

---

### 2. 🧪 Check for Existing Filesystem

```bash
sudo blkid /dev/rbd0
```

If no filesystem is detected, format the device:

```bash
sudo mkfs.ext4 -L portainer_data /dev/rbd0
```

---

### 3. 📁 Mount the Device

```bash
sudo mkdir -p /mnt/portainer-data
sudo mount /dev/rbd0 /mnt/portainer-data
```

---

### 4. ✏️ Fix Permissions

To allow all users access (e.g., for Docker bind mounts):

```bash
sudo chmod 777 /mnt/portainer-data
```

Or to assign it to a specific user:

```bash
sudo chown $USER:$USER /mnt/portainer-data
```

---

## ♻️ Persist Mapping and Mount Across Reboots

### Option A: Add to `/etc/fstab`

```fstab
/dev/rbd0  /mnt/portainer-data  ext4  defaults,_netdev  0  2
```

---

### Option B: Use `/etc/ceph/rbdmap`

1. Add this line to `/etc/ceph/rbdmap`:

    ```ini
    docker-bind-rbd/portainer/data@portainer --namespace=portainer,keyfile=/etc/ceph/portainer.secret
    ```

2. Enable and start the rbdmap service:

    ```bash
    sudo systemctl enable rbdmap
    sudo systemctl start rbdmap
    ```

---

## ✅ Done'!'

You now have a mounted, writable Ceph RBD block device ready for use at:

```bash
/mnt/portainer-data
```

Use it directly or bind-mount it into containers, VMs, or services.
