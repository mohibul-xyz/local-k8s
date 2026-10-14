# 1. Architecture

## What the project does

You describe what you want, either a set of VMs or a Kubernetes cluster, in
a Terraform file. Running `make up` then:

1. creates the VMs in VirtualBox,
2. gives each VM a fixed IP address on a private network that only exists on
   your machine,
3. routes all VM internet traffic through your host, so it keeps working
   whatever network the host is on,
4. configures each VM with Ansible (packages, SSH key, roles), and, for a
   cluster, installs and joins Kubernetes,
5. returns only once everything is done (and, for a cluster, ready).

Running it again changes only what you changed. `make down` removes
everything.

## The pieces

```
┌──────────────────────────── your machine (host) ───────────────────────────┐
│                                                                            │
│  envs/<env>/          Terraform root: what you edit                        │
│     │                                                                      │
│     ▼                                                                      │
│  modules/k8s-cluster  (optional) turns "cluster_name + worker_count"       │
│     │                 into a list of nodes, IPs and Kubernetes settings    │
│     ▼                                                                      │
│  modules/fleet        a map of VMs → creates them, writes the Ansible      │
│     │   │             inventory, runs the playbook                         │
│     │   └──────────────────────────────┐                                   │
│     ▼                                  ▼                                   │
│  modules/vm                       ansible/                                 │
│     │  wraps virtualbox_vm          bootstrap.yml → static_network, common │
│     ▼                               site.yml      → + webserver            │
│  shekeriev/virtualbox provider      k8s.yml       → + k8s_* roles          │
│     │  drives VBoxManage                   │                               │
│     ▼                                      │ SSH                           │
│  VirtualBox ──── vboxnet0 (host-only, 192.168.56.0/24) ────────────────┐   │
│                    │ host = 192.168.56.1 (gateway)                     │   │
│                    │                                                   │   │
│  scripts/host-nat.sh: masquerade 192.168.56.0/24 → current uplink      │   │
│                    │                                                   │   │
│                    ▼                                                   │   │
│              Wi-Fi / Ethernet / VPN ──► internet                       │   │
└────────────────────────────────────────────────────────────────────────│───┘
                                                                         │
            ┌────────────┐  ┌────────────┐  ┌────────────┐               │
            │ VM .11     │  │ VM .21     │  │ VM .30 ... │ ◄─────────────┘
            └────────────┘  └────────────┘  └────────────┘
```

### Layer by layer

| Layer | Lives in | Responsible for | Not responsible for |
|---|---|---|---|
| **Environment** | `envs/dev`, `envs/k8s` | Your choices: which VMs or which cluster, box image, keys. Holds Terraform state. | Any logic; it only calls modules. |
| **k8s-cluster module** | `modules/k8s-cluster` | Turning cluster settings into nodes (names, IPs, sizes, groups). Cluster-level checks (CIDR overlap, IP range). Passing Kubernetes settings to Ansible. Cleaning up the kubeconfig. | Creating VMs or running Ansible; it hands that to `fleet`. |
| **fleet module** | `modules/fleet` | Creating each VM (via `vm`), validating fixed IPs, writing the Ansible inventory, deciding when Ansible must re-run, and running it. | Anything inside the guest. |
| **vm module** | `modules/vm` | One `virtualbox_vm` resource (or N identical ones), validated inputs, IP/MAC outputs. | Networking policy, Ansible. |
| **Provider** | `shekeriev/virtualbox` | Importing the Vagrant box, creating the VM, starting it, waiting until it has an IP. | Setting IPs, MACs, or anything in the guest. |
| **Ansible** | `ansible/` | Everything inside the guest: fixed IP, hostname, packages, SSH, Kubernetes. | Creating or deleting VMs. |
| **Host scripts** | `scripts/` | The host-only network, its DHCP server, and NAT/forwarding on the host. Run once. | Anything per VM. |

The split is deliberate. **Terraform owns things that exist or don't**
(VMs, files). **Ansible owns how a running machine is configured.** The
inventory file is the hand-off point between them.

## Repository map

