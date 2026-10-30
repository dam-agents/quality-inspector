#!/usr/bin/env bash
# helm-k3s `kvm` and `host_dirs` (engines/helm-k3s/README.md → KVM): the node side of `up` —
# /dev/kvm opened to all, the kubelet's root moved off an overlay (k3s stopped first when it
# runs on the old one), node directories bind-mounted from the home disk and the pods on them
# restarted, and k3s kept on the port its data dir was made on. The node is a directory
# (QI_NODE_ROOT); stat, mountpoint, mount, pkill, pgrep, k3s, helm and curl are stubs.
. "$(dirname "$0")/lib.sh"
ENG="$SCRIPTS/../engines/helm-k3s"
N="$SANDBOX/node"; H="$SANDBOX/home"; B="$SANDBOX/kbin"; L="$SANDBOX/calls.log"
mkdir -p "$B"
export N H L
# stat -f -c %T <p>: overlayfs for a path under the node, unless STUB_HOME_OVERLAY=0 and it is under the home.
cat > "$B/stat" <<'S'
#!/usr/bin/env bash
p="${!#}"
case "$p" in
  "$H"*) [ "${STUB_HOME_OVERLAY:-0}" = 1 ] && echo overlayfs || echo ext4 ;;
  "$N"*) echo overlayfs ;;
  *) echo ext4 ;;
esac
S
cat > "$B/mountpoint" <<'S'
#!/usr/bin/env bash
grep -qxF "${!#}" "$N.mounts" 2>/dev/null
S
# mount with no argument prints the table in $N.table; umount and the iptables pairs never touch
# this machine: the suite also runs on the agent's own VM (docs/self-modification.md §9).
cat > "$B/mount" <<'S'
#!/usr/bin/env bash
[ $# -eq 0 ] && { cat "$N.table" 2>/dev/null; exit 0; }
echo "mount $*" >> "$L"; [ "$1" = --bind ] && echo "$3" >> "$N.mounts"; exit 0
S
printf '#!/usr/bin/env bash\necho "umount $*" >> "$L"\n' > "$B/umount"
for b in iptables iptables-legacy; do
  printf '#!/usr/bin/env bash\ncat "$N.rules" 2>/dev/null\n' > "$B/$b-save"
  printf '#!/usr/bin/env bash\ncat > "$N.restored-%s"\n' "$b" > "$B/$b-restore"
done
cat > "$B/pkill" <<'S'
#!/usr/bin/env bash
echo "pkill $*" >> "$L"; case "$*" in (*"k3s server"*) rm -f "$N.running";; esac; exit 0
S
cat > "$B/pgrep" <<'S'
#!/usr/bin/env bash
[ -f "$N.running" ]
S
cat > "$B/k3s" <<'S'
#!/usr/bin/env bash
case "$*" in
  "kubectl get --raw=/readyz") [ -f "$N.running" ] ;;
  server*) echo "k3s $*" >> "$L"; touch "$N.running" ;;
  "kubectl get pods -A -o json") cat "$N.pods" 2>/dev/null || echo '{"items":[]}' ;;
  kubectl\ -n\ *\ delete\ pod*) echo "k3s $*" >> "$L" ;;
  kubectl\ apply*) cat >/dev/null ;;
  *) exit 0 ;;
