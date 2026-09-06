# Приложения для подключения

Сервер развёрнут — теперь на телефон и компьютер нужны клиенты. Для каждого
канала своё приложение: универсального нет.

| Канал | Windows | Android | macOS / iOS |
|---|---|---|---|
| WireGuard | [WireSock](#wireguard-на-windows--wiresock) | [Amnezia](#wireguard-на-android--amnezia) | [офиц. WireGuard](https://www.wireguard.com/install/) |
| Reality (обход DPI) | [v2rayN](#reality-на-windows--v2rayn) | [v2rayNG](#reality-на-android--v2rayng) | [Hiddify](https://github.com/hiddify/hiddify-app) |
| DNS-туннель | нет | [SlipNet](#dns-туннель--только-slipnet) | нет |
| RustDesk | [офиц. клиент](https://rustdesk.com/) | [офиц. клиент](https://rustdesk.com/) | [офиц. клиент](https://rustdesk.com/) |

Ссылку или конфиг для любого из них выдаёт сам сервер — руками ничего заполнять
не нужно, см. [«Откуда брать конфиг»](#откуда-брать-конфиг) внизу.

## WireGuard на Windows — WireSock

[WireSock Secure Connect](https://www.wiresock.net/) вместо официального клиента,
потому что он умеет то, чего у официального нет:

- **раздельное туннелирование по приложениям** — в VPN уходит только браузер или
  только игра, остальное идёт напрямую и не теряет скорость;
- исключение отдельных адресов из туннеля;
- маскировка трафика от DPI и поддержка AmneziaWG.

Бесплатен для личного, учебного и некоммерческого использования; исходники
закрыты, платная версия — для компаний. Официальный клиент
[WireGuard для Windows](https://github.com/WireGuard/wireguard-windows) остаётся
запасным вариантом, если закрытый код принципиально не подходит.

Конфиг из админки wg-easy импортируется как есть: «Добавить туннель из файла».

## WireGuard на Android — Amnezia

[Amnezia VPN](https://github.com/amnezia-vpn/amnezia-client) ([сайт и загрузки](https://amnezia.org/downloads))
понимает обычный WireGuard и вдобавок умеет **AmneziaWG** — тот же протокол, но с
обфускацией: пакеты перестают опознаваться по сигнатуре, и провайдер, режущий
WireGuard по виду трафика, его не видит.

Импорт: `+` на главном экране → «Файл с настройками подключения» → выбрать
скачанный `.conf`. Предложит включить обфускацию — соглашайтесь.

> [!WARNING]
> Известная грабля: при `AllowedIPs = 0.0.0.0/0` Amnezia не исключает адрес
> самого VPN-сервера из туннеля — пакет к серверу заворачивается в туннель,
> ведущий на этот же сервер. Клиент показывает «Подключено», трафика нет.
> Разбор и лечение — в [OPERATORS.md](OPERATORS.md#похоже-на-поломку-канала-но-это-не-она).

Официальный [WireGuard для Android](https://play.google.com/store/apps/details?id=com.wireguard.android)
тоже работает — но без обфускации и без списков приложений.

## Reality на Android — v2rayNG

[v2rayNG](https://github.com/2dust/v2rayNG) — стандартный клиент Xray для Android,
поддерживает VLESS + Reality + Vision, то есть ровно то, что поднимает панель 3x-ui.

Профиль добавляется одной ссылкой `vless://…` или QR-кодом из панели:
`+` → «Импорт из буфера обмена» либо «Сканировать QR-код».

## Reality на Windows — v2rayN

[v2rayN](https://github.com/2dust/v2rayN) — тот же проект, что v2rayNG, только для
Windows. Ссылка `vless://…` вставляется из буфера обмена.

Кому нужен один клиент на все платформы сразу — [Hiddify](https://github.com/hiddify/hiddify-app):
Windows, macOS, Linux, Android, iOS, тот же набор протоколов, интерфейс проще.

> [!CAUTION]
> **NekoRay и NekoBox ставить не надо.** Репозиторий
> [MatsuriDayo/nekoray](https://github.com/MatsuriDayo/nekoray) заархивирован
> 17 марта 2025 с формулировкой «больше не поддерживается, ищите замену».
> Обновлений и исправлений безопасности не будет.

## DNS-туннель — только SlipNet

Клиент один: [SlipNet](https://github.com/anonvector/SlipNet), Android. Понимает
оба туннеля, которые ставит этот проект — Slipstream и dnstt.

> [!IMPORTANT]
> Скачивать только со [страницы релизов на GitHub](https://github.com/anonvector/SlipNet/releases).
> В Google Play и других магазинах официальных сборок нет — всё, что там лежит,
> выложено посторонними.

Сервер выдаёт готовую ссылку `slipnet://…` (команда `slipnet-user add <имя>`),
она вставляется через «Import from URI» и заполняет профиль целиком. Настройки,
которые стоит проверить после импорта, и подбор резолвера — в [TUNNEL.md](TUNNEL.md).

## Раздельное туннелирование

Гнать весь трафик через VPN нужно не всегда: банки и госуслуги от зарубежного
адреса часто отказываются работать, а скорость на дальнем сервере ниже домашней.

[vpn-configurator](https://github.com/Friskes/vpn-configurator) — программа с
графическим интерфейсом, которая берёт обычный `.conf` из админки wg-easy и
делает из него конфиг, где в туннель уходят только выбранные сервисы. Есть
готовые наборы адресов (YouTube, Discord, Telegram, ChatGPT и другие) и режимы
для WireGuard, Amnezia, WireSock и Android-клиентов со списками приложений.

<!-- media: split-tunneling.png — скриншот окна vpn-configurator с загруженным конфигом -->

## Откуда брать конфиг

| Канал | Где взять |
|---|---|
| WireGuard | админка wg-easy: создать клиента → скачать `.conf` или снять QR-код |
| Reality | панель 3x-ui: у строки входа кнопка выдачи ссылки `vless://` и QR |
| DNS-туннель | на сервере: `slipnet-user add <имя>` печатает ссылку `slipnet://` |
| RustDesk | адрес сервера и Public Key — в `artifacts/<сервер>/CONNECTION_INFO.md` |

Обе админки — wg-easy и 3x-ui — снаружи закрыты намеренно. Как в них попасть
через SSH-проброс, описано в [SERVER.md](SERVER.md#доступ-к-админкам).

<!-- media: wg-easy-client.png — скриншот админки wg-easy с созданным клиентом и QR -->
<!-- media: xui-inbound.png — скриншот панели 3x-ui с готовым инбаундом reality-443 -->
