# 🔗 Ceph RBD Provisioning & Mounting Guide

This guide explains how to map, format, and mount a Ceph RBD image after running the provisioning script that installs required configs and authentication.

---

## 💪 Prerequisites

Your provisioning script must already have:

* ✅ Copied `ceph.conf` to `/etc/ceph/ceph.conf`
* ✅ Installed keyring as `/etc/ceph/portainer.secret`
* ✅ Created an RBD image in pool `docker-bind-rbd`, namespace `portainer`
* ✅ Assigned permissions to `client.portainer`

---

## 🚀 Mount and Prepare RBD

### 1. 🗺️ Map the RBD Image

```bash
sudo rbd map docker-bind-rbd/portainer/data --namespace portainer
```

Check mapping:

```bash
rbd showmapped
```

Expected output:

```
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

## ✅ Done!

You now have a mounted, writable Ceph RBD block device ready for use at:

```
/mnt/portainer-data
```

Use it directly or bind-mount it into containers, VMs, or services.
