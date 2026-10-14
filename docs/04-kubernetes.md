# 4. Kubernetes cluster

`modules/k8s-cluster` builds a working kubeadm cluster from a handful of
settings. It reuses everything from [chapter 3](03-vm-lifecycle.md):
the same VM creation, fixed IPs and baseline. Then it adds container
runtime, Kubernetes and network stages, and only finishes once the
cluster is ready.

## Overview

```
 make up ENV=k8s
   │
   ├─ k8s-cluster   cluster settings → node list (names, IPs, sizes, groups) + checks
   ├─ fleet         create 3+ VMs → inventory → ansible-playbook k8s.yml
   │                  │
   │                  ├─ bootstrap.yml        connect, fixed IP, baseline   (all nodes)
   │                  ├─ k8s_node             containerd, kubelet/kubeadm/kubectl (all nodes)
   │                  ├─ k8s_control_plane    kubeadm init, Flannel, join command, kubeconfig
   │                  ├─ k8s_worker           kubeadm join                  (workers)
   │                  └─ readiness wait       all nodes registered + Ready, CoreDNS rolled out
   │
   └─ kubeconfig    envs/k8s/lab.kubeconfig on your machine
```

## Calling the module

`envs/k8s/main.tf`:

```hcl
module "k8s" {
  source = "../../modules/k8s-cluster"

  cluster_name      = "lab"
  worker_count      = 2
  image             = var.box_image
  first_host_number = 30
  network           = { cidr = "192.168.56.0/24", gateway = "192.168.56.1" }

  control_plane = { cpus = 2, memory_mb = 4096 }
  worker        = { cpus = 2, memory_mb = 4096 }

  kubernetes_version    = "1.37"
  ssh_private_key_file  = var.ssh_private_key_file
  admin_public_key_file = var.admin_public_key_file
}
```

