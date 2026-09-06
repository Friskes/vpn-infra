#!/system/bin/sh
# Карта портов до своего VPS под белыми списками + проверка идеи «прикинуться
# белым сайтом по SNI». Запускается НА ТЕЛЕФОНЕ:
#   adb push operator-ports.sh /data/local/tmp/ && adb shell "V=<IP сервера> sh /data/local/tmp/operator-ports.sh"
#
# На проверяемых портах сервера нужен эхо-ответчик, иначе «тишина» неотличима
# от «никто не слушает».
V="${V:-}"
[ -z "$V" ] && echo "Задайте адрес сервера: V=<IP> sh $0" && exit 1

echo "======== КАРТА ПОРТОВ $(date '+%H:%M:%S') ========"
echo "оператор: $(getprop gsm.operator.alpha) | wifi: $(settings get global wifi_on)"

echo
echo "--- TCP до $V ---"
for p in 80 443 2222 8080 8443 22 51820; do
  r=$(echo | timeout 8 nc -w 5 $V $p 2>/dev/null | head -c 30)
  if [ -n "$r" ]; then echo "  tcp/$p -> $r"; else echo "  tcp/$p -> тишина"; fi
done

echo
echo "--- UDP до $V ---"
for p in 80 443 123 500 1194 4500 8443; do
  n=$(printf 'probe\n' | timeout 6 nc -u -w 3 $V $p 2>/dev/null | head -c 30)
  if [ -n "$n" ]; then echo "  udp/$p -> $n"; else echo "  udp/$p -> тишина"; fi
done

echo
echo "--- TLS с разными SNI на наш IP (порт 443) ---"
for s in ya.ru gosuslugi.ru 2ip.ru example.com; do
  c=$(timeout 10 curl -s -o /dev/null -w '%{http_code}' --max-time 7 \
      --resolve "$s:443:$V" "https://$s" 2>&1)
  echo "  SNI=$s -> $c"
done

echo
echo "--- контроль: TLS к настоящим сайтам ---"
for s in ya.ru 2ip.ru; do
  echo "  $s -> $(timeout 10 curl -s -o /dev/null -w '%{http_code}' --max-time 7 https://$s 2>&1)"
done
echo "======== КОНЕЦ ========"
