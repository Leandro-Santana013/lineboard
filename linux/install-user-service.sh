#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
service_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
service_path="$service_dir/lineboard-adapter.service"
mkdir -p "$service_dir"

cat > "$service_path" <<EOF
[Unit]
Description=Lineboard Linux cloud adapter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$repo_root
ExecStart=$(command -v node) $repo_root/linux/lineboard-adapter.mjs run --host 0.0.0.0 --port 47832
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.config/lineboard %h/.local/state/lineboard

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now lineboard-adapter.service
printf 'Installed and started %s\n' "$service_path"
