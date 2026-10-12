#!/bin/bash

set -ouex pipefail

# install vm packages
dnf -y install \
  ceph-common \
  qemu-guest-agent

# qemu-guest-agent for running as a vm inside Proxmox
