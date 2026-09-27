# Устройство проекта и правки

## Структура

```text
site.yaml                # плейбук: какие роли и в каком порядке
Makefile                 # все команды (make help)
inventory/hosts.yaml     # список серверов (создаётся из .example, не в git)
group_vars/all/          # общие настройки и общие секреты
host_vars/ИМЯ/           # настройки конкретного сервера (не в git)
keys/                    # ssh-ключ проекта (не в git)
roles/                   # swap, common, ssh, docker, firewall, fail2ban, wireguard,
                         # slipstream, dnstt, xui, rustdesk, summary, backup
tools/                   # new-host.sh, access.sh (make ssh-key, make admin), hostvds.py
tools/measure/           # скрипты замеров (MEASURE.md)
artifacts/               # ключи и сводки, снятые с серверов (не в git)
.vault-key               # пароль от vault: не в git, не потерять
```

Всё, что относится к вашей установке — адреса, домены, пароли, ключи, — лежит в файлах,
которых нет в репозитории. Форкнуть и прислать правку можно, не рискуя опубликовать свою
инфраструктуру.

## Проверки перед коммитом

CI нет: всё проверяется на машине перед коммитом. Хуки ставятся один раз:

```bash
make hooks                 # gitleaks, yamllint, ansible-lint, shellcheck, проверка секретов
pre-commit run --all-files # прогнать всё разом, не дожидаясь коммита
```

Правки ролей, которые пересоздают контейнеры (wireguard, rustdesk, xui), сначала
гоняются через `make check`: контейнер пересоздаётся как «удалить старый → создать новый»,
и ошибка посередине оставляет сервис лежать.
