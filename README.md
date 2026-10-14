# terraform-virtualbox

Describe VMs in one `terraform.tfvars`, run `make up`, and get running,
configured VirtualBox VMs on **fixed IPs**, with the **host as their NAT
gateway**:

1. **Terraform** creates the VMs from a Vagrant box and writes an Ansible
   inventory with each VM's IP address, groups and variables.
2. **Ansible** (started by Terraform) pins each VM's fixed IP, then sets the
   hostname, timezone and packages, authorizes your SSH key, and applies group
   roles (e.g. nginx on `web`).

```
terraform.tfvars ──► envs/dev ──► modules/fleet ──► modules/vm ──► virtualbox_vm
                                       │
                                       └──► inventory.yml ──► ansible/site.yml
```

**Full documentation:** [`docs/`](docs/README.md) explains how everything
works, step by step: architecture, host networking, the VM lifecycle, the
Kubernetes build, a complete reference, and troubleshooting.

## Networking

```
 VM 192.168.56.11 ─┐
 VM 192.168.56.21 ─┼─ vboxnet0 (host-only) ── host 192.168.56.1 ── NAT ──► Wi-Fi / Ethernet / VPN
 VM ...           ─┘   192.168.56.0/24                           (whatever is up right now)
```

- Each VM has **one** adapter, on the host-only network `vboxnet0`. That
  network is virtual and lives only on this machine, so the VM's IP never
  changes when the host moves between networks.
- The VM's default gateway is the host (`192.168.56.1`).
  `scripts/host-nat.sh` masquerades the VM subnet out of whichever interface
  holds the host's default route *at that moment*. When the host switches
  networks, new connections from the VMs follow automatically. Connections
  that were already open drop, as they do on the host.
- DNS defaults to public resolvers (`1.1.1.1`, `8.8.8.8`), which work on any
  uplink. Names that only resolve on a corporate network or VPN won't resolve
  in the VMs unless you set `dns_servers`.
- First boot uses DHCP (`.100`–`.199`), because the VirtualBox provider waits
  for an address before it reports the VM as created. Ansible then switches
  the VM to its fixed IP. Pick fixed IPs from `.10`–`.99`.

## Layout

| Path | What it is |
|---|---|
| `modules/vm` | One VM (or N identical VMs) — wraps the `virtualbox_vm` resource with validated inputs and IP/MAC outputs. |
| `modules/fleet` | A map of differently-sized VMs with fixed IPs, the generated Ansible inventory, and (optionally) the playbook run. |
| `modules/k8s-cluster` | A ready kubeadm Kubernetes cluster: 1 control plane + N ≥ 2 workers, built on `fleet`. |
| `envs/dev` | Plain VMs — you edit `terraform.tfvars`. |
| `envs/k8s` | Example Kubernetes cluster — you edit `main.tf`. |
| `ansible/` | `bootstrap.yml` (shared: fixed IP + baseline), `site.yml` (plain VMs), `k8s.yml` (cluster); roles `static_network`, `common`, `webserver`, `k8s_node`, `k8s_control_plane`, `k8s_worker`. |
| `scripts/` | One-time host setup: `vbox-network.sh` (host-only network + DHCP), `host-nat.sh` (host as NAT gateway, systemd service). |

## Prerequisites (once)

- VirtualBox 7.x, Terraform >= 1.9, Ansible (`ansible-core` >= 2.15).
- An **Ubuntu** Vagrant box for the VirtualBox provider, **with Guest
  Additions**. The provider reads VM IPs through Guest Additions, and the
  fixed-IP role writes netplan config. `bento/ubuntu-24.04` has both.
- Vagrant's insecure private key, which fresh boxes accept:
  ```sh
  curl -fsSLo ~/.ssh/vagrant_insecure https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant
  chmod 600 ~/.ssh/vagrant_insecure
  ```
- Host network + NAT gateway:
  ```sh
  make host-setup
  ```
  This runs `scripts/vbox-network.sh` as you, creating `vboxnet0` at
  `192.168.56.1/24` with DHCP on `.100`–`.199`. It then runs
  `sudo scripts/host-nat.sh install`, which enables IP forwarding, adds the
  masquerade and forward rules, and installs `vbox-nat.service` so they're
  re-applied at boot. Check it with `sudo scripts/host-nat.sh status`.

## Usage

```sh
cp envs/dev/terraform.tfvars.example envs/dev/terraform.tfvars
$EDITOR envs/dev/terraform.tfvars
make init
make up
```

A VM is one entry under `vms`; only `ip` is required:

