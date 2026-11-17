#!/usr/bin/env bash
# dashboard-service.sh install|check — the dashboard server's Login item for an agent created
# without the kit, or before 3.60.0 (the kit's startupItems write the same service at create).
# install writes ~/.config/rc/init.d/quality-inspector-dashboard, links it into the default
# runlevel and starts it; it never replaces a script already there. check says whether the
# server answers on its loopback port (docs/catalog.md → The server).
set -u
HOME_DIR="${HOME:-/home/agent}"
NAME=quality-inspector-dashboard
SVC="$HOME_DIR/.config/rc/init.d/$NAME"
PORT="${QI_DASHBOARD_PORT:-5555}"
answers() { curl -sf --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }
case "${1:-check}" in
  install)
    if [ ! -f "$SVC" ]; then
      mkdir -p "$(dirname "$SVC")" "$HOME_DIR/.config/rc/runlevels/default"
      cat > "$SVC" <<SVCEOF
#!/sbin/openrc-run
description="Quality Inspector: the dashboard's data and commands on the Artifact API port"
command="$HOME_DIR/scripts/dashboard/serve.sh"
SVCEOF
      chmod +x "$SVC"
      ln -sf "$SVC" "$HOME_DIR/.config/rc/runlevels/default/$NAME"
    fi
    rc-service --user "$NAME" start >/dev/null 2>&1 || rc-service --user "$NAME" restart >/dev/null 2>&1 || true
    sleep 1
    if answers; then echo "ok   dashboard server answers on 127.0.0.1:$PORT"
    else echo "FAIL dashboard server does not answer — rc-service --user $NAME status; log ~/.local/state/rc/$NAME.log"; exit 1; fi;;
  restart)
    rc-service --user "$NAME" restart >/dev/null 2>&1 || true
    sleep 1
    if answers; then echo "ok   dashboard server restarted"; else echo "FAIL dashboard server does not answer after a restart"; exit 1; fi;;
  check)
    if answers; then echo "ok   dashboard server answers"; else echo "FAIL dashboard server does not answer"; exit 1; fi;;
  *) echo "usage: dashboard-service.sh install|restart|check"; exit 2;;
esac
