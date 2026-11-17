#!/usr/bin/env bash
# The dashboard server's Login item (kit.yaml → startupItems): openrc's supervise-daemon
# runs this at every boot and restarts it when it exits (docs/catalog.md → The server).
exec node "$HOME/scripts/dashboard/server.mjs"
