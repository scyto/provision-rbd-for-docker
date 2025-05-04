# Scripts for provisioing and deprovisioning RBDs for doccker bind mounts

This was another of my first experiments in what could i get ChatGPT / GitHub Copilot to do for me given I can't code even the most basic of shell scripts.

## The intent of these scripts is as follows':'

- Assumes that i want to store docker bind mounts as a RBDs on ceph
- That each service needs one or more RBDs
- That a give service will only run once on a swarm node (i.e. this wont be written too)
- That this is to let me evaluate if i think using cpehFS or cephRBD is better
- That this speeds up and makes it consistent adding rbds and removing rbds (after creating the provisioing script it is trivial to create a deprovision script within the same chatgpt cobnversations)
- while i did this for docker it can be used for any RBD that gets mounted over a network

## AI Observations':'

- boy do they like making the same mistake over and over
- chatGPT is great for initial creation
- github copilot in vscode is better to help refine and debug issues
- one should constantly challenege the tools to explain if they did the right things if somethings look odd - sometimes they will correct code, sometimes they will explain indeed they did do it right and why (and then i learn't something)

## This repo contains two scripts':'

1. **rbd provision script** - this provisions the RBD and creates a help script to be run on the client that copies all needed ceph files to the client (but does not mmount the rbd)
2. **the deprovision script** - this cleans up every created on the proxmox host, note it doesn't clean up the client, that you still have to do ny hand.

## 🐘 provision-docker-rbd.sh

This script provisions a Ceph RBD image for a given service in a dedicated namespace, sets up authentication, and generates a helper script to configure a guest (e.g., Docker host or VM) with access to the RBD image.

---

### 🚀 Features

- Creates a Ceph RBD namespace and image (if not already present)
- Configures Ceph client authentication with scoped OSD and MON capabilities
- Generates a base64 secret for libcephfs or RBD mount
- Produces a helper script for guests to securely pull credentials and mount the image
- Supports default and custom image sizes, names, and pool selection

---

### 📦 Requirements

- Ceph CLI tools available on the Proxmox host
- Access to the `/etc/pve/priv/ceph/` directory
- An existing Ceph pool (default: `docker-bind-rbd`)
- Guests must support SSH access and have `ceph-common` installed

---

### 📝 Usage

```bash
./provision-rbd.sh <service> [size-in-MiB] [image-name] [pool-name]
```

#### Arguments

| Argument        | Description                                                               | Default           |
|-----------------|---------------------------------------------------------------------------|-------------------|
| `<service>`     | **Required.** Name of the service. Used for namespace and client ID       | —                 |
| `[size-in-MiB]` | Optional. Size of the image in MiB                                        | `10240` (10 GiB)  |
| `[image-name]`  | Optional. RBD image name within the namespace                             | `data`            |
| `[pool-name]`   | Optional. Ceph pool to use                                                | `docker-bind-rbd` |

---

### 🧪 Examples

```bash
# Create a 10GiB RBD image named 'data' for 'portainer' in default pool
./provision-rbd.sh portainer

# Create a 20GiB RBD image named 'data' for 'redis'
./provision-rbd.sh redis 20480

# Create a 30GiB image named 'data' for 'postgres' in pool 'rbd-alt'
./provision-rbd.sh postgres 30720 data rbd-alt
```

---

### 📁 What It Does

For a given `<service>`, the script will:

- ✅ Create RBD namespace: `$service`
- ✅ Create RBD image: `/pool/service/data`
- ✅ Generate client keyring: `/etc/pve/priv/ceph/ceph.client.$service.keyring`
- ✅ Generate base64 secret: `/etc/pve/priv/ceph/$service.secret`
- ✅ Output guest helper script: `/etc/pve/priv/ceph/${service}-guest-pull.sh`

---

### 🧳 Guest Setup

From your guest VM or container host:

```bash
scp root@<proxmox-host>:/etc/pve/priv/ceph/portainer-guest-pull.sh /tmp/
bash /tmp/portainer-guest-pull.sh <proxmox-host>
```

This will:

- 📥 Pull the Ceph keyring, secret, and config over SSH
- 🔐 Install them into `/etc/ceph/`
- (🔧 Mapping the RBD device is **commented out by default**, but included in the script)

> You can uncomment and adjust the mapping logic depending on whether you're using `rbd` or `rbd-nbd`.

---

### 🔐 Notes

- You must run the script from a Proxmox host with access to `/etc/pve/priv/ceph/`.
- Guests should have SSH access to the Proxmox node to pull credentials.
- The generated guest script supports persistent SSH multiplexing to reduce login prompts.

---

## 🐘 deprovision-docker-rbd.sh

This script deprovisions a Ceph RBD service created using `provision-rbd.sh`. It safely removes the RBD image, namespace (if empty), Ceph authentication credentials, and all associated secrets and guest helper files from a Proxmox host.

---

## 🚀 Features

- Automatically unmaps the RBD device if it is still in use
- Deletes the RBD image and cleans up the namespace only if it is empty
- Removes Ceph client authentication and secrets
- Deletes any generated helper scripts and `.tar.gz` credential archives
- Confirms before deletion unless `--yes` is specified
- Only works on a Proxmox host with access to `/etc/pve/priv/ceph/`

---

## 🧳 Requirements

- Must be run on a **Proxmox host**
- Requires access to `ceph`, `rbd`, and `/etc/pve/priv/ceph`
- Requires appropriate privileges to remove Ceph auth, images, and secrets

---

## 📝 Usage

```bash
./delete-rbd-docker.service.sh <service-name> [--yes] [--image <name>] [--pool <name>]
