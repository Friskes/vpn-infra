#!/usr/bin/env bash
# Доступ к серверу с локального ПК. Вызывается из Makefile, руками запускать не нужно.
#   access.sh admin [сервер]  — SSH-проброс к админкам wg-easy и 3x-ui, адреса и пароли
#   access.sh key [сервер]    — положить ключ проекта на сервер по root-паролю (разово)
#   access.sh shell [сервер]  — консоль сервера
# Сервер по умолчанию — первый в группе vpn инвентаря.
set -euo pipefail

MODE="${1:?admin, key или shell}"
HOST="${2:-}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
KEY=keys/vpn-infra
WG_LOCAL="${WG_LOCAL:-15821}"
XUI_LOCAL="${XUI_LOCAL:-2053}"

inventory_json="$(.venv/bin/ansible-inventory --list 2>/dev/null)"
if [ -z "$HOST" ]; then
  HOST="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["vpn"]["hosts"][0])' <<<"$inventory_json" 2>/dev/null)" \
    || { echo "В инвентаре нет серверов — сначала make new-host"; exit 1; }
fi
IP="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["_meta"]["hostvars"][sys.argv[1]]["ansible_host"])' \
  "$HOST" <<<"$inventory_json" 2>/dev/null)" || { echo "Сервер $HOST не найден в инвентаре (make hosts)"; exit 1; }

if [ "$MODE" = key ]; then
  echo "Кладу $KEY.pub на $HOST ($IP) — введите пароль root, который выдал хостер."
  echo "Вводимые символы не отображаются, так и должно быть."
  ssh-copy-id -i "$KEY.pub" -o StrictHostKeyChecking=accept-new "root@$IP"
  echo "Готово: дальше make deploy HOST=$HOST ходит по ключу, а после развёртывания вход по паролю закроется."
  exit 0
fi

SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "root@$IP")
if [ "$MODE" = shell ]; then
  exec "${SSH[@]}"
fi

path="$("${SSH[@]}" 'cat /root/.x-ui/.base-path 2>/dev/null' || true)"
secrets="$(.venv/bin/ansible "$HOST" -m ansible.builtin.debug \
  -a '{"msg": "{{ wireguard_admin_password }}|{{ xui_admin_password }}|{{ xui_admin_user | default(\"admin\") }}"}' \
  2>/dev/null | python3 -c 'import sys,re; m=re.search(r"\"msg\": \"([^\"]*)\"", sys.stdin.read()); print(m.group(1) if m else "||")' \
  || echo "||")"
IFS='|' read -r wg_pass xui_pass xui_user <<<"$secrets" || true

cat <<EOF

Сервер $HOST ($IP). Пока это окно открыто, админки доступны в браузере:

  WireGuard (wg-easy)  http://127.0.0.1:$WG_LOCAL
                       пароль: ${wg_pass:-не найден, make show-secrets}
EOF
if [ -n "$path" ]; then
  cat <<EOF
  Reality (3x-ui)      http://127.0.0.1:$XUI_LOCAL$path
                       логин: ${xui_user:-admin}  пароль: ${xui_pass:-не найден, make show-secrets}
EOF
fi
echo
echo "Закрыть доступ — Ctrl+C."
exec "${SSH[@]}" -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
  -L "$WG_LOCAL:127.0.0.1:51821" -L "$XUI_LOCAL:127.0.0.1:2053"
