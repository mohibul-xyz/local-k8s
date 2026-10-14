ENV ?= dev
TF  := terraform -chdir=envs/$(ENV)

ifeq ($(ENV),k8s)
PLAYBOOK  ?= k8s.yml
INVENTORY ?= ../envs/k8s/lab-inventory.yml
else
PLAYBOOK  ?= site.yml
INVENTORY ?= ../envs/$(ENV)/inventory.yml
endif

.PHONY: host-setup init plan up down provision test lint fmt

host-setup:      ## One-time: host-only network + host NAT gateway (asks for sudo)
	scripts/vbox-network.sh
	sudo scripts/host-nat.sh install

init:            ## Install providers and Ansible collections
	$(TF) init
	ansible-galaxy collection install -r ansible/requirements.yml

plan:            ## Show what would change
	$(TF) plan

up:              ## Create/update VMs, then run Ansible  (make up ENV=k8s for the cluster)
	$(TF) apply

down:            ## Destroy every VM in the environment
	$(TF) destroy

provision:       ## Re-run Ansible only, against the current inventory
	cd ansible && ansible-playbook -i $(INVENTORY) $(PLAYBOOK)

test:            ## Module unit tests (mocked provider; no VirtualBox needed)
	terraform -chdir=modules/vm test
	terraform -chdir=modules/fleet test
	terraform -chdir=modules/k8s-cluster test

lint:            ## Format check, validate, ansible-lint
	terraform fmt -check -recursive
	$(TF) validate
	cd ansible && ansible-lint

fmt:
	terraform fmt -recursive
