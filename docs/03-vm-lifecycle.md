# 3. VM lifecycle: from `make up` to a provisioned VM

This chapter follows one `make up` (`envs/dev`) from start to finish, then
covers what later runs, changes and `make down` do. The Kubernetes
cluster uses exactly the same path, with extra Ansible stages on top
([chapter 4](04-kubernetes.md)).

## Overview

```
 make up
   │
   ├─ Stage 1  terraform plan       validate inputs, decide what changes
   ├─ Stage 2  virtualbox_vm        unpack box → create VM → boot → wait for DHCP IP
   ├─ Stage 3  local_file           write inventory.yml (DHCP IP + fixed IP + vars)
   └─ Stage 4+ terraform_data       ansible-playbook site.yml
                 ├─ connect         reach VM on fixed IP if up, else DHCP IP
                 ├─ static_network  netplan → fixed IP, reconnect
                 ├─ common          hostname, timezone, packages, SSH key, sshd
                 └─ group roles     e.g. webserver on group "web"
```

## Stage 0 — your input

`envs/dev/terraform.tfvars`:

```hcl
box_image            = "~/boxes/ubuntu-24.04.box"
ssh_private_key_file = "~/.ssh/vagrant_insecure"

vms = {
  web-01 = { ip = "192.168.56.11", cpus = 2, memory_mb = 2048, groups = ["web"], packages = ["htop"] }
  db-01  = { ip = "192.168.56.21", memory_mb = 4096, groups = ["db"], host_vars = { timezone = "Asia/Dhaka" } }
}
```

Each key (`web-01`) is the VM name, the VirtualBox VM name, the guest
hostname, and the Ansible inventory hostname. Everything except `ip` has a
default (2 CPUs, 2048 MiB, no groups, no extra packages).

`envs/dev/main.tf` passes this to `modules/fleet` along with the
environment-wide settings: the one host-only adapter on `vboxnet0`, the
network (`192.168.56.0/24`, gateway `.1`, DNS), SSH user and key, and
which playbook to run (`ansible/site.yml`).

## Stage 1 — plan and validation

`terraform apply` first builds a plan. Before anything is created, the
modules' validations run. Any failure stops the run with a clear message:

| Check | Where | Example failure |
|---|---|---|
| `ip` is a valid address inside `network.cidr` | `fleet` `var.vms` | `10.0.0.5` with `192.168.56.0/24` |
| No two VMs share an `ip` | `fleet` | two VMs on `.11` |
| No VM uses the gateway address | `fleet` | a VM on `.1` |
| Group names are valid Ansible group names | `fleet` | `web-servers` (has a `-`) |
| VM name characters, CPU and memory are sane | `vm` | `memory_mb = 64` |
| Adapter types and devices are known; host-only/bridged adapters name an interface | `vm` | `{ type = "hostonly" }` without `host_interface` |
| `status` is `running` or `poweroff` | `vm` | `status = "paused"` |

