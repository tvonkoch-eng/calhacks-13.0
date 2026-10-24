#!/bin/bash
# tools/qm-mac-ssh.sh — shared ssh setup for every agent sandbox. Source it, don't run it.
#
# WHY THIS EXISTS: a cold ssh to the Mac costs ~5 s. The tunnel is tailscale in
# userspace-networking mode, so every connection pays a full proxy + TCP + SSH handshake.
# A normal iteration used to open three of them (push, check, deploy) = ~15 s of pure
# connection setup, more than the build. With ControlMaster the first call opens a master
# that persists 30 min and every later call rides it in ~1.5 s.
#
#   . tools/qm-mac-ssh.sh ; macssh 'hostname'
#
# Needs the tailscale credential in execute.credentials: ["tailscale:dfa15f425ebf5238"]
MAC_IP=100.100.44.96
MAC_USER=jdelpego
MAC_KEY=/root/.ssh/qm_mac

qm_ssh_setup() {
  export PATH="$PATH:/usr/local/bin"
  [ -f "$MAC_KEY" ] || { echo "MISSING $MAC_KEY — this sandbox has no key for the Mac."; return 1; }
  mkdir -p /root/.ssh/cm
  # Written every time: it is tiny, and an agent sandbox that has never run this has no config.
  cat > /root/.ssh/config <<EOF
Host mac
  HostName $MAC_IP
  User $MAC_USER
  IdentityFile $MAC_KEY
  ProxyCommand tailscale nc %h %p
  EscapeChar none
  ControlMaster auto
  ControlPath /root/.ssh/cm/%r@%h:%p
  ControlPersist 30m
  ServerAliveInterval 30
  ServerAliveCountMax 6
  StrictHostKeyChecking no
  UserKnownHostsFile /root/.ssh/known_hosts
EOF
  chmod 600 /root/.ssh/config
  # EscapeChar none is not optional: without it ssh silently truncates piped data.
  export GIT_SSH_COMMAND="ssh -F /root/.ssh/config"
}
macssh() { qm_ssh_setup || return 1; ssh mac "$@"; }
# Open the multiplexed master now so the next call is cheap. Safe to call repeatedly.
qm_warm() {
  qm_ssh_setup || return 1
  ssh -O check mac 2>/dev/null || ssh -f -N mac 2>/dev/null || true
}