```hcl
vms = {
  web-01 = {
    ip        = "192.168.56.11"       # fixed, inside network_cidr, outside DHCP range
    cpus      = 2
    memory_mb = 2048
    groups    = ["web"]               # Ansible groups -> roles in site.yml
    packages  = ["htop"]              # extra packages for this VM
    host_vars = { timezone = "UTC" }  # any other Ansible host var
  }
}
```

Terraform rejects IPs outside `network_cidr`, duplicates, and the gateway
address before creating anything.

Add, resize or remove an entry and run `make up` again. Ansible re-runs
automatically whenever a VM is created, a VM's settings change, or anything
under `ansible/` changes.

| Command | Does |
|---|---|
| `make host-setup` | One-time host network + NAT gateway. |
| `make up` / `make down` | Apply / destroy the environment (`ENV=dev` by default, `ENV=k8s` for the cluster). |
| `make provision` | Re-run Ansible only. |
| `make test` | `terraform test` for all modules, with a mocked provider. |
| `make lint` | `fmt -check`, `validate`, `ansible-lint`. |

After `make up`, `terraform -chdir=envs/dev output ssh_commands` prints
`ssh vagrant@<fixed-ip>` for each VM (logging in with your own key).

## Kubernetes cluster

```hcl
module "k8s" {
  source = "../../modules/k8s-cluster"

  cluster_name      = "lab"
  worker_count      = 2       # >= 2, plus 1 control plane = 3 nodes minimum
  first_host_number = 30      # control plane .30, workers .31, .32, ...
  image             = var.box_image
  network           = { cidr = "192.168.56.0/24", gateway = "192.168.56.1" }

  control_plane = { cpus = 2, memory_mb = 4096 }
  worker        = { cpus = 2, memory_mb = 4096 }

  kubernetes_version   = "1.37"
  ssh_private_key_file = var.ssh_private_key_file
}
```

```sh
cp envs/k8s/terraform.tfvars.example envs/k8s/terraform.tfvars   # box + keys
make init ENV=k8s
make up ENV=k8s
export KUBECONFIG=$PWD/envs/k8s/lab.kubeconfig
kubectl get nodes
```

`make up ENV=k8s` returns only once the cluster is **ready**. That means
every node is registered and `Ready`, and CoreDNS has rolled out. What it
builds:

- containerd 2.x (from Docker's apt repo; Kubernetes ≥ 1.36 needs it) with
  the systemd cgroup driver, swap off, `br_netfilter` and IP forwarding on.
- kubelet/kubeadm/kubectl from `pkgs.k8s.io` at the chosen minor version,
  held so `apt upgrade` doesn't move them. Each kubelet is pinned to its
  node's fixed IP.
- `kubeadm init` on the control plane, with Flannel as the CNI (pod network
  `10.244.0.0/16`). Then `kubeadm join` on each worker.
- The admin kubeconfig is copied to `envs/k8s/<cluster>.kubeconfig` and
  removed on `terraform destroy`.

To scale workers, change `worker_count` and run `make up ENV=k8s`. New
workers join, and nodes that already joined are left alone. When you scale
down, Terraform deletes the VMs, but the node objects stay in the cluster:
`kubectl delete node <name>` them first.

Before creating anything, Terraform rejects: fewer than 2 workers, a control
plane under 2 CPUs / 2 GiB, pod/service CIDRs that overlap the VM network or
each other, and node IPs that would run into the DHCP range.

Limits: single control plane (no HA — that needs a virtual IP such as
kube-vip in front of several API servers), Ubuntu guests only, and the nodes
need internet access during provisioning (through the host NAT).

## Adding configuration

- New role for a group: create `ansible/roles/<role>/tasks/main.yml` and add a
  play to `site.yml` with `hosts: <group>`. Put the group in a VM's `groups`.
- Group-wide variables: `ansible/group_vars/<group>.yml`.
- Turn off the automatic Ansible run with `run_ansible = false`.

## Notes and limits

- Provider: [`shekeriev/virtualbox`](https://registry.terraform.io/providers/shekeriev/virtualbox),
  a maintained fork of `terra-farm/virtualbox` that works with VirtualBox 7.
  It builds VMs from Vagrant boxes only, and can't set IPs or MACs itself.
  That's why Ansible applies the fixed IP. Changing the CPU count, memory or
  adapters replaces the VM rather than editing it in place.
- `host-nat.sh` inserts its rules at the top of `FORWARD`, ahead of Docker's
  and ufw's chains, which both drop forwarded traffic by default. If ufw or
  Docker is reloaded later and the VMs lose internet, run
  `sudo systemctl restart vbox-nat`.
- State is local (`envs/<env>/terraform.tfstate`), because the VMs exist only
  on this machine. Don't delete it while VMs are running.
