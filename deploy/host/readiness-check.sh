#!/bin/bash
# READ-ONLY readiness check of the lab host before the first deployment. Run it ON THE INSTANCE (for example in a Session Manager session):
#   sudo bash deploy/host/readiness-check.sh
# It changes nothing and prints no secret: ownership and modes, the sudoers rule, the restricted authorized_keys (public fingerprints only), the
# host key fingerprint, the effective sshd settings, listeners, services and Docker. The setup script has its own pass/fail verification:
#   sudo bash deploy/host/setup-deploy-host.sh --verify
echo "== deploy user"; id deploy 2>&1; passwd -S deploy 2>&1
echo "== ownership and modes (owner:group mode path)"
stat -c '%U:%G %a %n' / /var /var/lib /var/lib/shopnest /opt/shopnest /usr/local/sbin /usr/local/sbin/shopnest-deploy /usr/local/sbin/shopnest-rollback /usr/local/sbin/shopnest-ssh-entry /etc/shopnest /etc/shopnest/release.conf /home/deploy /home/deploy/.ssh /home/deploy/.ssh/authorized_keys /etc/sudoers.d/deploy 2>&1
echo "== state dir"; ls -la /var/lib/shopnest 2>&1 | head -10
echo "== sudoers rule"; cat /etc/sudoers.d/deploy 2>&1
echo "== release.conf (not secret)"; cat /etc/shopnest/release.conf 2>&1
echo "== authorized_keys: options and public fingerprints"
sed -E 's/ssh-ed25519 [A-Za-z0-9+\/=]+.*/ssh-ed25519 <key>/' /home/deploy/.ssh/authorized_keys 2>&1 | grep -v '^#'
ssh-keygen -lf /home/deploy/.ssh/authorized_keys 2>&1
echo "== wrappers match the repository copy? (sizes only)"; wc -c /usr/local/sbin/shopnest-deploy /usr/local/sbin/shopnest-rollback /usr/local/sbin/shopnest-ssh-entry 2>&1
echo "== host key fingerprint"; ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>&1
echo "== sshd effective settings"; sshd -T 2>/dev/null | grep -E '^(passwordauthentication|pubkeyauthentication|permitrootlogin|kbdinteractiveauthentication|allowtcpforwarding|port|listenaddress) '
echo "== listeners"; ss -ltn 2>&1 | awk 'NR==1 || /:22 |:80 |:8081 /'
echo "== services and docker"; systemctl is-active ssh docker amazon-ssm-agent 2>&1; docker --version 2>&1; docker ps --format '{{.Names}} {{.Status}}' 2>&1 | head
echo "== bootstrap markers"; ls -la /var/lib/shopnest/bootstrap-complete /var/lib/shopnest/bootstrap-failed 2>&1
echo "== listing of /opt/shopnest"; ls -la /opt/shopnest 2>&1 | head -12
echo "== uname/disk/mem"; uname -sr; df -h / | tail -1; free -m | sed -n 2p
