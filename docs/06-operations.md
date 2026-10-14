# 6. Operations & troubleshooting

## Everyday tasks

### First time on a machine

```sh
make host-setup                                        # vboxnet0 + DHCP + host NAT (sudo)
cp envs/dev/terraform.tfvars.example envs/dev/terraform.tfvars
$EDITOR envs/dev/terraform.tfvars                      # box, keys, VMs
make init
make up
```

### Add, change or remove a VM

Edit `vms` in `envs/dev/terraform.tfvars`, then:

```sh
make plan     # read it: "must be replaced" = VM rebuilt, data lost
make up
```

See [changes and what they cost](03-vm-lifecycle.md#changes-and-what-they-cost).

### Log in

```sh
terraform -chdir=envs/dev output ssh_commands
ssh vagrant@192.168.56.11                              # with your own key
```

### Re-run configuration only

```sh
make provision              # envs/dev
make provision ENV=k8s      # cluster
```

### Add your own configuration

1. Create a role:
   ```
   ansible/roles/postgres/tasks/main.yml
   ansible/roles/postgres/defaults/main.yml    # optional variables
   ```
2. Add a play to `ansible/site.yml`:
   ```yaml
   - name: Databases
     hosts: db
     become: true
     roles:
       - postgres
   ```
3. Put VMs in the group: `groups = ["db"]`.
4. `make up`. A change under `ansible/` re-runs the playbook automatically.

Group-wide variables go in `ansible/group_vars/db.yml`. Variables for a
single VM go in `host_vars = { ... }` in `terraform.tfvars`.

### A second environment

Copy `envs/dev` to, say, `envs/test`, adjust its `terraform.tfvars`,
and run `make init ENV=test && make up ENV=test`. Environments share
`vboxnet0`, so **give them different IPs**. VM names must also be unique
across environments: they're VirtualBox VM names.

### Power off without destroying

Set `status = "poweroff"` on a VM and `make up`. Set it back to
`"running"` to start it again. The disk is kept.

### Tear down

```sh
make down              # envs/dev
make down ENV=k8s      # cluster
```

The host setup stays. To remove that too:

```sh
sudo scripts/host-nat.sh uninstall
VBoxManage dhcpserver remove --interface=vboxnet0
VBoxManage hostonlyif remove vboxnet0
```

## Troubleshooting

Start by working out which stage failed. The first error in the
`terraform apply` output says which:

| Error mentions | Stage | Section |
|---|---|---|
| `Invalid value for variable`, `Resource precondition failed` | 1 — validation | [Validation errors](#validation-errors) |
| `virtualbox_vm`, `waiting for VM ... to become ready` | 2 — provider | [VM creation](#vm-creation-fails-or-hangs) |
| `local-exec provisioner error` + Ansible output | 4+ — Ansible | [Ansible](#ansible-fails) |

To debug any Ansible stage by hand, use the same inventory Terraform
generated:

```sh
cd ansible
ansible-playbook -i ../envs/dev/inventory.yml site.yml -v          # add -vvv for SSH detail
ansible -i ../envs/dev/inventory.yml all -m ping
```

### Validation errors

These are by design. The message says what's wrong, for example *"Every
VM's ip must be a valid IPv4 address inside network.cidr"* or *"These
networks overlap: network.cidr and pod_cidr"*. Fix the value and run
again. Nothing was created.

### VM creation fails or hangs

**`waiting for VM (web-01) to become ready: timeout while waiting for state to become 'yes'`**

The VM booted but never reported an IP on its host-only adapter within
5 minutes.

1. Look at the VM's console: open the VirtualBox GUI and select the VM.
   Is it still booting? Is there a login prompt?
2. Does the box have **Guest Additions**? Without them, the provider never
   sees an IP, even if the VM has one. Use a `bento/*` box.
3. Is DHCP enabled on `vboxnet0`?
   ```sh
   VBoxManage list dhcpservers        # NetworkName: HostInterfaceNetworking-vboxnet0, Enabled: Yes
   ```
   If not, run `scripts/vbox-network.sh` again.
4. Does the guest run DHCP on its first network card? Any standard Ubuntu
   box does.
5. Slow machine? Raise `ip_wait_delay_seconds`. The 5-minute overall limit
   is fixed in the provider.

After fixing, run `make up` again. A VM left half-created is marked
*tainted* and replaced.

**`VBoxManage: error: ... host-only interface vboxnet0 not found`**: run
`scripts/vbox-network.sh`.

**`failed to unpack image`**: the box path is wrong, or the file isn't a
VirtualBox box. Check `box_image`. `~` is expanded for you.

**Two different boxes, same file name.** The provider caches unpacked boxes
by **file name** in `~/.terraform/virtualbox/gold/<name>/`. A different box
with the same file name (say, both `vagrant.box`) silently reuses the
first one. Give box files distinct names, or delete the stale folder.

**A VM with this name already exists.** Something left a VM behind, for
example a deleted state file. Remove it in VirtualBox
(`VBoxManage unregistervm web-01 --delete`) or pick another name.

### Ansible fails

#### Can't connect: `UNREACHABLE` / `wait_for_connection` timed out

| Check | Command | Fix |
|---|---|---|
| VM reachable at all? | `ping 192.168.56.11` and the DHCP IP from `inventory.yml` | VM not running, or `vboxnet0` down |
| Right key? | `ssh -i ~/.ssh/vagrant_insecure vagrant@<ip>` | `ssh_private_key_file` must be Vagrant's insecure key for a fresh box |
| Key file permissions | `ls -l ~/.ssh/vagrant_insecure` | must be `600`, or SSH refuses it |

#### Lost the VM during `static_network`

The connection moves from the DHCP IP to the fixed IP mid-run. If the
reconnect fails:

- Is the fixed IP already used by another VM, including one from another
  environment? Two machines on one IP cause intermittent failures.
- Is the fixed IP in `network_cidr`? Terraform checks this, but only
  against the CIDR you gave it.
- Log in through the VirtualBox console (user `vagrant`, password
  `vagrant` on Vagrant boxes) and check:
  ```sh
  ip addr; ip route; sudo netplan get; sudo cat /etc/netplan/99-static.yaml
  ```

#### Package installs fail: `Temporary failure resolving`, `Could not connect`

The VM has no internet. Check from the inside out:

```sh
ssh vagrant@192.168.56.11
ip route                    # must show: default via 192.168.56.1
ping -c1 192.168.56.1       # host reachable?        no  → vboxnet0 / IP problem
ping -c1 1.1.1.1            # internet by IP?        no  → host NAT problem ↓
getent hosts ubuntu.com     # DNS?                   no  → dns_servers blocked on this network?
```

Host NAT problems:

```sh
sudo scripts/host-nat.sh status       # all three rules + ip_forward=1?
systemctl status vbox-nat
sudo systemctl restart vbox-nat       # re-inserts rules at the top
```

The usual cause is that **ufw or Docker reloaded and rebuilt their rules**
(`ufw reload`, a Docker restart or upgrade), pushing ours down or
flushing them. `systemctl restart vbox-nat` fixes it. Also check that the
host itself is online.

#### `static_network only supports netplan guests`

The box isn't Ubuntu. Use an Ubuntu box, or extend
`roles/static_network` for the guest's network tooling, such as
NetworkManager (`nmcli`) on RHEL-family guests.

### Kubernetes problems

All from your machine with `export KUBECONFIG=envs/k8s/lab.kubeconfig`,
or on the control plane after `ssh vagrant@192.168.56.30`.

| Symptom | Likely cause | Check / fix |
|---|---|---|
| `kubeadm init` preflight error: CPUs / memory | VM too small | Terraform should prevent this. Raise `control_plane` |
| `kubeadm init` fails: container runtime not running | containerd config problem | `sudo systemctl status containerd`; `sudo crictl info` |
| Packages fail on `pkgs.k8s.io` with 403/404 | `kubernetes_version` doesn't exist (yet or anymore) | `curl -sI https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release` |
| Node `NotReady` | No pod network on it | `kubectl -n kube-flannel get pods -o wide`; `kubectl describe node <n>` |
| Flannel pod `CrashLoopBackOff` | Pod CIDR mismatch, or `br_netfilter` missing | `kubectl -n kube-flannel logs <pod>`; on the node: `lsmod \| grep br_netfilter` |
| CoreDNS `Pending` | No node Ready yet (pod network) | Fix Flannel first |
| Images fail to pull: `ErrImagePull` | Node has no internet | See [package installs fail](#package-installs-fail-temporary-failure-resolving-could-not-connect) |
| Worker never joins | Join token expired / API unreachable | Re-run `make provision ENV=k8s` (it makes a fresh token); `nc -zv 192.168.56.30 6443` from the worker |
| `kubectl` from host: connection refused / timeout | API server down or wrong kubeconfig | `ssh vagrant@192.168.56.30 'sudo crictl ps \| grep kube-apiserver'` |
| `x509: certificate signed by unknown authority` | Old kubeconfig from a previous cluster | `make provision ENV=k8s` fetches the current one |
| Readiness wait times out | Any of the above | The playbook stops at the failing wait. Inspect with `kubectl get pods -A` |

Node-level logs:

```sh
sudo journalctl -u kubelet -e          # kubelet: why a node isn't Ready, why pods won't start
sudo journalctl -u containerd -e
sudo crictl ps -a                      # containers on this node, including crashed ones
```

**Starting over** is cheap and often the fastest fix for a lab cluster:
`make down ENV=k8s && make up ENV=k8s`.

### Terraform state is lost or out of sync

If you delete VMs in the VirtualBox GUI, `make up` notices they're gone
during refresh and recreates them.

If you **lose the state file** while VMs exist, Terraform no longer knows
about them, and `make up` fails because the names are taken. Delete the
orphans and start clean:

```sh
VBoxManage list vms
VBoxManage controlvm web-01 poweroff; VBoxManage unregistervm web-01 --delete
```

## Running the checks

```sh
make test     # terraform test: all modules, mocked provider, no VirtualBox needed
make lint     # fmt, validate, ansible-lint
```

The tests cover:

- naming,
- IP and MAC handling,
- every validation: bad IPs, duplicates, gateway clash, CIDR overlap, DHCP
  range, sizes, group names,
- inventory contents,
- the cluster's node layout.

They don't start real VMs. A full end-to-end check is `make up` on a
machine with VirtualBox.
