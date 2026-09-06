#!/usr/bin/env bash
# Заводит новый сервер: каталог host_vars/<имя>/ из шаблона и запись в инвентаре.
# Вызывается из Makefile (make new-host NAME=... IP=... [GROUP=vpn|entry]),
# руками запускать не нужно.
set -euo pipefail

NAME="${1:?Укажите имя сервера}"
IP="${2:?Укажите адрес сервера}"
GROUP="${3:-vpn}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="$REPO/inventory/hosts.yaml"

case "$GROUP" in
  vpn) TEMPLATE="$REPO/host_vars/example-host/vars.yaml.example" ;;
  entry) TEMPLATE="$REPO/host_vars/example-entry/vars.yaml.example" ;;
  *) echo "GROUP может быть vpn или entry, а не '$GROUP'"; exit 1 ;;
esac

if ! [[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Имя сервера: латиница, цифры, дефис, подчёркивание"
  exit 1
fi

if [ -d "$REPO/host_vars/$NAME" ]; then
  echo "host_vars/$NAME уже существует"
  exit 1
fi

if [ ! -f "$INVENTORY" ]; then
  echo "Нет inventory/hosts.yaml — сначала выполните make init"
  exit 1
fi

if grep -qE "^ +$NAME:" "$INVENTORY"; then
  echo "Сервер $NAME уже есть в inventory/hosts.yaml"
  exit 1
fi

mkdir -p "$REPO/host_vars/$NAME"
cp "$TEMPLATE" "$REPO/host_vars/$NAME/vars.yaml"

# Запись дописывается в нужную группу прямо в текстовый файл, а не через
# разбор YAML: разбор потерял бы комментарии, которыми инвентарь и объясняется.
awk -v group="$GROUP" -v name="$NAME" -v ip="$IP" '
  $0 ~ "^    " group ":$" { in_group = 1 }
  in_group && $0 ~ "^      hosts:" {
    print "      hosts:"
    print "        " name ":"
    print "          ansible_host: \"" ip "\""
    in_group = 0
    next
  }
  { print }
' "$INVENTORY" > "$INVENTORY.tmp" && mv "$INVENTORY.tmp" "$INVENTORY"

cat <<EOF

Готово. Создан host_vars/$NAME/vars.yaml, сервер добавлен в inventory/hosts.yaml.

Дальше:
  1. Разложите публичный ключ keys/vpn-infra.pub в панели хостера при создании VPS
     (или впишите root-пароль в vault: make edit-secrets).
  2. make ping HOST=$NAME     — проверить связь
  3. make deploy HOST=$NAME   — развернуть

Нужны DNS-туннели, RustDesk или другой набор сервисов на этом сервере —
раскомментируйте нужное в host_vars/$NAME/vars.yaml.
EOF
