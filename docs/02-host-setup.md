# 2. Host setup

Everything in this chapter happens **once per machine**. `make host-setup`
runs both scripts:

```sh
make host-setup
# = scripts/vbox-network.sh            (as you)
#   sudo scripts/host-nat.sh install   (as root)
```

## 2.1 Software prerequisites

| Tool | Version | Used for |
|---|---|---|
| VirtualBox | 7.x | Runs the VMs. `VBoxManage` must be on `PATH`. |
| Terraform | ≥ 1.9 | Creates VMs and runs Ansible. 1.9 is needed for validations that compare two variables, such as "IP inside the network". |
| Ansible | `ansible-core` ≥ 2.15 | Configures the VMs. `make init` installs the collections it needs (`community.general`, `ansible.posix`). |
| iptables | any (nf_tables backend is fine) | Host NAT rules. |

Two files are also needed:

1. **A Vagrant box** for the VirtualBox provider, Ubuntu, **with
   VirtualBox Guest Additions**. `bento/ubuntu-24.04` qualifies.
   - *Guest Additions* run a small service inside the VM that reports its
     IP addresses to VirtualBox. The provider reads them from there; it has
     no other way to learn a VM's IP.
   - *Ubuntu* because the fixed-IP role writes **netplan** configuration.
   ```sh
   vagrant box add bento/ubuntu-24.04 --provider virtualbox
   # The .box contents land in ~/.vagrant.d/boxes/...; or download a .box URL directly.
   ```
2. **Vagrant's insecure private key.** Every official box ships with this
   well-known key authorized for the `vagrant` user. Ansible uses it for
   the very first login, then authorizes *your* key.
   ```sh
   curl -fsSLo ~/.ssh/vagrant_insecure https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant
   chmod 600 ~/.ssh/vagrant_insecure
   ```
   The key is public knowledge. That's acceptable only because the VMs sit
   on a network nothing outside your machine can reach, and because the
   `common` role turns off password login.

## 2.2 The host-only network: `scripts/vbox-network.sh`

Runs as **your user**, because VirtualBox stores DHCP server settings in
your per-user VirtualBox configuration. Every value can be overridden
with an environment variable:

| Variable | Default | Meaning |
|---|---|---|
| `IFACE` | `vboxnet0` | Host-only interface name |
| `HOST_IP` | `192.168.56.1` | Host's address on it = the VMs' gateway |
| `NETMASK` | `255.255.255.0` | → `192.168.56.0/24` |
| `DHCP_SERVER` | `192.168.56.2` | VirtualBox's built-in DHCP server address |
| `DHCP_LOWER` / `DHCP_UPPER` | `.100` / `.199` | Temporary addresses for first boot |

### Step 1 — create the interface if it's missing

```sh
VBoxManage list hostonlyifs                 # does vboxnet0 exist?
VBoxManage hostonlyif create                # if not: creates the next free vboxnetN
```

VirtualBox picks the name itself (`vboxnet0`, `vboxnet1`, …). If it
creates something other than the expected name (because `vboxnet0` was
deleted but higher numbers exist), the script stops and tells you to set
`IFACE`, and `host_only_interface` in Terraform, to the name it actually
created.

### Step 2 — give the host its address

```sh
VBoxManage hostonlyif ipconfig vboxnet0 --ip=192.168.56.1 --netmask=255.255.255.0
```

This puts `192.168.56.1/24` on the host's `vboxnet0` interface. From now
on the host can reach anything in `192.168.56.0/24`, and the VMs can reach
the host there. On Linux, VirtualBox only allows host-only addresses in
`192.168.56.0/21` unless others are listed in `/etc/vbox/networks.conf`.

### Step 3 — DHCP for first boot

```sh
VBoxManage dhcpserver add|modify --interface=vboxnet0 --server-ip=192.168.56.2 \
  --netmask=255.255.255.0 --lower-ip=192.168.56.100 --upper-ip=192.168.56.199 --enable
```

VirtualBox runs its own small DHCP server for the host-only network. The
script uses `modify` if one already exists, `add` otherwise. A new VM
gets an address from `.100`–`.199` until Ansible moves it to its fixed
IP, so **fixed IPs must stay outside this range**. Use `.10`–`.99`.
Terraform enforces this for the cluster (`max_host_number = 99`).

The resulting address plan:

```
192.168.56.1          host (gateway for every VM)
192.168.56.2          VirtualBox DHCP server
192.168.56.10 – .99   fixed IPs you assign (envs/dev examples: .11, .21; envs/k8s: .30+)
192.168.56.100 – .199 DHCP pool, used only during a VM's first boot
```

## 2.3 The host as NAT gateway: `scripts/host-nat.sh`

Runs as **root**. It has five subcommands:

| Command | Does |
|---|---|
| `install` | Copies itself to `/usr/local/sbin/vbox-nat`, writes the sysctl file and the systemd unit, enables and (re)starts the service. **This is what `make host-setup` runs.** |
| `apply` | Adds the rules now. Idempotent: running it twice adds nothing. |
| `remove` | Deletes exactly the rules it added. |
| `status` | Shows its rules and whether forwarding is on. |
| `uninstall` | Stops and removes the service, sysctl file and installed script. |

Overrides: `VBOX_NAT_CIDR` (default `192.168.56.0/24`), `VBOX_NAT_IFACE`
(default `vboxnet0`).

