#!/usr/bin/env python3
"""Перебор адресов HostVDS через OpenStack API: создать пачку серверов, отсеять заблокированные.

    export OS_USERNAME=hostvds-... OS_PASSWORD=...     # панель HostVDS → раздел API
    python3 tools/hostvds.py list                      серверы во всех регионах Европы
    python3 tools/hostvds.py create eu-west1 --count 8 серверы probe-* в сетях, где наших ещё нет; печатает IP
    python3 tools/hostvds.py delete-probes --keep IP   удалить все probe-*, кроме оставленных
    python3 tools/hostvds.py rename IP vpn-ams         дать победителю постоянное имя
    python3 tools/hostvds.py resize IP hostvds-2       сменить тариф, IP сохраняется

Зачем API, а не панель. Панель раздаёт адреса из нескольких подсетей, и в сентябре 2026
почти все они были заблокированы из РФ. Через API доступны все сети регионов, включая
регионы, которые панель считает недоступными, и сети Unlisted-*: там нашлись чистые
адреса. Сети RESERVE-* идут в конец — их адреса не отвечали снаружи вовсе.
Порядок перебора — в HOSTING.md.

Серверы создаются с ключом keys/vpn-infra.pub и группой безопасности allow_all:
группа default пропускает только трафик между своими серверами, и сервер без allow_all
не отвечает никому снаружи — его легко принять за заблокированный.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

AUTH_URL = os.environ.get("OS_AUTH_URL", "https://os-api.hostvds.com/identity/v3")
REPO = Path(__file__).resolve().parent.parent
PUBKEY = REPO / "keys" / "vpn-infra.pub"
KEY_NAME = "vpn-infra"
SG_NAME = "allow_all"
IMAGE_NAME = "Ubuntu-24.04-amd64"
PROBE_PREFIX = "probe-"


class Api:
    """Токен проекта и адреса сервисов по регионам из каталога Keystone."""

    def __init__(self):
        user, password = os.environ.get("OS_USERNAME"), os.environ.get("OS_PASSWORD")
        if not user or not password:
            sys.exit("Задайте OS_USERNAME и OS_PASSWORD (панель HostVDS → API).")
        ident = {"methods": ["password"],
                 "password": {"user": {"name": user, "domain": {"name": "Default"}, "password": password}}}
        self.token, _ = self._auth({"identity": ident})
        project = self.call("GET", f"{AUTH_URL}/auth/projects")["projects"][0]["id"]
        self.token, body = self._auth({"identity": ident, "scope": {"project": {"id": project}}})
        self.endpoints = {}
        for svc in body["token"]["catalog"]:
            for ep in svc["endpoints"]:
                if ep["interface"] == "public":
                    self.endpoints[(svc["type"], ep["region"])] = ep["url"].rstrip("/")

    @staticmethod
    def _auth(auth):
        req = urllib.request.Request(f"{AUTH_URL}/auth/tokens", data=json.dumps({"auth": auth}).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.headers["X-Subject-Token"], json.load(resp)

    def call(self, method, url, body=None):
        """Запрос к API; GET повторяется на 5xx — шлюз HostVDS периодически отвечает 504."""
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(4):
            req = urllib.request.Request(url, data=data, method=method, headers={
                "X-Auth-Token": self.token, "Content-Type": "application/json",
                "OpenStack-API-Version": "compute 2.47"})
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as err:
                if err.code >= 500 and method == "GET" and attempt < 3:
                    time.sleep(5)
                    continue
                raise SystemExit(f"{method} {url} -> {err.code}: {err.read().decode(errors='replace')[:300]}")

    def regions(self):
        return sorted(r for t, r in self.endpoints if t == "compute" and r.startswith("eu-"))

    def nova(self, region):
        return self.endpoints[("compute", region)]

    def neutron(self, region):
        return self.endpoints[("network", region)] + "/v2.0"

    def servers(self, region):
        return self.call("GET", f"{self.nova(region)}/servers/detail")["servers"]


def ipv4(server):
    for addrs in server.get("addresses", {}).values():
        for a in addrs:
            if a.get("version") == 4:
                return a["addr"]
    return ""


def all_servers(api):
    return [(region, s) for region in api.regions() for s in api.servers(region)]


def find(api, ip):
    for region, s in all_servers(api):
        if ipv4(s) == ip:
            return region, s
    sys.exit(f"Сервер с адресом {ip} не найден")


def cmd_list(api, _args):
    for region, s in all_servers(api):
        print(f"{region:11} {s['name']:30} {s['status']:14} {s['flavor'].get('original_name', ''):12} {ipv4(s)}")


def ensure_access(api, region):
    """Ключ vpn-infra и группа allow_all в регионе: без них проба бесполезна."""
    nova, neutron = api.nova(region), api.neutron(region)
    keys = [k["keypair"]["name"] for k in api.call("GET", f"{nova}/os-keypairs")["keypairs"]]
    if KEY_NAME not in keys:
        api.call("POST", f"{nova}/os-keypairs", {"keypair": {"name": KEY_NAME, "public_key": PUBKEY.read_text().strip()}})
    if not api.call("GET", f"{neutron}/security-groups?name={SG_NAME}")["security_groups"]:
        sg = api.call("POST", f"{neutron}/security-groups", {"security_group": {"name": SG_NAME}})["security_group"]
        for ethertype in ("IPv4", "IPv6"):
            api.call("POST", f"{neutron}/security-group-rules", {"security_group_rule": {
                "security_group_id": sg["id"], "direction": "ingress", "ethertype": ethertype}})


def cmd_create(api, args):
    region = args.region
    nova, neutron = api.nova(region), api.neutron(region)
    ensure_access(api, region)
    flavor = next(f["id"] for f in api.call("GET", f"{nova}/flavors/detail")["flavors"] if f["name"] == args.flavor)
    image = api.call("GET", f"{api.endpoints[('image', region)]}/v2/images?name={IMAGE_NAME}")["images"][0]["id"]

    subnets = {s["id"]: s for s in api.call("GET", f"{neutron}/subnets")["subnets"] if s["ip_version"] == 4}
    existing = api.servers(region)
    used = {net for s in existing for net in s.get("addresses", {})}
    nets = [n for n in api.call("GET", f"{neutron}/networks")["networks"]
            if n["name"] not in used and any(sid in subnets for sid in n["subnets"])]
    nets.sort(key=lambda n: (0 if n["name"].startswith("Unlisted") else 2 if n["name"].startswith("RESERVE") else 1,
                             n["name"]))
    room = 10 - len(existing)
    if room <= 0:
        sys.exit(f"В {region} уже 10 серверов — это квота региона. Удалите пробы: delete-probes")

    created = []
    for net in nets[:min(args.count, room)]:
        body = {"server": {"name": f"{PROBE_PREFIX}{net['name']}", "flavorRef": flavor, "imageRef": image,
                           "key_name": KEY_NAME, "networks": [{"uuid": net["id"]}],
                           "security_groups": [{"name": SG_NAME}]}}
        created.append(api.call("POST", f"{nova}/servers", body)["server"]["id"])

    deadline = time.time() + 300
    pending = set(created)
    while pending and time.time() < deadline:
        time.sleep(8)
        for sid in list(pending):
            s = api.call("GET", f"{nova}/servers/{sid}")["server"]
            if s["status"] == "ERROR":
                api.call("DELETE", f"{nova}/servers/{sid}")
                print(f"# {s['name']}: ERROR при создании, удалён", file=sys.stderr)
                pending.discard(sid)
            elif s["status"] == "ACTIVE" and ipv4(s):
                print(ipv4(s))
                pending.discard(sid)
    for sid in pending:
        print(f"# {sid}: не поднялся за 5 минут, проверьте list", file=sys.stderr)


def cmd_delete_probes(api, args):
    keep = set(args.keep or [])
    for region, s in all_servers(api):
        if s["name"].startswith(PROBE_PREFIX) and ipv4(s) not in keep:
            api.call("DELETE", f"{api.nova(region)}/servers/{s['id']}")
            print(f"удалён {region} {s['name']} {ipv4(s)}")


def cmd_rename(api, args):
    region, s = find(api, args.ip)
    api.call("PUT", f"{api.nova(region)}/servers/{s['id']}", {"server": {"name": args.name}})
    print(f"{args.ip}: {s['name']} -> {args.name}")


def cmd_resize(api, args):
    region, s = find(api, args.ip)
    nova = api.nova(region)
    flavor = next(f["id"] for f in api.call("GET", f"{nova}/flavors/detail")["flavors"] if f["name"] == args.flavor)
    api.call("POST", f"{nova}/servers/{s['id']}/action", {"resize": {"flavorRef": flavor}})
    for _ in range(60):
        time.sleep(10)
        status = api.call("GET", f"{nova}/servers/{s['id']}")["server"]["status"]
        if status == "VERIFY_RESIZE":
            api.call("POST", f"{nova}/servers/{s['id']}/action", {"confirmResize": None})
        elif status in ("ACTIVE", "ERROR"):
            break
    s = api.call("GET", f"{nova}/servers/{s['id']}")["server"]
    print(f"{args.ip}: {s['status']} {s['flavor'].get('original_name')} адрес {ipv4(s)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    p = sub.add_parser("create")
    p.add_argument("region")
    p.add_argument("--count", type=int, default=8)
    p.add_argument("--flavor", default="hostvds-1")
    p = sub.add_parser("delete-probes")
    p.add_argument("--keep", nargs="*")
    p = sub.add_parser("rename")
    p.add_argument("ip")
    p.add_argument("name")
    p = sub.add_parser("resize")
    p.add_argument("ip")
    p.add_argument("flavor")
    args = ap.parse_args()
    {"list": cmd_list, "create": cmd_create, "delete-probes": cmd_delete_probes,
     "rename": cmd_rename, "resize": cmd_resize}[args.cmd](Api(), args)


if __name__ == "__main__":
    main()
