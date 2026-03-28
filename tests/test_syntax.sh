#!/bin/sh
# Quick syntax and lint checks — runs without a hypervisor.
# Usage: ./tests/test_syntax.sh
set -e

echo "=== Ansible syntax check: site.yml ==="
ansible-playbook site.yml --syntax-check

echo "=== Ansible syntax check: runners.yml ==="
ansible-playbook runners.yml --syntax-check

echo "=== Ansible syntax check: destroy.yml ==="
ansible-playbook destroy.yml --syntax-check

echo "=== Ansible syntax check: tests/test_lifecycle.yml ==="
ansible-playbook tests/test_lifecycle.yml --syntax-check

echo "=== YAML lint: group_vars ==="
python3 -c "import yaml; yaml.safe_load(open('group_vars/xen_hosts.yml'))" && echo "OK"

echo "=== YAML lint: VM definitions ==="
for f in vms/*.yml; do
    python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "OK: $f"
done

echo ""
echo "All syntax checks passed."
