#!/usr/bin/env bash
# Разбор канала по пакетам: сколько запросов в секунду, какого размера ответы,
# через какие адреса реально приходит рекурсия. VPN должен быть ВКЛЮЧЁН.
# Скрипт сам создаёт нагрузку скачиванием с телефона.
#
# Что смотреть: доля ответов с данными. У DNS-туннеля большинство ответов вниз
# пустые (данные едут примерно в каждом пятом) — это нормально и объясняет потолок
# скорости. Сильный сдвиг в сторону пустых по сравнению с прошлым замером — повод
# перемерить резолверы, а не крутить настройки туннеля.
set -u
source "$(dirname "$0")/common.sh"
require_vpn_on

echo "=== запускаю скачивание на телефоне ==="
"$ADB" shell "curl -s -o /dev/null --max-time 60 \
  -w 'ТЕЛЕФОН: %{speed_download} Б/с за %{time_total} с\n' \
  http://$SRV:8088/512k.bin" < /dev/null > /tmp/phone_speed.txt 2>&1 &
PHONE_PID=$!

sleep 3
echo "=== снимаю пакеты 25 секунд под нагрузкой ==="
ssh_do "SRV=$SRV bash -s" <<'REMOTE'
timeout 25 tcpdump -ni any -l "udp port 53 and host $SRV" 2>/dev/null > /tmp/cap.txt
echo "пакетов: $(wc -l < /tmp/cap.txt)"
echo "ЗАПРОСЫ вверх:"
grep -E "> $SRV\.53:" /tmp/cap.txt | grep -oE "\([0-9]+\)$" | tr -d '()' \
  | awk '{s+=$1; n++} END {if(n) printf "  %d штук (%.1f/сек), средний %.0f Б\n", n, n/25, s/n}'
echo "ОТВЕТЫ вниз:"
grep -E "$SRV\.53 >" /tmp/cap.txt | grep -oE "\([0-9]+\)$" | tr -d '()' \
  | awk '{s+=$1; n++} END {if(n) printf "  %d штук (%.1f/сек), средний %.0f Б, итого %.1f КБ\n", n, n/25, s/n, s/1024}'
echo "размеры ответов (топ):"
grep -E "$SRV\.53 >" /tmp/cap.txt | grep -oE "\([0-9]+\)$" | tr -d '()' \
  | sort -n | uniq -c | sort -rn | head -6
echo "через какие адреса приходит рекурсия:"
grep -E "> $SRV\.53:" /tmp/cap.txt \
  | grep -oE "IP [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | sort | uniq -c | sort -rn | head -3
REMOTE

wait $PHONE_PID 2>/dev/null
echo
cat /tmp/phone_speed.txt
