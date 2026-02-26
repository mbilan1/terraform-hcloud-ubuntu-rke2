#!/bin/bash
# Install Ansible and dependencies on the Packer build instance.
# This runs before the ansible-local provisioner.
#
# DECISION: Install Galaxy roles and collections at build time.
# Why: The CIS hardening role (ansible-lockdown/UBUNTU24-CIS) is an external
#      Galaxy dependency. Installing it here ensures the ansible-local
#      provisioner can find it without internet access during playbook execution.
set -euo pipefail

apt-get update -q
apt-get install -q -y software-properties-common git
add-apt-repository --yes --update ppa:ansible/ansible
apt-get install -q -y ansible
ansible --version

# Install Galaxy collections and roles from requirements.yml
# NOTE: requirements.yml is uploaded by Packer's file provisioner
#       before this script runs.
if [ -f /tmp/packer-files/ansible/requirements.yml ]; then
  echo ">>> Installing Ansible Galaxy dependencies from requirements.yml..."
  ansible-galaxy collection install -r /tmp/packer-files/ansible/requirements.yml --force
  ansible-galaxy role install -r /tmp/packer-files/ansible/requirements.yml --force
  echo ">>> Galaxy dependencies installed."
else
  echo ">>> No requirements.yml found — skipping Galaxy install."
fi