Defaults you didn't set: `pod_cidr = "10.244.0.0/16"`,
`service_cidr = "10.96.0.0/12"`, `flannel_version = "v0.28.10"`,
`host_only_interface = "vboxnet0"`, `max_host_number = 99`. The full list
is in the [reference](05-reference.md#modulesk8s-cluster).

## Step 1 — from settings to nodes (`modules/k8s-cluster`)

### Names and IPs

The module computes the node list. You never write IPs by hand:

| Node | Name | IP = `cidrhost(network.cidr, …)` | Size | Ansible group |
|---|---|---|---|---|
| control plane | `lab-cp-01` | `first_host_number` → `.30` | `control_plane` | `k8s_control_plane` |
| worker 1 | `lab-worker-01` | `first_host_number + 1` → `.31` | `worker` | `k8s_workers` |
| worker 2 | `lab-worker-02` | `first_host_number + 2` → `.32` | `worker` | `k8s_workers` |
| worker N | `lab-worker-NN` | `first_host_number + N` | `worker` | `k8s_workers` |

Worker IPs depend only on the worker's number, so adding a worker never
moves an existing one.

### Checks before anything is created

| Check | Why |
|---|---|
| `worker_count >= 2` | 1 control plane + 2 workers = 3 nodes minimum, as requested. |
| control plane ≥ 2 CPUs and ≥ 2048 MiB | kubeadm's preflight check refuses fewer than 2 CPUs and about 1.7 GiB. Failing in Terraform is faster than failing 5 minutes into Ansible. |
| workers ≥ 1 CPU and ≥ 1024 MiB | Below that, a node can't run much. |
| `cluster_name` is lowercase letters, digits and `-` | Node names must be valid DNS labels in Kubernetes. |
| `kubernetes_version` looks like `1.37` | It selects an apt repository by minor version. |
| network, pod and service CIDRs don't overlap | An overlap breaks routing: a pod IP that is also a VM IP can't be routed correctly. Two CIDRs overlap if they have the same network address at the shorter of their two prefix lengths. |
| last node's host number ≤ `max_host_number` (99) and inside the subnet | Keeps nodes out of the DHCP pool (`.100`+). |

### Handing off

The module then calls `modules/fleet` with:

- `vms` = the computed nodes,
- `ansible_playbook` = `ansible/k8s.yml`,
- `ansible_vars` = the Kubernetes settings, which become `all.vars` in the
  inventory:

  | Inventory variable | From |
  |---|---|
  | `kubernetes_version` | `kubernetes_version` |
  | `k8s_pod_cidr` | `pod_cidr` |
  | `k8s_service_cidr` | `service_cidr` |
  | `k8s_flannel_version` | `flannel_version` |
  | `k8s_kubeconfig_dest` | `kubeconfig_path` (default `envs/k8s/lab.kubeconfig`) |
  | `admin_public_key_file` | `admin_public_key_file` |

The inventory goes to `envs/k8s/lab-inventory.yml`. Stages 1–5 of
[chapter 3](03-vm-lifecycle.md) now run unchanged for all three VMs: create,
boot, DHCP, inventory, connect, fixed IP, baseline. Then `k8s.yml`
continues.

## Step 2 — every node: `k8s_node`

Runs on `k8s_control_plane` and `k8s_workers`. Each task is idempotent.

### 2.1 Swap off

```sh
swapoff -a                          # only if facts show swap in use
# /etc/fstab: comment out swap lines, so it stays off after reboot
```

By default kubelet refuses to start with swap enabled. The scheduler's
memory accounting assumes memory is real RAM.

### 2.2 Kernel modules and settings

```
modprobe overlay br_netfilter            # now
/etc/modules-load.d/k8s.conf             # at boot
/etc/sysctl.d/99-k8s.conf:
  net.bridge.bridge-nf-call-iptables  = 1
  net.bridge.bridge-nf-call-ip6tables = 1
  net.ipv4.ip_forward                 = 1
```

- `overlay`: the filesystem driver containerd uses for container layers.
- `br_netfilter` + `bridge-nf-call-*`: makes traffic crossing the Linux
  bridge that pods attach to go through iptables. kube-proxy implements
  Services with iptables rules, so without this, Service traffic between
  pods on the same node bypasses them.
- `ip_forward`: the node routes packets between pods, the bridge and
  `eth0`.

### 2.3 Container runtime: containerd 2.x

```
apt install apt-transport-https ca-certificates curl gpg python3-debian
add apt source  https://download.docker.com/linux/ubuntu <release> stable   (key fetched from Docker)
apt install containerd.io
```

- **Why Docker's repository?** Kubernetes 1.36 and later need containerd
  2.x. Ubuntu 24.04's own `containerd` package is the 1.7 series.
  `containerd.io` from Docker's repo is containerd 2.x, and it's the usual
  choice for kubeadm setups. Only containerd is installed, not Docker.
- `python3-debian` is needed by Ansible's `deb822_repository` module, which
  writes modern `.sources` files and downloads the signing key itself.

**Config.** `containerd.io` ships a config that *disables* the CRI plugin,
the interface kubelet talks to. So the role replaces it:

1. `containerd config default`: print the full default config.
2. Check it contains `SystemdCgroup = false`. If a future containerd
   changes the format, the run stops with a clear message rather than
   silently doing the wrong thing.
3. Write it to `/etc/containerd/config.toml` with
   `SystemdCgroup = true`.
4. If it changed, restart containerd now (`flush_handlers`), before kubelet
   depends on it.

**Why the systemd cgroup driver?** Ubuntu runs systemd, which already
manages cgroups. If containerd managed them separately (the `cgroupfs`
driver), two managers would each have their own view of resource limits,
which becomes unstable under memory pressure. kubeadm configures kubelet
for `systemd` by default, so containerd has to match.

### 2.4 Kubernetes packages

```
add apt source  https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /   (key: .../Release.key)
apt install kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
```

- The repository is **per minor version**, so `kubernetes_version = "1.37"`
  installs the newest 1.37.x patch release.
- **Hold** stops `apt upgrade` from moving them. Upgrading a cluster is a
  deliberate, ordered process (`kubeadm upgrade`), not a side effect of
  updating packages.
- `kubelet` is the node agent, `kubeadm` bootstraps or joins the cluster,
  and `kubectl` is the CLI.

### 2.5 Pin kubelet to the fixed IP

```
/etc/default/kubelet:   KUBELET_EXTRA_ARGS=--node-ip=192.168.56.30
```

This file is read by kubelet's systemd unit. Without it, kubelet picks the
address of the interface with the default route. Here that is the fixed
IP anyway, but pinning it makes the node's advertised address explicit
and keeps it right if you add interfaces later. kubelet is enabled. It
restarts in a loop until `kubeadm init` or `join` gives it a
configuration, which is normal.

## Step 3 — control plane: `k8s_control_plane`

### 3.1 `kubeadm init`

Runs only if `/etc/kubernetes/admin.conf` doesn't exist yet, so it
happens once in the cluster's lifetime:

```sh
kubeadm init \
  --apiserver-advertise-address=192.168.56.30 \
  --apiserver-cert-extra-sans=192.168.56.30 \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --node-name=lab-cp-01
```

What kubeadm does, in order:

1. **Preflight checks**: CPUs, memory, swap, ports free, container runtime
   reachable.
2. **Certificates**: creates a cluster CA in `/etc/kubernetes/pki` and
   signs certificates for the API server (valid for `192.168.56.30`,
   hence `--apiserver-cert-extra-sans`), etcd, and the other components.
3. **kubeconfig files** for the admin, kubelet, controller-manager and
   scheduler, including `/etc/kubernetes/admin.conf`.
4. **Static pods**: writes manifests for etcd, kube-apiserver,
   kube-controller-manager and kube-scheduler into
   `/etc/kubernetes/manifests`. kubelet starts them as containers, so the
   control plane runs as pods on this node.
5. **Waits** for the API server to answer.
6. **Taints** the node `node-role.kubernetes.io/control-plane:NoSchedule`,
   so ordinary workloads go to the workers.
7. **Add-ons**: CoreDNS (cluster DNS) and kube-proxy (Service routing).
   CoreDNS stays `Pending` until a pod network exists (3.3).

`--pod-network-cidr` gives each node a slice of `10.244.0.0/16` for
its pods, a `/24` per node. `--service-cidr` is where ClusterIP Services
get their virtual IPs.

### 3.2 kubeconfig for the SSH user

Copies `admin.conf` to `/home/vagrant/.kube/config` (mode `0600`), so
`kubectl` works after `ssh vagrant@192.168.56.30`.

### 3.3 Pod network: Flannel

```sh
curl  https://github.com/flannel-io/flannel/releases/download/v0.28.10/kube-flannel.yml  > /etc/kubernetes/kube-flannel.yml
sed   '"Network": "…"'  →  '"Network": "10.244.0.0/16"'          # = pod_cidr
kubectl apply -f /etc/kubernetes/kube-flannel.yml
```

Flannel runs as a DaemonSet, one pod per node. On each node it:

- reads the node's pod subnet from Kubernetes (for example `10.244.1.0/24`),
- creates a `cni0` bridge for local pods and a `flannel.1` VXLAN
  interface,
- adds routes so that traffic for another node's pod subnet is
  encapsulated in UDP and sent to that node's IP (`192.168.56.31`, …).

The manifest's `"Network"` must equal kubeadm's `--pod-network-cidr`.
The role rewrites it, so changing `pod_cidr` keeps the two in sync. Once
Flannel is up, each node's network plugin reports ready, and CoreDNS can
start.

### 3.4 Join command

```sh
kubeadm token create --print-join-command --ttl 1h
# → kubeadm join 192.168.56.30:6443 --token abcdef.0123456789abcdef \
#     --discovery-token-ca-cert-hash sha256:…
```

This runs on every playbook run. A fresh token costs nothing, and tokens
expire after an hour. The output is saved as a host fact
(`k8s_join_command`) for the workers to read. It contains:

- the API server address,
- a **bootstrap token**, so the new node can authenticate the first time,
- the **CA certificate hash**, so the new node can check it's talking to
  the real API server before trusting it.

### 3.5 Kubeconfig on your machine

`fetch` copies `/etc/kubernetes/admin.conf` to `k8s_kubeconfig_dest`
(`envs/k8s/lab.kubeconfig`), and a local task sets it to `0600`. It points
at `https://192.168.56.30:6443`, which your machine can reach directly
over `vboxnet0`.

> This is a **cluster-admin** credential. It's git-ignored, and it's deleted
> on `terraform destroy`.

## Step 4 — workers: `k8s_worker`

Runs only if `/etc/kubernetes/kubelet.conf` doesn't exist yet, meaning the
node never joined:

```sh
kubeadm join 192.168.56.30:6443 --token … --discovery-token-ca-cert-hash sha256:… --node-name=lab-worker-01
```

What happens:

1. **Discovery**: the worker downloads the cluster CA from the API server
   and checks it against the hash. Only then does it trust the server.
2. **TLS bootstrap**: using the token, kubelet asks for a client
   certificate. The control plane approves and signs it automatically.
3. kubelet writes `/etc/kubernetes/kubelet.conf` and starts as a
   cluster member. The node registers as `lab-worker-01`.
4. Flannel's DaemonSet schedules a pod on the new node, which sets up its
   pod network. kube-proxy's DaemonSet does the same for Service routing.

Workers that already joined skip this. That's why re-runs and scale-ups
are safe.

## Step 5 — readiness wait

The last play in `k8s.yml` runs on the control plane, and `make up` only
returns when it passes:

| Wait | Command | Up to |
|---|---|---|
| Every node registered | `kubectl get nodes -o name` until the count equals control plane + workers | 60 × 5 s = 5 min |
| Every node `Ready` | `kubectl wait --for=condition=Ready nodes --all` | 10 min |
| Cluster DNS running | `kubectl -n kube-system rollout status deployment/coredns` | 5 min |

`Ready` means kubelet is healthy and the node's pod network is up. CoreDNS
rolled out means pods can be scheduled, get IPs and talk across the
cluster, and cluster DNS works. If any wait times out, the playbook fails,
so `terraform apply` fails too, instead of reporting success on a
half-built cluster.

## Step 6 — use it

```sh
export KUBECONFIG=$PWD/envs/k8s/lab.kubeconfig
kubectl get nodes -o wide
# NAME            STATUS   ROLES           VERSION   INTERNAL-IP
# lab-cp-01       Ready    control-plane   v1.37.x   192.168.56.30
# lab-worker-01   Ready    <none>          v1.37.x   192.168.56.31
# lab-worker-02   Ready    <none>          v1.37.x   192.168.56.32
```

A quick smoke test:

```sh
kubectl create deployment hello --image=nginx --replicas=2
kubectl expose deployment hello --port=80 --type=NodePort
kubectl get svc hello                       # note the 3xxxx NodePort
curl http://192.168.56.31:<nodeport>        # any node IP works
```

## The cluster's networks

Three address ranges are in play. They must not overlap:

```
192.168.56.0/24  VM network     node IPs; real interfaces on vboxnet0; routed out via the host NAT
10.244.0.0/16    pod network    one /24 per node (10.244.0.0/24, 10.244.1.0/24, …); Flannel VXLAN between nodes
10.96.0.0/12     service network virtual ClusterIPs; exist only as kube-proxy iptables rules
```

How traffic moves:

- **Pod → pod, same node:** through the node's `cni0` bridge.
- **Pod → pod, different node:** `cni0` → `flannel.1` (VXLAN) →
  encapsulated in UDP to the other node's `192.168.56.x` → unwrapped →
  that node's `cni0` → pod.
- **Pod → Service:** kube-proxy's iptables rules rewrite the ClusterIP
  to one of the backing pod IPs, then as above.
- **Pod → internet:** source-NAT to the node's IP (Flannel's masquerade
  rule), then the node's default route to the host (`192.168.56.1`), then
  the host's NAT to whatever uplink it's on. Two NATs in a row, both
  automatic.
