#!/usr/bin/env bash
# Поднимает на сервере раздачу тестовых файлов. Мерить надо по своему файлу,
# а не по внешним сайтам: иначе меряешь чужую загрузку, а не свой канал.
# Порт 8088 наружу не открыт — доступен только изнутри туннеля.
set -u
source "$(dirname "$0")/common.sh"

ssh_do "SRV=$SRV bash -s" <<'REMOTE'
set +e
mkdir -p /opt/speedfiles && cd /opt/speedfiles
[ -f 512k.bin ] || head -c 524288 /dev/urandom > 512k.bin
[ -f 1m.bin ]   || head -c 1048576 /dev/urandom > 1m.bin
echo ok > ping.txt

systemctl stop speedsrv 2>/dev/null
# --collect: юнит исчезает после остановки, перезапуск не требует ручной чистки.
systemd-run --unit=speedsrv --collect --working-directory=/opt/speedfiles \
  /usr/bin/python3 -m http.server 8088 --bind 0.0.0.0 >/dev/null 2>&1
sleep 2
echo -n "раздача: "; systemctl is-active speedsrv
ufw allow in on lo >/dev/null 2>&1
curl -s -o /dev/null -w "проверка с сервера: %{speed_download} Б/с\n" "http://$SRV:8088/1m.bin"
REMOTE

echo
echo "Погасить после замеров: systemctl stop speedsrv"
