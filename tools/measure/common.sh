#!/usr/bin/env bash
# Общая обвязка для замеров канала. Подключается остальными скриптами:
#   source "$(dirname "$0")/common.sh"
#
# Адрес сервера и домен туннеля берутся из репозитория, а не дублируются здесь:
# при заведении нового сервера править нужно только inventory и host_vars.
# Переопределить разово: SRV=203.0.113.10 DOMAIN=t2.example.com ./скрипт.sh

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Без HOST= берём первый сервер из инвентаря: у большинства он там один,
# и заставлять вспоминать его имя ради каждого замера незачем.
HOST="${HOST:-$(grep -oP '^        \K[a-zA-Z0-9_-]+(?=:$)' \
  "$REPO/inventory/hosts.yaml" 2>/dev/null | head -1)}"
if [ -z "$HOST" ]; then
  echo "В inventory/hosts.yaml нет ни одного сервера. Заведите: make new-host"
  exit 1
fi

SRV="${SRV:-$(grep -A1 "^        ${HOST}:" "$REPO/inventory/hosts.yaml" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)}"
DOMAIN="${DOMAIN:-$(grep -oP '^slipstream_domain:\s*"\K[^"]+' \
  "$REPO/host_vars/$HOST/vars.yaml" 2>/dev/null)}"
if [ -z "$SRV" ]; then
  echo "Не удалось определить адрес сервера. Задайте: SRV=<IP> $0"
  exit 1
fi

ADB="${ADB:-adb}"
command -v "$ADB" >/dev/null 2>&1 || {
  echo "Нет adb в PATH. Поставьте platform-tools или задайте ADB=<путь к adb>."
  exit 1
}

# Ходим по ключу, а не по паролю из vault: пароль иначе оседает в окружении
# процесса и в истории, а ключ на сервере и так единственный способ входа.
ssh_do() {
  ssh -i "$REPO/keys/vpn-infra" -o ConnectTimeout=40 "root@$SRV" "$1" 2>/dev/null
}

# Самая частая и самая незаметная ошибка замера — мерить туннель через него же.
require_vpn_on() {
  "$ADB" shell 'ip route get 8.8.8.8 2>/dev/null | head -1' < /dev/null | grep -q tun || {
    echo "ОСТАНОВКА: VPN на телефоне выключен, мерить нечего."
    exit 1
  }
}

require_vpn_off() {
  if "$ADB" shell 'ip route get 8.8.8.8 2>/dev/null | head -1' < /dev/null | grep -q tun; then
    echo "ОСТАНОВКА: VPN на телефоне включён, замер будет неверным."
    exit 1
  fi
}