Fixed IPs that fall in the DHCP range aren't checked for `envs/dev`. Keep
them in `.10`–`.99` ([chapter 2](02-host-setup.md#step-3--dhcp-for-first-boot)).

## Stage 2 — creating the VM (provider)

For each entry in `vms`, `modules/fleet` calls `modules/vm`, which declares
one `virtualbox_vm` resource. Terraform creates them in parallel (up to 10
at a time by default), although the provider unpacks and clones disks one
at a time. For each VM, the provider:

1. **Gets the box.** If `image` is an `http(s)` URL, it downloads it. A
   local path is used as-is. `modules/vm` expands `~` first, because the
   provider doesn't.
2. **Unpacks it once** into `~/.terraform/virtualbox/gold/<box file name>/`.
   If that folder already exists and isn't empty, this step is skipped, so
   later VMs from the same box start much faster.
3. **Creates the VM** in `~/.terraform/virtualbox/machine/<vm name>/` and
   **clones the box's disk** into it. Every VM gets its own copy.
4. **Sets the hardware:** CPUs, memory (`memory_mb` becomes `"2048 mib"`),
   OS type `Linux_64`, hardware virtualization flags, and the network
   adapters. Here that's a single host-only adapter on `vboxnet0` with an
   Intel PRO/1000 MT Server NIC. VirtualBox generates a random MAC address.
5. **Boots the VM.**
6. **Waits for an IP.** It waits `delay` seconds (30), then every
   `mintimeout` seconds (5) reads what Guest Additions inside the VM
   reports for each adapter: MAC, status and IPv4 address. It's done when
   the **first non-NAT adapter** has an IPv4 address. Inside the guest,
   Ubuntu brings up its first network card with DHCP, and VirtualBox's
   DHCP server on `vboxnet0` hands out an address from `.100`–`.199`.
   The provider gives up after 5 minutes in total.
7. **Records** the VM's UUID (`id`) and each adapter's `mac_address` and
   `ipv4_address` in Terraform state.

At this point the VM is running, has a temporary DHCP address, and is
reachable from the host on it. It can't reach the internet yet: VirtualBox's
host-only DHCP doesn't hand out a default route.

`modules/vm` then exposes, per VM:

- `primary_ipv4_addresses`: the DHCP address of the primary adapter, which
  is the first non-NAT one, here the only one.
- `primary_mac_addresses`: its MAC, converted from VirtualBox's
  `080027ABCDEF` to the guest's `08:00:27:ab:cd:ef` format. Ansible
  needs that format to find the right interface.

## Stage 3 — the Ansible inventory

`modules/fleet` writes `envs/dev/inventory.yml`. This file is the hand-off
from Terraform to Ansible: everything Ansible knows about the VMs comes from
here. For the example above (lists and groups compacted; Terraform writes
them in block style):

```yaml
# Generated by Terraform (modules/fleet). Do not edit.
"all":
  "vars":
    "ansible_user": "vagrant"
    "ansible_ssh_private_key_file": "/home/you/.ssh/vagrant_insecure"
    "ansible_ssh_common_args": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    "static_network_prefix": 24
    "static_network_gateway": "192.168.56.1"
    "static_network_dns_servers": ["1.1.1.1", "8.8.8.8"]
    "admin_public_key_file": "/home/you/.ssh/id_ed25519.pub"
  "hosts":
    "web-01":
      "ansible_host": "192.168.56.104"      # DHCP address the provider saw
      "static_ip": "192.168.56.11"          # the fixed IP you asked for
      "static_mac": "08:00:27:3a:91:0c"     # identifies the interface in the guest
      "extra_packages": ["htop"]
    "db-01":
      "ansible_host": "192.168.56.105"
      "static_ip": "192.168.56.21"
      "static_mac": "08:00:27:5e:22:b7"
      "extra_packages": []
      "timezone": "Asia/Dhaka"              # from host_vars
  "children":
    "web": { "hosts": { "web-01": {} } }
    "db":  { "hosts": { "db-01": {} } }
```

Where each value comes from:

| Inventory value | Source |
|---|---|
| `all.vars.ansible_user`, `ansible_ssh_private_key_file` | `ssh_user`, `ssh_private_key_file` |
| `ansible_ssh_common_args` | Fixed. VMs are recreated with new SSH host keys, so host-key pinning is turned off. Acceptable only because the network is private to your machine. |
| `static_network_*` | `network_cidr` (its prefix length), `gateway_ip`, `dns_servers` |
| other `all.vars` | `ansible_vars` from the environment or cluster module |
| `hosts.<name>.ansible_host` | IP the provider read in stage 2 |
| `static_ip` | your `ip` |
| `static_mac` | MAC from stage 2 |
| `extra_packages` | your `packages` |
| any other host var | your `host_vars` |
| `children` | your `groups` |

## Stage 4 — running Ansible

`modules/fleet` holds a `terraform_data.ansible` resource with a
`local-exec` provisioner. When that resource is created or replaced,
Terraform runs on your machine:

```sh
cd ansible
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i envs/dev/inventory.yml ansible/site.yml
```

If the playbook fails, `terraform apply` fails too. The resource is then
recorded as failed, and the next `make up` runs the playbook again.

`ansible.cfg` sets `host_key_checking = False`, SSH pipelining (fewer
round-trips), `forks = 10` (10 VMs in parallel), and YAML-formatted
output.

`site.yml` = `bootstrap.yml` + the `webserver` play. `bootstrap.yml` has
two plays:

### Play 1 — connect to each VM

Runs with `gather_facts: false`, since there may be no working connection
yet:

1. **Check whether the fixed IP already answers.** From your machine
   (`delegate_to: localhost`), it tries TCP port 22 on `static_ip` for up to
   5 seconds. It never fails, it just records the result.
2. **If it answered, switch to it** (`set_fact: ansible_host: static_ip`).
   This matters on every run after the first: the VM no longer has its
   DHCP address, and `inventory.yml` may still list it.
3. **Wait until SSH answers** on whichever address was chosen, for up to
   5 minutes. This covers VMs that are still booting.

### Play 2 — baseline: roles `static_network` then `common`

Runs with `become: true` (root via sudo; the `vagrant` user has
password-less sudo). Facts are gathered here, including every
interface's MAC address.

#### Stage 4 — fixed IP (`static_network`)

1. **Require netplan.** If `/usr/sbin/netplan` is missing, the run stops
   with a clear message. Only netplan guests (Ubuntu) are supported.
2. **Find the interface by MAC.** It searches the gathered facts for the
   interface whose `macaddress` equals `static_mac`. With one adapter
   that's simply the only interface. Matching by MAC is still correct
   whatever the guest calls it (`eth0`, `enp0s3`, …).
3. **Stop cloud-init from rewriting the network** on reboot, by writing
   `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`.
4. **Write `/etc/netplan/99-static.yaml`** (mode `0600`; netplan warns
   about anything more open):
   ```yaml
   network:
     version: 2
     ethernets:
       eth0:
         dhcp4: false
         dhcp6: false
         addresses: [192.168.56.11/24]
         routes:
           - to: default
             via: 192.168.56.1          # the host
         nameservers:
           addresses: ["1.1.1.1", "8.8.8.8"]
   ```
   netplan reads `/etc/netplan/*.yaml` in name order, and later files
   override earlier ones. The box's own file (typically
   `01-netcfg.yaml`, `eth0: dhcp4: true`) is overridden by `99-static.yaml`
   without being edited.
5. **If that file changed, switch over.** These are handlers, flushed
   immediately with `meta: flush_handlers` so that later roles already
   have internet:
   1. `sleep 2 && netplan apply`, started **in the background**
      (`async: 60, poll: 0`). Applying the config removes the DHCP address
      that Ansible is connected through. Run in the foreground, the SSH
      session would die mid-task and the task would hang. In the
      background, Ansible gets its answer first and the change happens
      two seconds later.
   2. `set_fact: ansible_host: static_ip`: all following tasks connect to
      the fixed IP.
   3. `wait_for_connection` (5 s delay, up to 2 min): reconnect on the
      fixed IP.

If the file is unchanged (any run after the first), nothing is applied and
there's no reconnect.

From here on, the VM has its fixed IP, a default route via the host, and
DNS. With the [host NAT](02-host-setup.md#23-the-host-as-nat-gateway-scriptshost-natsh)
in place, it has internet access.

#### Stage 5 — baseline (`common`)

| Task | What it does | Controlled by |
|---|---|---|
| Set hostname | `hostnamectl` → the inventory name (`web-01`) | VM name |
| Map hostname to loopback | `/etc/hosts`: `127.0.1.1 web-01`, so `sudo` and other tools can resolve the name | VM name |
| Set timezone | `timedatectl` | `timezone` (default `UTC` from `group_vars/all.yml`; per VM via `host_vars`) |
| Install packages | apt, with a cache update, installs `base_packages + extra_packages` | `base_packages` (curl, vim, git, ca-certificates); `packages` per VM |
| Upgrade all packages | `apt upgrade`, only if enabled | `upgrade_packages` (default `false`) |
| Authorize your SSH key | adds `admin_public_key_file` to `~vagrant/.ssh/authorized_keys` | `admin_public_key_file` |
| Disable SSH password login | `/etc/ssh/sshd_config.d/10-no-password.conf`; restarts `ssh` if changed | — |

After this you can `ssh vagrant@192.168.56.11` with your own key.

### Play 3+ — group roles

`site.yml` then runs `webserver` on group `web`: installs nginx, writes an
index page naming the host, and enables and starts nginx. Here that
applies to `web-01`, so `curl http://192.168.56.11` from the host returns
its page. `db-01` isn't in `web`, so the play skips it.

That's how you add your own configuration: a role per job, a play per
group, and the group listed on the VM ([chapter 6](06-operations.md#add-your-own-configuration)).

## Stage 6 — done

`terraform apply` finishes and prints the outputs:

```
ip_addresses   = { "db-01" = "192.168.56.21", "web-01" = "192.168.56.11" }
inventory_path = "/home/you/.../envs/dev/inventory.yml"
ssh_commands   = { "db-01" = "ssh vagrant@192.168.56.21", "web-01" = "ssh vagrant@192.168.56.11" }
```

## When does Ansible run again?

`terraform_data.ansible` is **replaced**, which re-runs the playbook,
whenever any of its `triggers_replace` values changes:

| Trigger | Changes when |
|---|---|
| `vm_ids` | any VM is created, replaced or removed (its VirtualBox UUID set changes) |
| `settings` | anything in `vms`, the network, or `ansible_vars` changes, e.g. a new package or group |
| `playbooks` | any file under `ansible/` changes, whether a role, a template or `group_vars` |

It deliberately does **not** watch `inventory.yml`. After the first run, the
provider sees the fixed IP instead of the DHCP address, so the inventory
changes once on its own. Watching it would trigger a pointless second
run.

Every run covers **all** VMs, not only the changed one. That's safe
because every task is idempotent: something already in place reports `ok`
and is left alone.

To force a run without changing anything:

```sh
make provision                                    # Ansible only, Terraform untouched
terraform -chdir=envs/dev apply -replace='module.fleet.terraform_data.ansible[0]'
```

## Changes and what they cost

| You change | Terraform does | Effect |
|---|---|---|
| Add a VM entry | creates 1 VM, then Ansible runs | others untouched (tasks report `ok`) |
| Remove a VM entry | destroys that VM | its disk is deleted |
| `cpus`, `memory_mb`, adapters, `image` | **replaces** the VM (destroy + create) | the provider can't edit VMs in place; anything stored on the VM is lost |
| `ip` | updates inventory, Ansible re-runs | netplan file changes → VM moves to the new IP |
| `packages`, `groups`, `host_vars` | Ansible re-runs | packages added (removing one from the list does **not** uninstall it) |
| A file under `ansible/` | Ansible re-runs | — |
| `status = "poweroff"` | powers the VM off | disk is kept |

Always read `terraform plan` (`make plan`) first. A line saying
`must be replaced` means the VM will be destroyed and rebuilt.

## `make down`

`terraform destroy` removes, in reverse dependency order:

1. `terraform_data.ansible`: nothing to undo, it only ran a command.
2. `local_file.inventory`: deletes `inventory.yml`.
3. Each `virtualbox_vm`: powers the VM off, then unregisters and deletes
   it, including its cloned disk under `~/.terraform/virtualbox/machine/`.

What stays: the unpacked box under `~/.terraform/virtualbox/gold/`,
reused next time, plus `vboxnet0`, its DHCP server and the host NAT rules.
Those are one-time host setup, not per-environment.
