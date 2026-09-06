#!/system/bin/sh
# Снимок режима фильтрации мобильного интернета: включены ли сейчас белые списки
# и что через них проходит. Запускается НА ТЕЛЕФОНЕ:
#   adb push operator-probe.sh /data/local/tmp/ && adb shell "V=<IP сервера> sh /data/local/tmp/operator-probe.sh"
#
# Wi-Fi на телефоне выключить: иначе замерим домашний провод (см. wifi_on в шапке).
# На сервере для пунктов 4-5 нужен эхо-ответчик на 443/tcp и 443/udp, иначе
# «тишина» будет означать «никто не слушает», а не «фильтр режет».
V="${V:-}"
[ -z "$V" ] && echo "Задайте адрес сервера: V=<IP> sh $0" && exit 1
T=6
DNSQ='\xaa\xaa\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x02ya\x02ru\x00\x00\x01\x00\x01'

# timeout обязателен: nc на Android без него вешает скрипт намертво.
udp_probe() {  # $1=ip $2=port $3=payload
  n=$(printf "$3" | timeout 6 nc -u -w 3 "$1" "$2" 2>/dev/null | wc -c)
  [ -z "$n" ] && n=0
  echo "$n"
}

echo "================ ЗАМЕР $(date '+%Y-%m-%d %H:%M:%S') ================"
echo "оператор: $(getprop gsm.operator.alpha) | сеть: $(getprop gsm.network.type)"
echo "wifi_on: $(settings get global wifi_on)  (1 = ВКЛЮЧЁН, замер испорчен!)"
echo "маршрут: $(ip route get 8.8.8.8 2>/dev/null | head -1)"

echo
echo "--- 1. БЕЛЫЕ ресурсы, TCP 443 ---"
for h in gosuslugi.ru ya.ru vk.com; do
  echo "$h -> $(timeout 10 curl -s -o /dev/null -w '%{http_code} за %{time_total}s' --max-time $T https://$h 2>&1 || echo FAIL)"
done

echo
echo "--- 2. НЕбелые ресурсы, TCP 443 (если работают — белых списков нет) ---"
for h in 2ip.ru example.com; do
  echo "$h -> $(timeout 10 curl -s -o /dev/null -w '%{http_code} за %{time_total}s' --max-time $T https://$h 2>&1 || echo FAIL)"
done

echo
echo "--- 3. ICMP: наш VPS против белого адреса ---"
echo "наш VPS:  $(ping -c 3 -W 3 $V 2>&1 | grep -E 'packet loss' || echo 'нет ответа')"
echo "Яндекс:   $(ping -c 3 -W 3 77.88.8.8 2>&1 | grep -E 'packet loss' || echo 'нет ответа')"

echo
echo "--- 4. TCP до нашего VPS (на 443 нужен эхо-ответчик) ---"
for p in 443 22; do
  r=$(echo | timeout 8 nc -w 5 $V $p 2>/dev/null | head -c 40)
  if [ -n "$r" ]; then echo "порт $p -> ОТВЕТИЛ: $r"
  else echo "порт $p -> тишина"; fi
done

echo
echo "--- 5. ГЛАВНЫЙ ТЕСТ: UDP ---"
echo "UDP к белому (77.88.8.8:53):    $(udp_probe 77.88.8.8 53 "$DNSQ") байт"
echo "UDP к НСДИ (195.208.4.1:53):    $(udp_probe 195.208.4.1 53 "$DNSQ") байт"
echo "UDP к Google (8.8.8.8:53):      $(udp_probe 8.8.8.8 53 "$DNSQ") байт"
echo "UDP к нашему VPS (443, эхо):    $(udp_probe $V 443 'probe\n') байт"
echo "(>0 байт = UDP до этого адреса проходит. Пробу в порт с реальным сервисом"
echo " вместо эхо-ответчика не считать: 0 байт там ничего не доказывает.)"

# raw-сокеты в shell запрещены, поэтому маршрут щупаем пингом с растущим TTL:
# на каком хопе обрывается — там и режут.
hops() {
  for t in 1 2 3 4 5 6 7 8; do
    o=$(timeout 5 ping -c 1 -t $t -W 2 "$1" 2>&1)
    ip=$(echo "$o" | grep -oE 'From [0-9.]+' | head -1 | cut -d' ' -f2)
    [ -z "$ip" ] && ip=$(echo "$o" | grep -oE 'from [0-9.]+' | head -1 | cut -d' ' -f2)
    if echo "$o" | grep -q 'bytes from'; then
      echo "  ttl $t: ДОШЛИ до $1"; break
    elif [ -n "$ip" ]; then
      echo "  ttl $t: $ip"
    else
      echo "  ttl $t: молчит"
    fi
  done
}

echo
echo "--- 6. путь до нашего VPS ---"
hops $V

echo
echo "--- 7. путь до белого адреса ---"
hops 77.88.8.8

echo
echo "================ КОНЕЦ ================"