### What `apply` does, rule by rule

**1. Turn on IP forwarding**

```sh
sysctl -w net.ipv4.ip_forward=1
```

Without this, Linux drops packets that arrive on one interface and are
meant for another. A gateway's whole job is forwarding them. (`install`
also writes `/etc/sysctl.d/90-vbox-nat.conf` so it survives reboots.
Docker turns it on too.)

**2. Masquerade VM traffic leaving the host**

```sh
iptables -t nat -I POSTROUTING 1 -s 192.168.56.0/24 ! -o vboxnet0 -j MASQUERADE -m comment --comment vbox-nat
```

Read it as: *for packets from the VM network that are leaving through any
interface other than `vboxnet0`, rewrite the source address to the
host's own address on that interface.*

- `MASQUERADE` (rather than `SNAT --to <ip>`) looks up the outgoing
  interface's address **for each new connection**. That's what makes it
  follow the host from network to network: the rule names no uplink and
  no address.
- `! -o vboxnet0` leaves VM-to-VM and VM-to-host traffic untouched.
- Replies come back to the host's address; connection tracking reverses the
  translation and sends them to the right VM.

**3. Allow the forwarded traffic through the firewall**

```sh
iptables -I FORWARD 1 -i vboxnet0 -s 192.168.56.0/24 -j ACCEPT
iptables -I FORWARD 1 -o vboxnet0 -d 192.168.56.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

- First rule: anything the VMs send out is allowed.
- Second rule: only **replies** to connections the VMs opened are allowed
  back in. Nothing on the outside can open a new connection to a VM.

**Why insert at position 1 of `FORWARD`?** On this host both **Docker**
and **ufw** are active, and both set up forwarding to drop traffic by
default:

```
FORWARD chain (policy DROP)
 1  vbox-nat ACCEPT replies to VMs      ← ours, inserted first
 2  vbox-nat ACCEPT from VMs            ← ours
 3  -j DOCKER-USER / DOCKER-FORWARD ... ← Docker's (only handles Docker bridges)
 4  -j ufw-before-forward ...           ← ufw's (would drop us)
    policy DROP
```

iptables evaluates rules top to bottom and the first `ACCEPT` wins, so VM
traffic is allowed before Docker's or ufw's rules ever see it. If Docker
later re-inserts its own jump at the top, that's still fine: Docker's
chains only act on Docker bridge interfaces and return for anything else.

Every rule carries `-m comment --comment vbox-nat`. That's how `apply`
checks whether a rule already exists (`iptables -C`), and how `remove`
deletes only its own rules.

### Making it permanent: the systemd unit

`install` writes `/etc/systemd/system/vbox-nat.service`:

```ini
[Unit]
After=network-online.target docker.service ufw.service
[Service]
Type=oneshot
RemainAfterExit=yes
Environment=VBOX_NAT_CIDR=192.168.56.0/24 VBOX_NAT_IFACE=vboxnet0
ExecStart=/usr/local/sbin/vbox-nat apply
ExecStop=/usr/local/sbin/vbox-nat remove
[Install]
WantedBy=multi-user.target
```

- iptables rules live in kernel memory and vanish on reboot, so the service
  re-applies them at every boot.
- `After=docker.service ufw.service` makes it run after those two have
  built their own chains, so ours go on top.
- `oneshot` + `RemainAfterExit` means "run once, then count as active".
  `systemctl stop vbox-nat` runs `remove`.

The rules match the interface by **name**, so they're valid even before
VirtualBox creates `vboxnet0`.

### Verifying

```sh
sudo scripts/host-nat.sh status
#   -A POSTROUTING -s 192.168.56.0/24 ! -o vboxnet0 -m comment --comment vbox-nat -j MASQUERADE
#   -A FORWARD -d 192.168.56.0/24 -o vboxnet0 -m conntrack --ctstate RELATED,ESTABLISHED ... -j ACCEPT
#   -A FORWARD -s 192.168.56.0/24 -i vboxnet0 ... -j ACCEPT
#   ip_forward=1
systemctl status vbox-nat
```

Once a VM exists, the end-to-end check is from inside it:

```sh
ssh vagrant@192.168.56.11 'ip route; ping -c1 1.1.1.1; getent hosts example.com'
# default via 192.168.56.1 dev eth0 ...
```

## 2.4 What happens when the host changes networks

| Event | Effect on VMs |
|---|---|
| Wi-Fi → Ethernet (or a new Wi-Fi) | VM IPs unchanged. New outbound connections leave through the new uplink. Connections that were open drop, just as they do on the host. |
| Host connects to a VPN | If the VPN takes the default route, VM traffic goes through the VPN too. MASQUERADE uses the VPN interface's address. |
| Host goes offline | VMs still reach each other and the host. They have no internet. |
| Host reboots | `vbox-nat.service` restores the rules. VirtualBox keeps `vboxnet0` and its DHCP config. VMs keep their netplan config. |

**DNS:** VMs use `1.1.1.1` and `8.8.8.8` by default (`dns_servers`).
Public resolvers answer from any network, so DNS also survives network
changes. The catch: names that only resolve on a corporate network or
through a VPN won't resolve inside the VMs. If you need them, set
`dns_servers` to resolvers reachable from the VMs.
