#!/usr/bin/env bash
# Замер скорости и задержки туннеля с телефона. VPN должен быть ВКЛЮЧЁН.
# Канал разгоняется около минуты — судить по лучшему из трёх прогонов.
#
# Приложение SlipNet исключает адрес сервера из туннеля (защита от петли),
# поэтому раздача на самом сервере через него недоступна: мерить внешним файлом
# (http://cachefly.cachefly.net/1mb.test) либо с клиента, который так не делает.
set -u
source "$(dirname "$0")/common.sh"
require_vpn_on

URL="${URL:-http://$SRV:8088}"

echo "=== задержка (мелкий файл, 3 раза) ==="
"$ADB" shell "for i in 1 2 3; do curl -s -o /dev/null --max-time 40 \
  -w '  ответ за %{time_total} с\n' $URL/ping.txt; done" < /dev/null

echo
echo "=== скорость (512 КБ, 3 прогона) ==="
"$ADB" shell "for i in 1 2 3; do curl -s -o /dev/null --max-time 120 \
  -w '  %{speed_download} Б/с | скачано %{size_download} | TTFB %{time_starttransfer} с | всего %{time_total} с\n' \
  $URL/512k.bin; done" < /dev/null
