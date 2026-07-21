# RawOS build orchestration.
# Most targets need root (debootstrap, chroot, loop devices). Use: sudo make iso
SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help iso appliances all deps clean distclean check

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[1;34m%-12s\033[0m %s\n",$$1,$$2}'

deps: ## Install host build dependencies (Debian/Ubuntu)
	sudo apt-get update && sudo apt-get install -y \
	  debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin \
	  mtools dosfstools rsync qemu-utils parted e2fsprogs imagemagick

check: ## Syntax-check all shell scripts
	@set -e; for f in build/*.sh chroot-hooks/*.sh patches/*.sh; do \
	  echo "bash -n $$f"; bash -n "$$f"; done; echo "all scripts OK"

iso: ## Build the live+install ISO (root)
	sudo ./build/build-iso.sh

appliances: ## Build .qcow2 + .ova from the built rootfs (root; run after iso)
	sudo ./build/build-appliances.sh

all: iso appliances ## Build ISO then appliances

clean: ## Remove build working tree (keeps out/ and download cache)
	sudo rm -rf work

distclean: clean ## Also remove artifacts and cache
	sudo rm -rf out .cache
