# Documentation

How this project turns a few lines of configuration into running,
configured VirtualBox VMs or a ready Kubernetes cluster. These docs explain
each step in detail: what runs, in what order, and why.

| # | Document | Read it to learn |
|---|---|---|
| 1 | [Architecture](01-architecture.md) | The big picture: the pieces, how they connect, and the design decisions behind them. |
| 2 | [Host setup](02-host-setup.md) | The one-time setup on your machine: the host-only network, DHCP, and the host acting as NAT gateway. Every command and firewall rule explained. |
| 3 | [VM lifecycle](03-vm-lifecycle.md) | What happens, step by step, from `make up` to a provisioned VM, and on every later run, change and destroy. |
| 4 | [Kubernetes cluster](04-kubernetes.md) | How `modules/k8s-cluster` builds a kubeadm cluster: node layout, every install step, how "ready" is decided, scaling. |
| 5 | [Reference](05-reference.md) | Every module input and output, the generated inventory format, Ansible variables, Make targets. |
| 6 | [Operations & troubleshooting](06-operations.md) | Day-to-day tasks, and what to check when something goes wrong. |

New here? Read 1, then 2, then 3. Read 4 if you want the cluster. Keep 5
and 6 for lookups.

The [top-level README](../README.md) is the short version: prerequisites
and the commands to run.