- **Your machine → cluster:** directly to node IPs. The API server on
  `.30:6443` and NodePorts on any node's IP.

## Scaling and changes

| Change | What happens |
|---|---|
| `worker_count` 2 → 3 | Terraform creates `lab-worker-03` (`.33`). Ansible re-runs everywhere. Existing nodes report `ok`, and the new one installs and joins. `make up` returns once all 4 nodes are `Ready`. |
| `worker_count` 3 → 2 | Terraform destroys `lab-worker-03`, the highest-numbered worker. **First** run `kubectl drain lab-worker-03 --ignore-daemonsets --delete-emptydir-data` and `kubectl delete node lab-worker-03`. Otherwise the node object stays behind as `NotReady`. |
| `worker` / `control_plane` size | Every VM of that kind is **replaced**. For workers, that means wiping and rejoining them. For the control plane, it means **losing the cluster** (etcd lives on that VM): `make down ENV=k8s && make up ENV=k8s`. |
| `kubernetes_version` | Only affects newly installed nodes; packages are held. Upgrading a running cluster is a `kubeadm upgrade` procedure, which isn't automated here. Mixing versions isn't supported. For a lab, rebuild instead. |
| `pod_cidr`, `service_cidr`, `first_host_number` | Need a rebuild: these are fixed at `kubeadm init`. |

## `make down ENV=k8s`

Destroys all node VMs, the inventory, and the fetched kubeconfig. That's
the job of `terraform_data.kubeconfig`, whose destroy-time provisioner runs
`rm -f` on the file. The cluster has no other state outside the VMs.

## Limits

- **Single control plane.** If `lab-cp-01` is lost, the cluster is lost.
  High availability would need ≥ 3 control planes behind a virtual IP,
  for example with kube-vip, and `--control-plane-endpoint` pointing at it.
- **Ubuntu guests only** (netplan, apt).
- **Nodes need internet during provisioning** for packages, the Flannel
  manifest and container images. That goes through the host NAT, so the
  host must be online for `make up`.
- **No storage provisioner or ingress controller** is installed.
  PersistentVolumeClaims stay `Pending` until you add one, for example
  local-path-provisioner.