esac
S
printf '#!/usr/bin/env bash\n[ "$1" = version ] && echo "v3.19.0+gstub"\n[ "$1" = pull ] && while [ $# -gt 0 ]; do [ "$1" = --untardir ] && mkdir -p "$2/chart"; shift; done\nexit 0\n' > "$B/helm"
printf '#!/usr/bin/env bash\nprintf 200\n' > "$B/curl"
chmod +x "$B"/*

CFG0='{"chart":"oci://reg.example/acme/chart","registry_api":"oci","release":"app","app_port":8080,
  "channels":{"main":{"tag":"^1$","order":"semver"}},"default_candidate":"main",
  "credentials":{"users":{"owner":{"username":"qa"}}},"values":{"user":"{{user:owner.username}}"}}'
fresh() { rm -rf "$N" "$N".* "$H" "$SANDBOX/envd" "$L"; mkdir -p "$N/var/lib" "$N/var/log" "$N/etc/rancher/k3s" "$H" "$SANDBOX/envd"; : > "$L"
  printf 'E2E_USER_OWNER_USERNAME=qa\nE2E_USER_OWNER_PASSWORD=pw\n' > "$SANDBOX/envd/credentials.env"; }
up() { # <engine_config overrides (jq)>
  PATH="$B:$PATH" HOME="$H" QI_NODE_ROOT="$N" QI_ENV_DIR="$SANDBOX/envd" QI_PROFILE_CONFIG='{}' \
    QI_ENGINE_CONFIG="$(jq -c "$1" <<<"$CFG0")" bash "$ENG/bin/env" up 1 >/dev/null 2>"$SANDBOX/err"; echo $?; }
DROPIN="$N/etc/rancher/k3s/config.yaml.d/60-kubelet-root.yaml"

# Without kvm: nothing on the node changes.
fresh; mkdir -p "$N/dev"; : > "$N/dev/kvm"; chmod 0600 "$N/dev/kvm"
assert_eq "no kvm: up succeeds" 0 "$(up '.')"
[ -e "$DROPIN" ] && { echo "  no kvm: no kubelet drop-in"; FAILED=1; }
assert_eq "no kvm: /dev/kvm untouched" 600 "$(stat -c %a "$N/dev/kvm" 2>/dev/null || /usr/bin/stat -f %Lp "$N/dev/kvm")"

# kvm, k3s not running: /dev/kvm 0666, the drop-in written before k3s starts, no stop.
fresh; mkdir -p "$N/dev"; : > "$N/dev/kvm"; chmod 0600 "$N/dev/kvm"
assert_eq "kvm: up succeeds" 0 "$(up '.kvm = true')"
assert_eq "kvm: /dev/kvm opened to all" 666 "$(/usr/bin/stat -c %a "$N/dev/kvm" 2>/dev/null || /usr/bin/stat -f %Lp "$N/dev/kvm")"
grep -qx "  - \"root-dir=$H/.local/share/kubelet\"" "$DROPIN" 2>/dev/null || { echo "  kvm: the drop-in moves the kubelet's root to the home"; FAILED=1; }
grep -q '^kubelet-arg+:' "$DROPIN" 2>/dev/null || { echo "  kvm: the drop-in appends to kubelet-arg"; FAILED=1; }
grep -q "^pkill" "$L" && { echo "  kvm: a k3s not running is not stopped"; FAILED=1; }

# kvm, k3s running on the old root: stopped once, then the drop-in, then started again.
fresh; mkdir -p "$N/dev" "$N/var/lib/cni"; : > "$N/dev/kvm"; touch "$N.running"
cat > "$N.table" <<T
overlay on / type overlay (rw)
shm on /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/abc/shm type tmpfs (rw)
tmpfs on /var/lib/kubelet/pods/p1/volumes/kubernetes.io~projected/kube-api-access type tmpfs (rw)
tmpfs on $H/.local/share/kubelet/pods/p2/volumes/v type tmpfs (rw)
nsfs on /run/netns/cni-1234 type nsfs (rw)
/dev/vdb on /home/agent type ext4 (rw)
tmpfs on /run/user/1000 type tmpfs (rw)
T
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' ':KUBE-SERVICES - [0:0]' ':CNI-FORWARD - [0:0]' ':FLANNEL-FWD - [0:0]' \
  '-A INPUT -j KUBE-SERVICES' '-A INPUT -p tcp --dport 22 -j ACCEPT' '-A FORWARD -m comment --comment "flannel forwarding" -j ACCEPT' 'COMMIT' > "$N.rules"
assert_eq "kvm, running: up succeeds" 0 "$(up '.kvm = true')"
assert_eq "kvm, running: the pods' mounts are unmounted, and no other" \
  "$(printf '%s\n' /var/lib/kubelet/pods/p1/volumes/kubernetes.io~projected/kube-api-access /run/netns/cni-1234 \
      /run/k3s/containerd/io.containerd.grpc.v1.cri/sandboxes/abc/shm "$H/.local/share/kubelet/pods/p2/volumes/v" | sort | paste -sd'|' -)" \
  "$(grep '^umount' "$L" | sed 's/^umount -l //' | sort -u | paste -sd'|' -)"
for b in iptables iptables-legacy; do
  assert_eq "kvm, running: $b keeps only the VM's own rules" \
    "*filter|:INPUT ACCEPT [0:0]|-A INPUT -p tcp --dport 22 -j ACCEPT|COMMIT" "$(paste -sd'|' - < "$N.restored-$b" 2>/dev/null)"
done
[ -e "$N/var/lib/cni" ] && { echo "  kvm, running: the CNI state goes"; FAILED=1; }
grep -q "^pkill -f k3s server" "$L" || { echo "  kvm, running: k3s is stopped"; FAILED=1; }
grep -q "^pkill -9 -f /k3s/data/.*containerd-shim" "$L" || { echo "  kvm, running: its pods' shims go too"; FAILED=1; }
grep -q "^k3s server" "$L" || { echo "  kvm, running: k3s starts again"; FAILED=1; }
grep -q "stopping k3s, to start it on the kubelet's new root" "$SANDBOX/err" || { echo "  kvm, running: says why it stops k3s"; FAILED=1; }

# The drop-in already there: k3s that runs keeps running.
: > "$L"; touch "$N.running"
assert_eq "kvm, moved already: up succeeds" 0 "$(up '.kvm = true')"
grep -q "^pkill" "$L" && { echo "  kvm, moved already: no second stop"; FAILED=1; }

# k3s does not stop: the drop-in is not written, and up fails.
fresh; mkdir -p "$N/dev"; : > "$N/dev/kvm"; touch "$N.running"
printf '#!/usr/bin/env bash\necho "pkill $*" >> "$L"; exit 0\n' > "$B/pkill"
sleep() { :; }; export -f sleep
assert_eq "kvm, k3s will not stop: up fails" 1 "$(up '.kvm = true')"
unset -f sleep
[ -e "$DROPIN" ] && { echo "  kvm, k3s will not stop: no drop-in"; FAILED=1; }
printf '#!/usr/bin/env bash\necho "pkill $*" >> "$L"; case "$*" in (*"k3s server"*) rm -f "$N.running";; esac; exit 0\n' > "$B/pkill"

# The home on an overlay too: nothing moves, and up says so.
fresh; mkdir -p "$N/dev"; : > "$N/dev/kvm"
STUB_HOME_OVERLAY=1 up '.kvm = true' >/dev/null
[ -e "$DROPIN" ] && { echo "  home on an overlay: no drop-in"; FAILED=1; }
grep -q "both on an overlay" "$SANDBOX/err" || { echo "  home on an overlay: says so"; FAILED=1; }

# No /dev/kvm: the install still runs, with a warning.
fresh
assert_eq "no /dev/kvm: up succeeds" 0 "$(up '.kvm = true')"
grep -q "no /dev/kvm on the node" "$SANDBOX/err" || { echo "  no /dev/kvm: warns"; FAILED=1; }

# host_dirs: each from a source of its own whole path, what it held copied over; a mount point skipped.
fresh; mkdir -p "$N/a/images" "$N/b/images" "$N/var/lib/vm-images"; echo old > "$N/a/images/keep"
echo "$N/var/lib/vm-images" > "$N.mounts"
assert_eq "host_dirs: up succeeds" 0 "$(up '.host_dirs = ["/a/images", "/b//images/", "/var/lib/vm-images"]')"
grep -qx "mount --bind $H/.local/share/host-a-images $N/a/images" "$L" || { echo "  host_dirs: /a/images from host-a-images: $(cat "$L")"; FAILED=1; }
grep -qx "mount --bind $H/.local/share/host-b-images $N/b/images" "$L" || { echo "  host_dirs: /b//images/ from its own source, slashes collapsed"; FAILED=1; }
grep -q "vm-images" "$L" && { echo "  host_dirs: a mount point is left alone"; FAILED=1; }
assert_eq "host_dirs: what it held is copied over" old "$(cat "$H/.local/share/host-a-images/keep" 2>/dev/null)"
[ -e "$H/.local/share/host-b-images/keep" ] && { echo "  host_dirs: sources never shared"; FAILED=1; }

# host_dirs mounted while k3s runs: the pods on them (or a subdirectory) restart; others stay.
fresh; mkdir -p "$N/a/images"; touch "$N.running"
cat > "$N.pods" <<'J'
{"items":[{"metadata":{"namespace":"ns1","name":"runner"},"spec":{"volumes":[{"hostPath":{"path":"/a/images/default/app"}}]}},
          {"metadata":{"namespace":"ns1","name":"other"},"spec":{"volumes":[{"hostPath":{"path":"/a/images-x"}},{"emptyDir":{}}]}}]}
J
assert_eq "host_dirs, running: up succeeds" 0 "$(up '.host_dirs = ["/a/images"]')"
grep -q "^k3s kubectl -n ns1 delete pod runner" "$L" || { echo "  host_dirs, running: the pod on the directory restarts"; FAILED=1; }
grep -q "delete pod other" "$L" && { echo "  host_dirs, running: a pod on another directory stays"; FAILED=1; }

# k3s keeps the port its data dir was made on.
fresh; mkdir -p "$N/data/server/cred"
printf 'data-dir: /data\nhttps-listen-port: 16443\n' > "$N/etc/rancher/k3s/config.yaml"
printf 'clusters:\n- cluster:\n    server: https://127.0.0.1:6444\n' > "$N/data/server/cred/admin.kubeconfig"
up '.' >/dev/null
grep -qx "k3s server --https-listen-port 6443" "$L" || { echo "  port: a cluster made on 6443 keeps it: $(grep server "$L")"; FAILED=1; }
fresh; mkdir -p "$N/data/server/cred"
printf 'data-dir: "/data"\n' > "$N/etc/rancher/k3s/config.yaml"
printf 'clusters:\n- cluster:\n    server: https://127.0.0.1:6444\n' > "$N/data/server/cred/admin.kubeconfig"
up '.' >/dev/null
grep -qx "k3s server --https-listen-port 6443" "$L" || { echo "  port: a quoted data-dir is read too: $(grep server "$L")"; FAILED=1; }
fresh; up '.' >/dev/null
grep -qx "k3s server" "$L" || { echo "  port: a fresh data dir takes the config's port"; FAILED=1; }

exit $FAILED
