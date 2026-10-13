#!/usr/bin/env bash
# ssh into the VM of scripts/run-vm.sh as root (dev profile). Arguments go to ssh, e.g. a command:
#   scripts/ssh.sh openhu-cli status
#   scripts/ssh.sh -L 5520:127.0.0.1:5520 -N     (OpenHU API on the host)
# A VM started with --instance/--ssh-port: OPENHU_VM_SSH_PORT=PORT scripts/ssh.sh
exec ssh -p "${OPENHU_VM_SSH_PORT:-2222}" -i "$(dirname "$0")/../local/id_ed25519" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
