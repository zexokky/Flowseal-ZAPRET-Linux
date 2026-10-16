<div align="center">

# zapret-discord-youtube для Linux

**Обход DPI-блокировок Discord и YouTube на Kali / Debian / Ubuntu**

<a href="https://t.me/nonmainfun">
  <img src="assets/telegram-button.svg" width="420" alt="Мой Telegram-канал @nonmainfun">
</a>

</div>

---

## 📖 Что это

Проект запускает `nfqws` из [bol-van/zapret](https://github.com/bol-van/zapret). Правило nftables (NFQUEUE) передаёт ему первые пакеты соединений, а он изменяет их так, чтобы DPI провайдера не распознал заблокированный сайт.

## ⚙️ Установка

```bash
cd ~/Документы/zapret-discord-youtube-main
chmod +x install.sh zapret.sh
sudo ./install.sh
```

`install.sh` делает три вещи:
- ставит нужные пакеты через apt;
- собирает `nfqws` из исходников bol-van/zapret в `bin/nfqws`;
- переводит списки в формат строк Linux.

## 🚀 Использование

```bash
sudo ./zapret.sh                   # интерактивное меню
./zapret.sh list                   # список стратегий
sudo ./zapret.sh start general     # запустить стратегию (можно: general-alt2, "general (ALT2)" или её номер)
sudo ./zapret.sh stop              # остановить
sudo ./zapret.sh status            # состояние
sudo ./zapret.sh test              # проверить все стратегии и найти лучшую
sudo ./zapret.sh test general-alt5 # проверить одну стратегию
sudo ./zapret.sh install-service general-alt2   # автозапуск при загрузке (systemd)
sudo ./zapret.sh remove-service    # убрать автозапуск
sudo ./zapret.sh diagnostics       # диагностика
```

Другие команды:

| Команда         | Что делает                                       |
|-----------------|--------------------------------------------------|
| `restart`       | перезапуск текущей стратегии                     |
| `game-filter`   | обход для игр (TCP/UDP-порты)                    |
| `ipset-filter`  | режим IPSet: `loaded` / `none` / `any`           |
| `update-ipset`  | обновить `lists/ipset-all.txt`                   |
| `update-hosts`  | добавить нужные записи в `/etc/hosts`            |
| `replace-fakes` | сменить активные фейки для Discord / игр         |

> 💡 Если стратегия не работает, попробуйте следующую (`general-alt`, `general-alt2`, ...). Можно и автоматически: `sudo ./zapret.sh test` проверит все стратегии и покажет лучшую.

## 🔧 Как это работает

- `zapret.sh` создаёт таблицу nftables `inet zapret_dy`. Она отправляет первые пакеты исходящих соединений на портах стратегии (`TCP_PORTS` / `UDP_PORTS`) в очередь NFQUEUE 200.
- `nfqws` получает параметры из `strategies/<имя>.conf`, по одному на строку. Он работает от имени владельца папки проекта, поэтому может читать списки даже в закрытой домашней папке.
- `stop` (или остановка службы) удаляет таблицу nftables, поэтому правил после остановки не остаётся.

## 📁 Файлы

| Путь                             | Назначение                                                   |
|----------------------------------|--------------------------------------------------------------|
| `strategies/*.conf`              | стратегии (`@BIN@`, `@LISTS@`, `@GAME_TCP@`, `@GAME_UDP@`)   |
| `lists/list-general-user.txt`    | ваши домены для обхода                                       |
| `lists/list-exclude-user.txt`    | домены-исключения                                            |
| `lists/ipset-exclude-user.txt`   | IP-исключения                                                |
| `utils/game_filter.enabled`      | настройки Game Filter                                        |
| `utils/targets.txt`              | сайты для проверки командой `test`                           |
| `bin/*.bin`                      | фейковые пакеты                                              |

## 🛠 Решение проблем

- **`nfqws not found`**: запустите `sudo ./install.sh`.
- **Логи службы:** `journalctl -u zapret-discord-youtube -e`.
- **Увидеть ошибку nfqws:** `sudo ./zapret.sh run general` (остановить: Ctrl+C).
- **Конфликты:** VPN, другой zapret или byedpi могут мешать работе. Проверьте их через `sudo ./zapret.sh diagnostics`.

---

<div align="center">

Основано на [bol-van/zapret](https://github.com/bol-van/zapret) и [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube)

<a href="https://t.me/nonmainfun"><img src="assets/telegram-button.svg" width="320" alt="Мой Telegram-канал @nonmainfun"></a>

</div>
