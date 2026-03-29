# xliac

Ansible role and playbooks for provisioning cloud-init VMs on Xen hypervisors using `xl` directly.

## Why not libvirt/Terraform?

The libvirt Xen (libxl) driver is a second-class citizen compared to KVM/QEMU — volume paths not passed to xenstore, unsupported lifecycle flags, library version mismatches. Meanwhile `xl create` just works. This project uses Ansible to template `xl` config files and manage VM lifecycle directly.

## Requirements

**Hypervisor (Dom0):**
- Xen with `xl` toolstack
- `qemu-img` (for disk overlays)
- `genisoimage` (for cloud-init ISOs)

**Control machine:**
- Python 3 + Ansible (`pip install ansible`)
- SSH access to the hypervisor

## Quick start

```bash
# 1. Set up a virtualenv
python3 -m venv .venv && source .venv/bin/activate
pip install ansible ansible-lint

# 2. Configure your host
cp inventory.ini inventory.local.ini
# Edit inventory.local.ini with your hypervisor's hostname and SSH user

# 3. Add your SSH public key
# Edit group_vars/xen_hosts.yml — add your key to ssh_keys[]

# 4. Deploy
ansible-playbook -i inventory.local.ini site.yml
```

## Project structure

```
.
├── inventory.ini               # Inventory (edit or copy to .local.ini)
├── site.yml                    # Main playbook — reads vms/*.yml
├── runners.yml                 # GitHub runner playbook — reads runners/*.yml
├── destroy.yml                 # Interactive VM destruction + disk wipe
├── group_vars/
│   └── xen_hosts.yml           # Image registry, defaults, SSH keys
├── vms/                        # One YAML per VM
│   └── freebsd.yml
├── runners/                    # One YAML per GitHub runner (gitignored, contains tokens)
│   └── example.yml.dist
└── roles/xen_vm/
    ├── defaults/main.yml
    ├── tasks/
    │   ├── main.yml            # Dispatches present/absent
    │   ├── present.yml         # Download image → overlay → cloud-init → xl create
    │   └── absent.yml          # xl destroy (keeps disk)
    └── templates/
        ├── xen.cfg.j2          # Xen domain config
        ├── user-data.j2        # Cloud-init user-data
        ├── meta-data.j2        # Cloud-init meta-data
        ├── network-config.j2   # Cloud-init network-config (v2)
        └── runner-install.sh.j2 # GitHub runner install script
```

## Adding a VM

Drop a YAML file in `vms/`:

```yaml
# vms/webserver.yml
name: webserver
image: freebsd-15.0-zfs
memory: 2048
vcpus: 4
```

Everything else inherits from `vm_defaults` in `group_vars/xen_hosts.yml`. See `vms/freebsd.yml` for all available overrides.

## Adding a base image

Add an entry to the `images` dict in `group_vars/xen_hosts.yml`:

```yaml
images:
  ubuntu-24.04:
    url: https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    filename: noble-server-cloudimg-amd64.img
    format: qcow2
```

Images are downloaded and cached on the hypervisor at first use.

## Destroying a VM

`state: absent` in a VM definition stops the domain but keeps the disk (safe re-start). To fully destroy a VM including its disk:

```bash
ansible-playbook -i inventory.local.ini destroy.yml
```

This prompts for the VM name and requires confirmation.

## Network configuration

Default: DHCP on all interfaces via cloud-init network-config v2.

For static IPs, override per VM:

```yaml
# vms/db.yml
name: db
image: freebsd-15.0-zfs
network:
  version: 2
  ethernets:
    xn0:
      addresses:
        - 10.0.0.50/24
      gateway4: 10.0.0.1
      nameservers:
        addresses: [1.1.1.1, 8.8.8.8]
```

## Cloud-init customisation

`cloudinit_base` in `group_vars/xen_hosts.yml` is applied to every VM (serial console, sshd). Per-VM extras are appended:

```yaml
# vms/app.yml
name: app
image: freebsd-15.0-zfs
cloudinit:
  packages:
    - nginx
    - python3
  runcmd:
    - 'sysrc nginx_enable=YES'
    - 'service nginx start'
```

For a fully custom cloud-init, provide your own `cloudinit_template` path (not yet implemented — PRs welcome).

## GitHub Actions runners

Deploy self-hosted GitHub runners as VMs. The runner installs and registers automatically on first boot via cloud-init — no second SSH pass needed.

1. Copy the example: `cp runners/example.yml.dist runners/my-runner.yml`
2. Edit with your repo URL and [registration token](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
3. Deploy: `ansible-playbook -i inventory.local.ini runners.yml`

```yaml
# runners/my-runner.yml
name: my-runner
image: ubuntu-24.04
memory: 4096
vcpus: 4
disk_size: 32G
bridge: xenbr0

runner:
  repo_url: https://github.com/org/repo
  token: AXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
  labels: self-hosted,xen,linux
```

Runner definitions are gitignored (they contain tokens). Supports both Linux (Ubuntu) and FreeBSD guests.

## Lifecycle policies

Control what happens when a VM shuts down, reboots, or crashes:

```yaml
name: myvm
image: freebsd-15.0-zfs
autostart: true       # start on Dom0 boot via xendomains
on_poweroff: destroy  # destroy | restart | preserve
on_reboot: restart
on_crash: restart
```

| Setting | `destroy` | `restart` | `preserve` |
|---|---|---|---|
| **Behaviour** | Remove domain | Restart VM | Keep domain stopped |
| **Use case** | Ephemeral / `--rm` style | Persistent services | Debug crashed VMs |

Defaults: `on_poweroff: destroy`, `on_reboot: restart`, `on_crash: restart`.

**Autostart** creates a symlink in `/etc/xen/auto/` so `xendomains` starts the VM on Dom0 boot. Setting `state: absent` or running `destroy.yml` removes the symlink.

## Development

### Linting

This project uses `ansible-lint` to enforce best practices. Install it in your virtualenv:

```bash
source .venv/bin/activate
pip install ansible-lint
```

Run linting manually:

```bash
ansible-lint                     # lint all playbooks and roles
ansible-lint site.yml            # lint a specific playbook
```

Or use the test suite (includes syntax + lint checks):

```bash
./tests/test_syntax.sh
```

**Configuration:** `.ansible-lint` skips `command-instead-of-module` for `xl`, `qemu-img`, `genisoimage`, and `unxz` commands — these Xen-specific tools have no Ansible module alternatives.

## Notes

- **HVM only** — VMs boot via SeaBIOS with `xen_platform_pci=1` for PV driver passthrough
- **Disk format** — qcow2 COW overlays on base images; base images are never modified
- **Serial console** — available via `xl console <vmname>` after first reboot (loader.conf.local takes effect on second boot)
- FreeBSD cloud images use **nuageinit** (lightweight cloud-init), not full Python cloud-init

## Licence

BSD 2-Clause. See [LICENSE](LICENSE).
