#!/usr/bin/env python3
"""Сколько на самом деле даёт туннель — замер с телефона, через сам туннель.

    python tunnel-speed.py              три прогона по 8 секунд, берём лучший
    python tunnel-speed.py --runs 1     один быстрый прогон
    python tunnel-speed.py --json       машинный вывод

Зачем это нужно. Отбор резолверов умеет сам SlipNet («Scan for Working
Resolvers»): у него 60 тысяч адресов, проверка DPI, NXDOMAIN, размера EDNS и
тест соединения через туннель. Чего он не показывает — сколько килобайт в
секунду резолвер реально вытягивает. А разница огромна: резолвер, прошедший все
проверки приложения, давал 25 КБ/с там, где другой давал 170.

Скрипт качает файл через локальный SOCKS, который поднимает приложение, то есть
меряет ровно тот путь, которым ходит весь трафик телефона. Порядок работы:
поставить кандидата в профиль, переподключить VPN, запустить этот замер,
повторить для следующего.
"""
import argparse
import json
import socket
import struct
import sys
import time

DEFAULT_URL = "http://cachefly.cachefly.net/10mb.test"
IP_URL = "http://api.ipify.org"


def socks_connect(socks_host, socks_port, host, port, timeout=60, auth=None):
    """Открывает соединение до host:port через локальный SOCKS5 приложения.

    Таймаут щедрый намеренно: на еле живом канале рукопожатие через туннель
    занимает десятки секунд, и жёсткие 20 с давали «не отвечает» там, где
    туннель на самом деле работал.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect((socks_host, socks_port))
    methods = b"\x00\x02" if auth else b"\x00"
    sock.sendall(bytes([5, len(methods)]) + methods)
    greeting = sock.recv(2)
    method = greeting[1] if len(greeting) > 1 else 0xFF
    if method == 2:
        if not auth:
            sock.close()
            raise OSError("локальный SOCKS требует логин — передайте --socks-user и --socks-pass")
        user, password = auth
        sock.sendall(b"\x01" + bytes([len(user)]) + user.encode()
                     + bytes([len(password)]) + password.encode())
        if sock.recv(2)[1:2] != b"\x00":
            sock.close()
            raise OSError("локальный SOCKS не принял логин")
    elif method != 0:
        sock.close()
        raise OSError("локальный SOCKS требует неизвестный способ входа")
    sock.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host.encode() + struct.pack(">H", port))
    reply = sock.recv(10)
    if len(reply) < 2 or reply[1] != 0:
        sock.close()
        raise OSError("SOCKS не смог соединиться с %s" % host)
    return sock


def split_url(url):
    if not url.startswith("http://"):
        raise ValueError("нужен http:// — https через SOCKS для замера не нужен")
    host, _, path = url[7:].partition("/")
    host, _, port = host.partition(":")
    return host, int(port or 80), "/" + path


def http_get(sock, host, path):
    # User-Agent обязателен: без него часть CDN отдаёт заголовки и рвёт соединение,
    # и замер показывает сотни байт вместо потока.
    sock.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\n"
                  "User-Agent: curl/8\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                  % (path, host)).encode())


def measure(socks_host, socks_port, url, seconds, auth=None):
    """Один прогон: качаем и считаем байты тела за отведённое время."""
    host, port, path = split_url(url)
    sock = socks_connect(socks_host, socks_port, host, port, auth=auth)
    try:
        http_get(sock, host, path)
        start, total, head = time.monotonic(), 0, b""
        while time.monotonic() - start < seconds:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            if head is not None:          # заголовки в счёт не идут
                head += chunk
                sep = head.find(b"\r\n\r\n")
                if sep >= 0:
                    total += len(head) - sep - 4
                    head = None
                continue
            total += len(chunk)
        elapsed = max(time.monotonic() - start, 0.001)
        return {"bytes": total, "seconds": round(elapsed, 1), "speed": total / elapsed}
    finally:
        sock.close()


def external_ip(socks_host, socks_port, auth=None):
    """Куда мир видит наш адрес — проверка, что трафик правда идёт через сервер."""
    host, port, path = split_url(IP_URL)
    try:
        sock = socks_connect(socks_host, socks_port, host, port, auth=auth)
    except OSError:
        return None
    try:
        http_get(sock, host, path)
        data = b""
        while len(data) < 4096:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        body = data.split(b"\r\n\r\n", 1)[-1].strip()
        return body.decode(errors="replace") or None
    except OSError:
        return None
    finally:
        sock.close()


def main():
    ap = argparse.ArgumentParser(description="Замер реальной скорости DNS-туннеля")
    # SlipNet поднимает локальный SOCKS на 10880 (адрес виден в настройках приложения),
    # а 1080 в профиле — это порт SOCKS уже на сервере, за туннелем.
    ap.add_argument("--socks-port", type=int, default=10880, help="порт локального SOCKS")
    ap.add_argument("--socks-host", default="127.0.0.1")
    ap.add_argument("--url", default=DEFAULT_URL, help="что качать")
    ap.add_argument("--seconds", type=float, default=8.0, help="длительность одного прогона")
    # Первый прогон всегда занижен: канал разгоняется около минуты, поэтому берём лучший.
    ap.add_argument("--runs", type=int, default=3, help="сколько прогонов сделать")
    ap.add_argument("--expect-ip", default=None, help="адрес сервера — сверить, что трафик идёт через него")
    # У профилей dnstt локальный SOCKS просит логин — тот же, что и SOCKS на сервере.
    ap.add_argument("--socks-user", default=None, help="логин локального SOCKS, если он его просит")
    ap.add_argument("--socks-pass", default=None, help="пароль локального SOCKS")
    ap.add_argument("--json", action="store_true", help="машинный вывод")
    args = ap.parse_args()
    auth = (args.socks_user, args.socks_pass) if args.socks_user else None

    ip = external_ip(args.socks_host, args.socks_port, auth)
    if ip is None and not args.json:
        print("Локальный SOCKS %s:%d не отвечает. VPN включён?" % (args.socks_host, args.socks_port))
        return 1

    runs = []
    for i in range(args.runs):
        try:
            r = measure(args.socks_host, args.socks_port, args.url, args.seconds, auth)
        except (OSError, ValueError) as exc:
            if args.json:
                json.dump({"error": str(exc)}, sys.stdout, ensure_ascii=False, indent=2)
                print()
            else:
                print("Прогон %d не удался: %s" % (i + 1, exc))
            return 1
        runs.append(r)
        if not args.json:
            print("  прогон %d: %6.1f КБ/с (%d Б за %s с)"
                  % (i + 1, r["speed"] / 1024, r["bytes"], r["seconds"]))

    best = max(runs, key=lambda r: r["speed"]) if runs else None

    if args.json:
        json.dump({"external_ip": ip, "runs": runs,
                   "best_speed": best["speed"] if best else 0},
                  sys.stdout, ensure_ascii=False, indent=2)
        print()
        return 0

    print()
    if best:
        print("Через туннель: %.1f КБ/с (лучший из %d)" % (best["speed"] / 1024, len(runs)))
    if ip:
        if args.expect_ip and ip != args.expect_ip:
            print("ВНИМАНИЕ: наружу мы выходим с %s, а ждали %s — трафик идёт мимо туннеля." % (ip, args.expect_ip))
        else:
            print("Наружу выходим с %s." % ip)
    print("Смените резолвер, переподключите VPN и повторите — сравнивать надо эти цифры,")
    print("а не оценки сканера: резолвер может пройти все проверки и всё равно быть втрое медленнее.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nпрервано")
