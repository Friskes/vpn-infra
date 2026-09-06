.DEFAULT_GOAL := help
PLAYBOOK := site.yaml
VENV := .venv
BIN := $(VENV)/bin
ANSIBLE := $(BIN)/ansible-playbook
VAULT_KEY := .vault-key
INVENTORY := inventory/hosts.yaml
SSH_KEY := keys/vpn-infra

# Секреты живут на двух уровнях: общие для всех серверов и личные для каждого.
VAULT_MAIN := group_vars/all/vault.yaml
VAULT_FILES = $(shell ls $(VAULT_MAIN) host_vars/*/vault.yaml 2>/dev/null)

# Развернуть один сервер вместо всех: make deploy HOST=vpn-nl
LIMIT := $(if $(HOST),--limit $(HOST),)

# Развернуть один сервис вместо всех: make deploy TAGS=wireguard
TAGSEL := $(if $(TAGS),--tags $(TAGS),)

.PHONY: help init install hooks keygen secrets-check require-vault-key decrypt encrypt \
        edit-secrets show-secrets vault ping syntax check deploy upgrade backup new-host hosts

help:  ## Показать список команд
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'
	@echo ""
	@echo "  Ограничить одним сервером:  make deploy HOST=vpn-nl"
	@echo "  Ограничить одним сервисом:  make deploy TAGS=wireguard"

# ── Первичная настройка ─────────────────────────────────────────────
# Одна команда вместо шести: окружение, ssh-ключ, инвентарь и секреты.
# Каждый шаг идемпотентен — уже готовое не трогается.
init: install keygen $(INVENTORY) $(VAULT_MAIN)  ## Подготовить всё к первому запуску (одна команда)
	@echo ""
	@echo "Готово. Дальше:"
	@echo "  1. Купите VPS (см. HOSTING.md) и разложите на нём ключ $(SSH_KEY).pub"
	@echo "  2. make new-host NAME=vpn1 IP=<адрес сервера>"
	@echo "  3. make ping && make deploy"

# Переустановка запускается, только когда менялись requirements.*
$(ANSIBLE): requirements.txt requirements.yaml
	test -d $(VENV) || python3 -m venv $(VENV)
	$(BIN)/pip install -qU pip -r requirements.txt
	$(BIN)/ansible-galaxy collection install -r requirements.yaml -p ./.ansible/collections
	@touch $@

install: $(ANSIBLE)  ## Создать .venv и поставить ansible + galaxy-коллекции

hooks: $(ANSIBLE)  ## Включить pre-commit проверки перед коммитом
	$(BIN)/pre-commit install

# Отдельная пара ключей на этот проект, а не общая личная: утечка одной
# не открывает всё остальное, и отзывать её можно не ломая прочий доступ.
$(SSH_KEY):
	@mkdir -p keys
	@ssh-keygen -t ed25519 -N "" -C "vpn-infra" -f $(SSH_KEY) >/dev/null
	@chmod 600 $(SSH_KEY)
	@echo "Создан ssh-ключ $(SSH_KEY). Публичную часть разложите на серверах:"
	@echo ""
	@cat $(SSH_KEY).pub
	@echo ""

keygen: $(SSH_KEY)  ## Создать ssh-ключ для доступа к серверам

$(INVENTORY):
	@cp $(INVENTORY).example $(INVENTORY)
	@echo "Создан $(INVENTORY). Серверы добавляйте командой make new-host."

hosts: $(ANSIBLE)  ## Показать список серверов
	@$(BIN)/ansible-inventory --list --yaml 2>/dev/null | \
		grep -E "^\s{8}[a-z0-9-]+:|ansible_host:" | sed 's/^/  /'

new-host: $(ANSIBLE)  ## Завести сервер: make new-host NAME=vpn1 IP=203.0.113.10
	@test -n "$(NAME)" || { echo "Укажите имя: make new-host NAME=vpn1 IP=203.0.113.10"; exit 1; }
	@test -n "$(IP)" || { echo "Укажите адрес: make new-host NAME=$(NAME) IP=203.0.113.10"; exit 1; }
	@bash tools/new-host.sh "$(NAME)" "$(IP)" "$(if $(GROUP),$(GROUP),vpn)"

# ── Секреты ─────────────────────────────────────────────────────────
# Последний рубеж перед коммитом: расшифрованные секреты и личные данные
# в публичном репозитории оказаться не должны.
secrets-check:  ## Проверить, что секреты зашифрованы и не отслеживаются git
	@fail=0; \
	for f in $(VAULT_FILES); do \
		if ! head -1 $$f | grep -q '^$$ANSIBLE_VAULT'; then \
			echo "ОШИБКА: $$f не зашифрован — выполните make encrypt"; fail=1; \
		fi; \
	done; \
	for f in $(VAULT_KEY) $(VAULT_MAIN) $(INVENTORY) $(SSH_KEY) $(SSH_KEY).pub; do \
		if git ls-files --error-unmatch $$f >/dev/null 2>&1; then \
			echo "ОШИБКА: $$f отслеживается git — уберите: git rm --cached $$f"; fail=1; \
		fi; \
	done; \
	if [ $$fail -eq 0 ]; then echo "Секреты в порядке"; else exit 1; fi

# Ключ генерируется один раз и лежит рядом с проектом (в .gitignore). Общий для всех
# серверов. Создаётся только явными init/decrypt/encrypt — прогоны (deploy/check/ping)
# его НЕ генерируют: иначе на новой машине с потерянным ключом молча появился бы чужой
# ключ и невнятная «Decryption failed» вместо честного «ключ потерян, восстановите».
$(VAULT_KEY):
	@head -c 32 /dev/urandom | base64 > $(VAULT_KEY)
	@chmod 600 $(VAULT_KEY)
	@echo "Создан $(VAULT_KEY) — не теряйте его, без него vault не расшифровать."

# Пароли придумывает не человек: у админок нет ни счётчика попыток, ни задержки,
# а через их API отдаются ключи всех клиентов. Заходят в них через ssh-проброс,
# так что запоминать пароль незачем — посмотреть можно make show-secrets.
$(VAULT_MAIN): $(ANSIBLE) $(VAULT_KEY)
	@cp $(VAULT_MAIN).example $(VAULT_MAIN)
	@for v in vault_wireguard_admin_password vault_xui_admin_password; do \
		pass=$$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32); \
		sed -i "s|^$$v: \"\"|$$v: \"$$pass\"|" $(VAULT_MAIN); \
	done
	@chmod 600 $(VAULT_MAIN)
	@$(BIN)/ansible-vault encrypt $(VAULT_MAIN) >/dev/null
	@echo "Создан $(VAULT_MAIN) со случайными паролями админок (make show-secrets)."

require-vault-key:
	@test -f $(VAULT_KEY) || { \
		echo "Нет $(VAULT_KEY) — без него vault не расшифровать."; \
		echo "Новая машина: восстановите ключ из бэкапа. Первичная настройка: make init."; \
		exit 1; \
	}

show-secrets: $(ANSIBLE) require-vault-key  ## Показать пароли админок, ничего не меняя
	@$(BIN)/ansible-vault view $(VAULT_MAIN)

edit-secrets: $(ANSIBLE) require-vault-key  ## Поправить секреты, не расшифровывая файл на диске
	@$(BIN)/ansible-vault edit $(VAULT_MAIN)

# Список файлов пересчитывается внутри рецепта, а не в переменной make: иначе
# только что созданный из шаблона vault в него не попадёт и останется с правами 644.
decrypt: $(ANSIBLE) $(VAULT_KEY)  ## Расшифровать все vault-файлы (правьте как обычные)
	@test -f $(VAULT_MAIN) || cp $(VAULT_MAIN).example $(VAULT_MAIN)
	@for f in $$(ls $(VAULT_MAIN) host_vars/*/vault.yaml 2>/dev/null); do \
		if head -1 $$f | grep -q '^$$ANSIBLE_VAULT'; then \
			$(BIN)/ansible-vault decrypt $$f; \
		else \
			echo "$$f и так расшифрован"; \
		fi; \
		chmod 600 $$f; \
	done

