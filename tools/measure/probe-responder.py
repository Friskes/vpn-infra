#!/usr/bin/env python3
"""Временный ответчик для проверки нового адреса: HTTP на 80/tcp и DNS на 53/udp.

    scp probe-responder.py root@203.0.113.10:/root/
    ssh root@203.0.113.10 'setsid nohup python3 /root/probe-responder.py >/dev/null 2>&1 < /dev/null &'

Ставится на свежий сервер до `make deploy`, сам гаснет через --minutes (по умолчанию 60).
Пока он работает:
  - ru-reach.py --port 80 --udp <IP> проверяет TCP с данными и UDP из домашних сетей РФ;
  - http://<IP> с телефона (VPN выключен) показывает строку «OK <IP> <время>» — значит,
    твой провайдер данные до адреса пропускает.

Слушает только публичный адрес, поэтому не мешает systemd-resolved на 127.0.0.53.
На развёрнутом сервере 80 и 53 закрыты ufw, а 53/udp может быть занят Slipstream —
там ответчик не нужен. Лог обращений — /root/probe-responder.log.
"""
import argparse
import http.server
import socket
import socketserver
import struct
import threading
import time


def public_ip():
    """Адрес интерфейса, через который сервер ходит наружу (пакет никуда не уходит)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect(("1.1.1.1", 53))
        return s.getsockname()[0]


def serve_dns(ip, port, log):
    """На любой A-запрос отвечает 192.0.2.1 — этот адрес и ищет проверка UDP."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((ip, port))
    answer = socket.inet_aton("192.0.2.1")
    while True:
        data, addr = s.recvfrom(2048)
        if len(data) < 12:
            continue
        end = 12
        while end < len(data) and data[end] != 0:
            end += data[end] + 1
        header = struct.pack(">HHHHHH", struct.unpack(">H", data[:2])[0], 0x8180, 1, 1, 0, 0)
        record = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + answer
        s.sendto(header + data[12:end + 5] + record, addr)
        log(f"DNS {addr[0]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ip", default=None, help="на каком адресе слушать (по умолчанию публичный)")
    ap.add_argument("--http-port", type=int, default=80)
    ap.add_argument("--dns-port", type=int, default=53)
    ap.add_argument("--minutes", type=int, default=60)
    args = ap.parse_args()
    ip = args.ip or public_ip()
    logfile = open("/root/probe-responder.log", "a", buffering=1)

    def log(msg):
        logfile.write(f"{time.strftime('%H:%M:%S')} {msg}\n")

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = f"OK {ip} {time.strftime('%H:%M:%S')}\n".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            log(f"HTTP {self.client_address[0]} {self.path}")

        def log_message(self, *_):
            pass

    threading.Thread(target=serve_dns, args=(ip, args.dns_port, log), daemon=True).start()
    socketserver.TCPServer.allow_reuse_address = True
    srv = socketserver.ThreadingTCPServer((ip, args.http_port), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log(f"start on {ip}, http {args.http_port}, dns {args.dns_port}, {args.minutes} min")
    time.sleep(args.minutes * 60)


if __name__ == "__main__":
    main()
