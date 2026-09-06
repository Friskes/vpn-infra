#!/system/bin/sh
# Режут ли трафик по СИГНАТУРЕ пакета, а не по адресу. Запускается НА ТЕЛЕФОНЕ:
#   adb push operator-signature.sh /data/local/tmp/ && adb shell "V=<IP сервера> sh /data/local/tmp/operator-signature.sh"
#
# На указанных портах сервера нужен эхо-ответчик. Шлём в каждый по два пакета:
# безобидный текст и точную копию заголовка WireGuard handshake initiation
# (тип 0x01, три нулевых байта, всего 148 байт). Обычный прошёл, wg-подобный нет —
# значит фильтр смотрит на содержимое.
V="${V:-}"
[ -z "$V" ] && echo "Задайте адрес сервера: V=<IP> sh $0" && exit 1

echo "======== ТЕСТ СИГНАТУРЫ $(date '+%H:%M:%S') ========"
echo "оператор: $(getprop gsm.operator.alpha)"

for p in 1194 4500 500 443; do
  a=$(printf 'probe\n' | timeout 6 nc -u -w 3 $V $p 2>/dev/null | head -c 20)
  b=$( (printf '\x01\x00\x00\x00'; head -c 144 /dev/zero) | timeout 6 nc -u -w 3 $V $p 2>/dev/null | head -c 20)
  echo "udp/$p: обычный='${a:-тишина}'  wg-подобный='${b:-тишина}'"
done

echo
echo "--- то же на реальный порт WireGuard (там сам wg-easy, ответа не ждём) ---"
(printf '\x01\x00\x00\x00'; head -c 144 /dev/zero) | timeout 5 nc -u -w 2 $V 51820 >/dev/null 2>&1
echo "пакет отправлен, смотрим счётчики на сервере"
echo "======== КОНЕЦ ========"
