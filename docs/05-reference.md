# 5. Reference

## Contents

- [Module inputs and outputs](#module-inputs-and-outputs): `vm`, `fleet`, `k8s-cluster`
- [Object-typed inputs, field by field](#object-typed-inputs-field-by-field)
- [Environment variables (`envs/dev`)](#environment-variables-envsdev)
- [Ansible variables](#ansible-variables)
- [Files this project creates](#files-this-project-creates)
- [Make targets](#make-targets)
- [Versions](#versions)

## Module inputs and outputs

These tables are generated from each module's `variables.tf` and
`outputs.tf`. Where they disagree with the code, the code is right. Inputs
with an object type are described field by field in the
[next section](#object-typed-inputs-field-by-field).

### `modules/vm`

#### Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | **required** | VM name. When instance_count &gt; 1, each VM is named "&lt;name&gt;-01", "&lt;name&gt;-02", ... |
| `instance_count` | `number` | `1` | Number of identical VMs to create. |
| `image` | `string` | **required** | Vagrant box (VirtualBox provider) to build the VM from: a local path to a .box file or an http(s) URL. |
| `image_checksum` | `string` | `null` | Optional checksum of the image, verified before use. |
| `image_checksum_type` | `string` | `null` | Hash algorithm of image_checksum (e.g. "sha256", "md5"). Required when image_checksum is set. |
| `cpus` | `number` | `2` | Number of virtual CPUs. |
| `memory_mb` | `number` | `2048` | Memory in MiB. |
| `network_adapters` | list(…) — see `variables.tf` | `[{"type": "nat"}]` | Network adapters, in slot order (adapter 1 first, max 8). - type: "nat", "bridged" or "hostonly". - host_interface: host NIC for "bridged" (e.g. "enp11s0") or host-only network for "hostonly" (e.g. "vboxnet0"). - device: emulated NIC: "IntelPro1000MTServer" (default), "IntelPro1000MTDesktop", "IntelPro1000TServer", "FASTIII" or "VirtIO". |
| `primary_adapter_index` | `number` | `null` | Zero-based index into network_adapters whose IPv4 address is reported as primary_ipv4_addresses. Defaults to the first non-NAT adapter (NAT adapters always report the unreachable 10.0.2.15), or 0 if all are NAT. |
| `boot_order` | `list(string)` | `null` | Boot device order, up to 4 of "none", "floppy", "dvd", "disk", "net". Null keeps the image's default. |
| `optical_disks` | `list(string)` | `[]` | Paths to ISO images to attach as optical drives. |
| `user_data` | `string` | `null` | Passed as-is to the provider's user_data attribute. |
| `status` | `string` | `running` | Desired power state: "running" or "poweroff". |

#### Outputs

| Name | Description |
|---|---|
| `names` | Names of the created VMs, in order. |
| `ids` | VirtualBox UUID of each VM, keyed by name. |
| `primary_ipv4_addresses` | IPv4 address of the primary adapter (see primary_adapter_index) of each VM, keyed by name. Reported by the guest, so the box needs VirtualBox Guest Additions. |
| `ipv4_addresses` | IPv4 address of every adapter of each VM (in slot order), keyed by name. |
| `mac_addresses` | MAC address of every adapter of each VM (in slot order), keyed by name. |
| `primary_mac_addresses` | MAC address of the primary adapter of each VM (lowercase, colon-separated, as the guest OS shows it), keyed by name. |

### `modules/fleet`

#### Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `network` | object(…) — see `variables.tf` | **required** | The network the VMs' fixed IPs live on — normally a host-only network whose gateway is the host itself (see scripts/host-nat.sh). - cidr: e.g. "192.168.56.0/24". - gateway: default route for the VMs, e.g. "192.168.56.1" (the host). - dns_servers: resolvers the VMs use. |
| `vms` | map(…) — see `variables.tf` | **required** | VMs to create, keyed by VM name (also used as the Ansible inventory hostname). - ip: Fixed IPv4 address inside network.cidr. Ansible configures it in the guest. - image: Vagrant box path/URL. Defaults to var.default_image. - cpus, memory_mb: Sizing. - network_adapters: Defaults to var.default_network_adapters. See modules/vm for the schema. - groups: Ansible groups the VM joins (e.g. ["web"]). - packages: Extra OS packages Ansible installs on this VM (host var "extra_packages"). - host_vars: Any other Ansible host vars, as strings. - status: "running" or "poweroff". |
| `default_image` | `string` | `null` | Vagrant box path/URL used by VMs that don't set image. |
| `default_network_adapters` | list(…) — see `variables.tf` | `[{"type": "hostonly", "host_interface": "vboxnet0"}]` | Network adapters for VMs that don't set network_adapters. The fixed IP goes on the primary adapter (first non-NAT one). |
| `inventory_path` | `string` | `null` | Where to write the generated Ansible inventory (YAML). Null skips writing it. |
| `ansible_user` | `string` | `vagrant` | SSH user Ansible connects as. Vagrant boxes ship with "vagrant". |
| `ansible_ssh_private_key_file` | `string` | `null` | Private key Ansible uses to log in as ansible_user. |
| `ansible_vars` | `map(string)` | `{}` | Extra variables placed under all.vars in the inventory. |
| `ansible_playbook` | `string` | `null` | Playbook to run against the VMs once they're up (absolute path; its directory must hold ansible.cfg). Null skips running Ansible. Needs inventory_path. |

#### Outputs

| Name | Description |
|---|---|
| `ids` | VirtualBox UUID of each VM, keyed by name. |
| `ip_addresses` | Fixed IPv4 address of each VM, keyed by name. |
| `reported_ip_addresses` | IPv4 address each VM's primary adapter last reported through Guest Additions (its DHCP address until the fixed IP is applied). |
| `inventory` | The generated Ansible inventory, as YAML. |
| `inventory_path` | Path of the written inventory file, or null if none was written. |
| `ansible_run_id` | Changes every time the playbook runs; null when ansible_playbook is unset. Depend on it to wait for provisioning. |

### `modules/k8s-cluster`

#### Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `cluster_name` | `string` | **required** | Cluster name; prefixes every VM ("&lt;name&gt;-cp-01", "&lt;name&gt;-worker-01", ...). Lowercase letters, digits and '-'. |
| `image` | `string` | **required** | Ubuntu Vagrant box (VirtualBox provider, with Guest Additions): a local .box path or an http(s) URL. |
| `network` | object(…) — see `variables.tf` | **required** | Host-only network the nodes live on, with the host as gateway. See modules/fleet. |
| `host_only_interface` | `string` | `vboxnet0` | VirtualBox host-only network the nodes attach to. |
| `first_host_number` | `number` | `10` | Host number (in network.cidr) of the control plane. Workers take the following numbers: with 192.168.56.0/24 and 30, the control plane is .30 and workers .31, .32, ... |
| `max_host_number` | `number` | `99` | Highest host number a node may use. Keeps nodes below the DHCP range (.100-.199 from scripts/vbox-network.sh). |
| `worker_count` | `number` | `2` | Number of worker nodes. With the single control plane, the cluster has worker_count + 1 nodes. |
| `control_plane` | object(…) — see `variables.tf` | `{}` | Control plane VM size. kubeadm needs at least 2 CPUs and ~1.7 GiB. |
| `worker` | object(…) — see `variables.tf` | `{}` | Size of each worker VM. |
| `kubernetes_version` | `string` | `1.37` | Kubernetes minor version ("1.37"). The latest patch release of it is installed and held. |
| `pod_cidr` | `string` | `10.244.0.0/16` | Pod network. Must not overlap network.cidr or service_cidr. |
| `service_cidr` | `string` | `10.96.0.0/12` | Service (ClusterIP) network. Must not overlap network.cidr or pod_cidr. |
| `flannel_version` | `string` | `v0.28.10` | Flannel (CNI) release tag. |
| `kubeconfig_path` | `string` | `null` | Where to write the cluster's admin kubeconfig. Defaults to &lt;root module&gt;/&lt;cluster_name&gt;.kubeconfig. |
| `inventory_path` | `string` | `null` | Where to write the Ansible inventory. Defaults to &lt;root module&gt;/&lt;cluster_name&gt;-inventory.yml. |
| `ssh_user` | `string` | `vagrant` | User baked into the box that Ansible logs in as. |
| `ssh_private_key_file` | `string` | **required** | Private key that can log in as ssh_user on a fresh box. |
| `admin_public_key_file` | `string` | `null` | Your public key; authorized for ssh_user on every node. Null skips it. |

#### Outputs

| Name | Description |
|---|---|
| `kubeconfig_path` | Admin kubeconfig for the cluster. Written once provisioning finishes: `export KUBECONFIG=&lt;this&gt;`. |
| `api_server_endpoint` | Kubernetes API server URL. |
| `control_plane` | Control plane node name and IP. |
| `workers` | Worker node names and IPs. |
| `ssh_commands` | SSH command for each node. |
| `inventory_path` | Generated Ansible inventory for the cluster. |

## Object-typed inputs, field by field

### `network_adapters` (`vm`), `default_network_adapters` (`fleet`), `vms[*].network_adapters` (`fleet`)

A list, one entry per adapter, in slot order (max 8):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `type` | string | required | `"nat"`, `"bridged"` or `"hostonly"` |
| `host_interface` | string | `null` | Required for `bridged` (a host NIC, e.g. `"enp11s0"`) and `hostonly` (e.g. `"vboxnet0"`) |
| `device` | string | `"IntelPro1000MTServer"` | Emulated NIC: `IntelPro1000MTServer`, `IntelPro1000MTDesktop`, `IntelPro1000TServer`, `FASTIII`, `VirtIO` |

Defaults differ by module. `vm` defaults to one NAT adapter, which suits
a VM used on its own. `fleet` and `k8s-cluster` default to one host-only
adapter on `vboxnet0`, which the fixed-IP design needs. The fixed IP is
always applied to the **primary** adapter: the first one that isn't NAT.

### `network` (`fleet`, `k8s-cluster`)

| Field | Type | Default | Meaning |
|---|---|---|---|
| `cidr` | string | required | Subnet the fixed IPs live in, e.g. `"192.168.56.0/24"` |
| `gateway` | string | required | Default route for the VMs, normally the host: `"192.168.56.1"` |
| `dns_servers` | list(string) | `["1.1.1.1", "8.8.8.8"]` | Resolvers written into each VM's netplan config |

### `vms` (`fleet`)

A map keyed by VM name:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `ip` | string | required | Fixed IPv4 inside `network.cidr`; unique; not the gateway |
| `image` | string | `default_image` | Vagrant box path or URL |
| `cpus` | number | `2` | Virtual CPUs |
| `memory_mb` | number | `2048` | Memory in MiB |
| `network_adapters` | list(object) | `default_network_adapters` | See above |
| `groups` | list(string) | `[]` | Ansible groups; letters, digits and `_` only |
| `packages` | list(string) | `[]` | Extra apt packages → host var `extra_packages` |
| `host_vars` | map(string) | `{}` | Any other Ansible host variables |
| `status` | string | `"running"` | `"running"` or `"poweroff"` |

### `control_plane`, `worker` (`k8s-cluster`)

| Field | Type | Default | Minimum |
|---|---|---|---|
| `cpus` | number | `2` | control plane 2, worker 1 |
| `memory_mb` | number | `4096` | control plane 2048, worker 1024 |

## Environment variables (`envs/dev`)

Set in `envs/dev/terraform.tfvars`:

| Variable | Default | Meaning |
|---|---|---|
| `vms` | required | As `fleet`'s `vms` above |
| `box_image` | required | Default box for every VM |
| `ssh_private_key_file` | required | Key a fresh box accepts (Vagrant's insecure key) |
| `admin_public_key_file` | `"~/.ssh/id_ed25519.pub"` | Your key, authorized on every VM |
| `ssh_user` | `"vagrant"` | Login user baked into the box |
| `host_only_interface` | `"vboxnet0"` | Host-only network to attach to |
| `network_cidr` | `"192.168.56.0/24"` | VM subnet |
| `gateway_ip` | `"192.168.56.1"` | The host's address on it |
| `dns_servers` | `["1.1.1.1", "8.8.8.8"]` | VM resolvers |
| `run_ansible` | `true` | Run `site.yml` automatically |
| `ip_wait_delay_seconds` | `30` | Provider: wait before the first IP check |
| `ip_wait_min_timeout_seconds` | `5` | Provider: interval between IP checks (overall limit fixed at 5 min) |

`envs/k8s` has three: `box_image`, `ssh_private_key_file`,
`admin_public_key_file`. The cluster's shape is set in its `main.tf`.

## Ansible variables

Most of these come from the Terraform-generated inventory. You can
override the defaults in `ansible/group_vars/<group>.yml`, or per VM with
`host_vars`.

| Variable | Set by | Default | Used by |
|---|---|---|---|
| `ansible_host` | inventory (provider's DHCP IP), then `static_ip` at runtime | — | connection |
| `ansible_user`, `ansible_ssh_private_key_file` | inventory | — | connection |
| `static_ip`, `static_mac` | inventory | — | `static_network` |
| `static_network_prefix`, `static_network_gateway`, `static_network_dns_servers` | inventory | — | `static_network` |
| `timezone` | `group_vars/all.yml`; per VM via `host_vars` | `UTC` | `common` |
| `base_packages` | `group_vars/all.yml` | curl, vim, git, ca-certificates | `common` |
| `extra_packages` | inventory (`packages`) | `[]` | `common` |
| `upgrade_packages` | you | `false` | `common` |
| `admin_public_key_file` | inventory | `""` (skip) | `common` |
| `webserver_index_html` | you | a page naming the host | `webserver` |
| `kubernetes_version` | inventory | `"1.37"` | `k8s_node` |
| `k8s_pod_cidr`, `k8s_service_cidr` | inventory | `10.244.0.0/16`, `10.96.0.0/12` | `k8s_control_plane` |
| `k8s_flannel_version` | inventory | `v0.28.10` | `k8s_control_plane` |
| `k8s_kubeconfig_dest` | inventory | `""` (don't fetch) | `k8s_control_plane` |
| `k8s_join_command` | set at runtime on the control plane | — | `k8s_worker` |

## Files this project creates

| Path | Created by | Contents | In git? |
|---|---|---|---|
| `envs/<env>/terraform.tfstate` | Terraform | What exists: VM UUIDs, IPs, MACs | no |
| `envs/<env>/.terraform.lock.hcl` | `terraform init` | Exact provider versions and checksums | **yes** (commit it) |
| `envs/dev/inventory.yml` | `fleet` | Ansible inventory | no |
| `envs/k8s/<cluster>-inventory.yml` | `k8s-cluster` → `fleet` | Ansible inventory | no |
| `envs/k8s/<cluster>.kubeconfig` | Ansible `fetch` | **cluster-admin** credentials | no |
| `~/.terraform/virtualbox/gold/<box>/` | provider | Unpacked box (shared by all VMs) | — |
| `~/.terraform/virtualbox/machine/<vm>/` | provider | VM definition and disk | — |
| `/usr/local/sbin/vbox-nat` | `host-nat.sh install` | Copy of the NAT script | — |
| `/etc/systemd/system/vbox-nat.service` | `host-nat.sh install` | Re-applies NAT at boot | — |
| `/etc/sysctl.d/90-vbox-nat.conf` | `host-nat.sh install` | `net.ipv4.ip_forward = 1` | — |
| guest `/etc/netplan/99-static.yaml` | `static_network` | Fixed IP, gateway, DNS | — |
| guest `/etc/ssh/sshd_config.d/10-no-password.conf` | `common` | Disables password login | — |

## Make targets

`ENV` selects the environment (`dev` by default, `k8s` for the cluster).

| Target | Runs |
|---|---|
| `make host-setup` | `scripts/vbox-network.sh`, then `sudo scripts/host-nat.sh install` |
| `make init` | `terraform init` in `envs/$ENV`, then `ansible-galaxy collection install -r ansible/requirements.yml` |
| `make plan` | `terraform plan` |
| `make up` | `terraform apply` (creates/updates VMs, runs Ansible) |
| `make down` | `terraform destroy` |
| `make provision` | `ansible-playbook` only: `site.yml` + `envs/dev/inventory.yml`, or for `ENV=k8s` `k8s.yml` + `envs/k8s/lab-inventory.yml` |
| `make test` | `terraform test` in all three modules (mocked provider; no VirtualBox needed) |
| `make lint` | `terraform fmt -check`, `terraform validate`, `ansible-lint` |
| `make fmt` | `terraform fmt -recursive` |

## Versions

| Component | Pinned to | Where |
|---|---|---|
| Terraform | `>= 1.9` | `versions.tf` (`fleet`, `k8s-cluster`, envs); `vm` allows `>= 1.5` |
| VirtualBox provider | `shekeriev/virtualbox ~> 0.0.4` | every `versions.tf` |
| local provider | `hashicorp/local ~> 2.5` | `fleet`, `k8s-cluster`, envs |
| Kubernetes | `1.37` (latest patch) | `kubernetes_version` |
| containerd | latest `containerd.io` from Docker's repo (2.x) | `k8s_node` |
| Flannel | `v0.28.10` | `flannel_version` |
| Ansible collections | latest `community.general`, `ansible.posix` | `ansible/requirements.yml` |