```
terraform-virtualbox/
├── Makefile                    shortcuts: host-setup, init, up, down, provision, test, lint
├── README.md                   quick start
├── docs/                       you are here
├── scripts/
│   ├── vbox-network.sh         creates vboxnet0 + DHCP range (run as you)
│   └── host-nat.sh             host as NAT gateway + systemd service (run as root)
├── modules/
│   ├── vm/                     virtualbox_vm wrapper            (+ tests/)
│   ├── fleet/                  VMs + inventory + Ansible run    (+ tests/)
│   └── k8s-cluster/            kubeadm cluster on top of fleet  (+ tests/)
├── envs/
│   ├── dev/                    plain VMs, configured in terraform.tfvars
│   └── k8s/                    a cluster, configured in main.tf
└── ansible/
    ├── ansible.cfg
    ├── requirements.yml        collections: community.general, ansible.posix
    ├── bootstrap.yml           shared stage: connect, fixed IP, baseline
    ├── site.yml                plain VMs  = bootstrap + webserver
    ├── k8s.yml                 cluster    = bootstrap + k8s roles + readiness wait
    ├── group_vars/all.yml      defaults for every VM
    └── roles/
        ├── static_network/     fixed IP via netplan
        ├── common/             hostname, timezone, packages, SSH key, sshd
        ├── webserver/          example: nginx for group "web"
        ├── k8s_node/           containerd + kubelet/kubeadm/kubectl
        ├── k8s_control_plane/  kubeadm init, Flannel, join command, kubeconfig
        └── k8s_worker/         kubeadm join
```

## Design decisions

### Why one network adapter, on a host-only network?

What you asked for: **IPs that never change, and the host as gateway,
whatever network the host is on.**

- A **host-only network** (`vboxnet0`) is a virtual switch inside your
  machine. It isn't bridged to Wi-Fi or Ethernet, so nothing outside can
  renumber it. A VM at `192.168.56.11` stays there whether you're at home,
  in the office, or offline.
- The host has an address on that switch (`192.168.56.1`). Each VM's
  default route points at it. The host then **masquerades** (source-NATs)
  the traffic out of whichever interface currently has the default route.
  When you move from Wi-Fi to Ethernet, new connections from the VMs simply
  leave through Ethernet.
- **Why not a second, VirtualBox NAT adapter?** It also gives internet
  access, but the provider has to see an IP on every adapter before it
  reads any of them. Most Ubuntu Vagrant boxes only run DHCP on their
  *first* network card, so with two cards `terraform apply` would wait
  forever. One card avoids that, and it also makes the routing simple: one
  interface, one gateway.

### Why does Ansible set the fixed IP, not Terraform?

The provider has no way to set a VM's IP or MAC address. So each VM boots
with a temporary DHCP address (`.100`–`.199`). The provider needs some
address anyway: it waits until the guest reports one before it considers
the VM created. Ansible then logs in on that temporary address, writes a
static netplan config, applies it, and reconnects on the fixed address.
[Chapter 3](03-vm-lifecycle.md#stage-4--fixed-ip-static_network) walks
through it.

### Why does Terraform run Ansible?

So that one command does everything, and `make up` only finishes when the
machines are actually usable. Terraform knows when VMs are created or
replaced, so it re-runs Ansible exactly when needed (see
[re-run triggers](03-vm-lifecycle.md#when-does-ansible-run-again)). You can
still run Ansible on its own with `make provision`, or turn the automatic
run off (`run_ansible = false` in `envs/dev`).

### Why the `shekeriev/virtualbox` provider?

It is a maintained fork of `terra-farm/virtualbox`, the original
community provider. It works with VirtualBox 7 and has a stable release
(0.0.4). The original only has an alpha (`0.2.2-alpha.1`). Both have the
same resource schema. Its limits shape a lot of this design: it builds
VMs only from Vagrant boxes, can't set IPs or MACs, and replaces a VM
rather than editing it.

### Why local Terraform state?

The VMs exist only on this machine, so a remote backend would only add a
dependency. State lives in `envs/<env>/terraform.tfstate`. Don't delete it
while VMs exist: Terraform would lose track of them (see
[recovery](06-operations.md#terraform-state-is-lost-or-out-of-sync)).

### Why kubeadm and Flannel for Kubernetes?

kubeadm is the upstream, standard way to build a cluster, so what you
learn here applies to real clusters. Flannel is the simplest CNI that
works out of the box with kubeadm's default pod network
(`10.244.0.0/16`), and it needs no extra configuration with a single
network interface.
