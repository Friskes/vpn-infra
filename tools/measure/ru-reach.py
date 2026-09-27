#!/usr/bin/env python3
"""Доходят ли данные до адресов из домашних сетей России — проверка до оплаты и деплоя.

    python3 ru-reach.py 203.0.113.10 203.0.113.11     SSH-баннер с 22/tcp: домашние сети РФ + контроль из DE
    python3 ru-reach.py --fast 203.0.113.10 ...        быстрый отсев: только TCP-соединение с узлов check-host в РФ
    python3 ru-reach.py --port 80 --udp 203.0.113.10   HTTP на 80/tcp и DNS на 53/udp (на сервере probe-responder.py)

Почему не `nc -vz`. При «мягкой» блокировке ТСПУ TCP-рукопожатие проходит, а данные
молча выбрасываются — `nc -vz` пишет succeeded про адрес, который не работает.
Скрипт засчитывает адрес, только если пришёл ответ сервера: HTTP-статус или любой
не-HTTP ответ (SSH-баннер). Итог по пробе: data — данные пришли, soft — соединение
есть, данных нет, drop — нет даже соединения.

Все адреса проверяются с одного и того же набора проб: первый замер выбирает пробы,
остальные ссылаются на его id. Иначе разные провайдеры в разных замерах дают
несравнимые цифры. Анонимный лимит Globalping — 250 замеров в час с одного IP;
адрес стоит один замер плюс один на --udp и один на контроль.
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request

GP = "https://api.globalping.io/v1"
CHECK_HOST = "https://check-host.net"
CHECK_HOST_NODES = ["ru1", "ru2", "ru3"]
UA = {"User-Agent": "vpn-infra-ru-reach", "Accept": "application/json"}


def http_json(url, body=None, timeout=30):
    """GET или POST с JSON; ответ сервера с ошибкой тоже разбирается, чтобы показать причину."""
    data = json.dumps(body).encode() if body is not None else None
    headers = dict(UA, **({"Content-Type": "application/json"} if data else {}))
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:
        raise SystemExit(f"{url} -> {err.code}: {err.read().decode(errors='replace')[:300]}")


def gp_start(body):
    return http_json(f"{GP}/measurements", body)["id"]


def gp_wait(mid, timeout=90):
    deadline = time.time() + timeout
    while True:
        res = http_json(f"{GP}/measurements/{mid}")
        if res["status"] != "in-progress" or time.time() > deadline:
            return res
        time.sleep(3)


def classify_tcp(result):
    """data / soft / drop по одному результату http-замера Globalping."""
    raw = result.get("rawOutput") or ""
    if result.get("status") == "finished" or any(s in raw for s in ("Expected HTTP", "Parse Error", "HPE_")):
        return "data"
    if "first response byte" in raw or "TLS" in raw:
        return "soft"
    return "drop"


def probe_name(probe):
    return f"{probe['network'].split()[0]}/{probe['city']}"


def run_globalping(ips, port, udp, limit):
    per_ip = 1 + (1 if udp else 0) + 1
    left = http_json(f"{GP}/limits")["rateLimit"]["measurements"]["create"]["remaining"]
    if left < per_ip * len(ips):
        sys.exit(f"Лимит Globalping: осталось {left} замеров, нужно {per_ip * len(ips)}. Сброс — раз в час.")

    tcp_opts = {"protocol": "HTTP", "port": port, "request": {"method": "GET", "path": "/"}}
    first = None
    jobs = []
    for ip in ips:
        where = first or [{"magic": "RU+eyeball-network", "limit": limit}]
        tcp_id = gp_start({"type": "http", "target": ip, "locations": where, "measurementOptions": tcp_opts})
        if first is None:
            first = tcp_id
            time.sleep(3)
        udp_id = None
        if udp:
            udp_id = gp_start({"type": "dns", "target": "probe.example.com", "locations": first,
                               "measurementOptions": {"resolver": ip, "protocol": "UDP", "port": 53,
                                                      "query": {"type": "A"}}})
        de_id = gp_start({"type": "http", "target": ip, "locations": [{"magic": "DE", "limit": 2}],
                          "measurementOptions": tcp_opts})
        jobs.append((ip, tcp_id, udp_id, de_id))

    print(f"Пробы: https://api.globalping.io/v1/measurements/{first}")
    for ip, tcp_id, udp_id, de_id in jobs:
        tcp = gp_wait(tcp_id)["results"]
        kinds = [classify_tcp(r["result"]) for r in tcp]
        line = (f"{ip:16} RU data {kinds.count('data'):2}/{len(kinds)}"
                f"  soft {kinds.count('soft'):2}  drop {kinds.count('drop'):2}")
        ok = kinds.count("data") >= 0.9 * len(kinds)
        if udp_id:
            udp_res = gp_wait(udp_id)["results"]
            udp_ok = sum(r["result"].get("status") == "finished" for r in udp_res)
            line += f"  UDP {udp_ok:2}/{len(udp_res)}"
            ok = ok and udp_ok >= 0.9 * len(udp_res)
        de = [classify_tcp(r["result"]) for r in gp_wait(de_id)["results"]]
        line += f"  DE {de.count('data')}/{len(de)}  {'PASS' if ok else 'fail'}"
        bad = [probe_name(r["probe"]) for r, k in zip(tcp, kinds) if k != "data"]
        print(line + (f"  не прошли: {', '.join(bad)}" if bad and not ok else ""))


def run_check_host(ips, port):
    """Быстрый отсев полной блокировки: TCP-соединение с узлов check-host в РФ.

    Узлы стоят в дата-центрах, мягкую блокировку и ограничения домашних провайдеров
    они не видят — прошедшие адреса дальше проверять через Globalping.
    """
    nodes = "&".join(f"node={n}.node.check-host.net" for n in CHECK_HOST_NODES)
    ids = {}
    for ip in ips:
        ids[ip] = http_json(f"{CHECK_HOST}/check-tcp?host={ip}:{port}&{nodes}")["request_id"]
        time.sleep(0.7)
    time.sleep(15)
    for ip, rid in ids.items():
        res = http_json(f"{CHECK_HOST}/check-result/{rid}")
        cells = []
        for node in CHECK_HOST_NODES:
            val = res.get(f"{node}.node.check-host.net")
            cells.append("?" if val is None else "ok" if val and val[0] and val[0].get("time") else "X")
        verdict = "PASS" if cells.count("ok") == len(cells) else "fail"
        print(f"{ip:16} {' '.join(f'{n}={c}' for n, c in zip(CHECK_HOST_NODES, cells))}  {verdict}"
              f"  {CHECK_HOST}/check-report/{rid}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("ips", nargs="+")
    ap.add_argument("--port", type=int, default=22, help="TCP-порт с отвечающим сервисом (22 — SSH-баннер)")
    ap.add_argument("--udp", action="store_true", help="плюс DNS-запрос на 53/udp — нужен probe-responder.py")
    ap.add_argument("--limit", type=int, default=12, help="сколько домашних проб РФ (Globalping)")
    ap.add_argument("--fast", action="store_true", help="только TCP-соединение с узлов check-host")
    args = ap.parse_args()
    if args.fast:
        run_check_host(args.ips, args.port)
    else:
        run_globalping(args.ips, args.port, args.udp, args.limit)


if __name__ == "__main__":
    main()