encrypt: $(ANSIBLE) $(VAULT_KEY)  ## Зашифровать все vault-файлы обратно
	@for f in $$(ls $(VAULT_MAIN) host_vars/*/vault.yaml 2>/dev/null); do \
		if head -1 $$f | grep -q '^$$ANSIBLE_VAULT'; then \
			echo "$$f уже зашифрован"; \
		else \
			$(BIN)/ansible-vault encrypt $$f; \
		fi; \
		chmod 600 $$f; \
	done

vault: decrypt  ## Псевдоним decrypt (оставлен по привычке)

# ── Развёртывание ───────────────────────────────────────────────────
# ARGS пробрасывается в ansible-playbook: разовая перезагрузка —
# make deploy ARGS="-e common_auto_reboot=true"
ping: $(ANSIBLE) require-vault-key  ## Проверить связь с серверами
	$(BIN)/ansible all $(LIMIT) -m ansible.builtin.ping

syntax: $(ANSIBLE)  ## Проверить синтаксис playbook
	$(ANSIBLE) $(PLAYBOOK) --syntax-check

check: $(ANSIBLE) require-vault-key  ## Сухой прогон без изменений (dry-run)
	$(ANSIBLE) $(PLAYBOOK) $(LIMIT) $(TAGSEL) --check --diff $(ARGS)

deploy: $(ANSIBLE) require-vault-key  ## Развернуть (целиком или один сервис через TAGS=)
	$(ANSIBLE) $(PLAYBOOK) $(LIMIT) $(TAGSEL) $(ARGS)

upgrade: $(ANSIBLE) require-vault-key  ## Развернуть и заодно накатить обновления пакетов
	$(ANSIBLE) $(PLAYBOOK) $(LIMIT) $(TAGSEL) -e common_upgrade_packages=true $(ARGS)

# Роль backup помечена тегом never, поэтому в обычный прогон не попадает и запускается
# только отсюда. Складывает состояние wg-easy и учётки туннеля в artifacts/<сервер>/.
backup: $(ANSIBLE) require-vault-key  ## Снять состояние серверов в artifacts/ (для переезда)
	$(ANSIBLE) $(PLAYBOOK) $(LIMIT) --tags backup $(ARGS)
