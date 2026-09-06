#!/usr/bin/env bash
# Отбор резолверов: чья рекурсия реально доходит до нашего сервера.
# VPN должен быть ВЫКЛЮЧЕН, иначе меряем туннель, а не резолверы.
#
# Метод: собираем DNS-запрос к УНИКАЛЬНОМУ имени в своей зоне (уникальное — чтобы
# не попасть в кэш резолвера), шлём через nc, параллельно слушаем сервер.
# Ответ резолвера сам по себе ничего не значит — он может ответить отказом.
# Значение имеет только одно: пришёл ли запрос к нам.
set -u
source "$(dirname "$0")/common.sh"
require_vpn_off

RESOLVERS="${*:-95.153.131.2 95.153.135.2 213.87.0.1 213.87.74.5 213.87.74.21 77.88.8.8}"

echo "=== запись на сервере ==="
ssh_do "pkill tcpdump 2>/dev/null; nohup timeout 200 tcpdump -ni any -l \
  'udp port 53 and dst host $SRV' > /tmp/race.txt 2>/dev/null & echo ok"
sleep 2

python3 - <<PY
import struct, os
os.makedirs('/tmp/dnsprobes', exist_ok=True)
res = "$RESOLVERS".split()
def q(name, qid):
    h = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 1)
    n = b"".join(bytes([len(p)])+p.encode() for p in name.split("."))+b"\x00"
    return h + n + struct.pack(">HH",1,1) + b"\x00" + struct.pack(">HHIH",41,4096,0,0)
for i in range(1, len(res)+1):
    for r in range(1, 6):
        tag = "wq%02d%d" % (i, r)
        open('/tmp/dnsprobes/%s.bin' % tag,'wb').write(q("%s.$DOMAIN" % tag, 0x4000+i*7+r))
print("проб: %d" % (len(res)*5))
PY
"$ADB" push /tmp/dnsprobes /data/local/tmp/ < /dev/null 2>&1 | tail -1

echo
echo "=== опрос (5 проб на резолвер) ==="
i=0
for ip in $RESOLVERS; do
  i=$((i+1)); ii=$(printf "%02d" $i)
  out=$("$ADB" shell "cd /data/local/tmp/dnsprobes; ok=0; for r in 1 2 3 4 5; do \
    n=\$(timeout 3 nc -u -w 2 $ip 53 < wq${ii}\$r.bin 2>/dev/null | wc -c); \
    [ \"\$n\" -gt 0 ] && ok=\$((ok+1)); done; echo \$ok" < /dev/null 2>/dev/null | tr -d '\r')
  printf "%-16s отвечает %s/5\n" "$ip" "${out:-0}"
done

echo
echo "=== ждём рекурсию 25 сек ==="
sleep 25
ssh_do "grep -oE 'wq[0-9]{3}' /tmp/race.txt | cut -c3-4 | sort | uniq -c" > /tmp/race_result.txt
echo "=== рекурсия дошла до сервера ==="
i=0
for ip in $RESOLVERS; do
  i=$((i+1)); ii=$(printf "%02d" $i)
  cnt=$(grep -E " $ii\$" /tmp/race_result.txt | awk '{print $1}')
  printf "  %-16s %s/5\n" "$ip" "${cnt:-0}"
done

echo
echo "Годные — те, у кого рекурсия доходит. Дальше их надо замерить по скорости:"
echo "вписать резолвер в приложение, подключить VPN, запустить phone-bench.sh"
