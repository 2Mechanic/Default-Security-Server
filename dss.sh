#!/bin/bash
# =============================================================================
# Готовый скрипт по гайду How-To-Secure-A-Linux-Server.
# Запуск ТОЛЬКО на целевом Linux-сервере: sudo bash dss.sh
# Если падает с "command not found" — на сервере выполни: sed -i 's/\r$//' dss.sh
# v6.1:
#   - смена пароля root (генерируется вместе с паролем пользователя)
#   - логин/пароли выводятся даже при падении скрипта
# v6: исправлены критические ошибки v5:
#   - ssh.socket (Ubuntu 22.10+/24.04): переключение на обычную службу
#   - sshd -t / sshd -T перед перезапуском + автоматический откат
#   - HostKey (оба ключа), приоритет над sshd_config.d/*.conf и Match
#   - установка sudo, проверка sudoers через visudo
#   - пароль без openssl (fallback /dev/urandom) + проверка длины
#   - wait_apt без fuser (pgrep + DPkg::Lock::Timeout)
#   - SELinux: semanage port для нового порта
#   - PAM: pam_permit после nullok (иначе вход без настроенного 2FA ломался)
#   - fail2ban: journal-backend без rsyslog, проверка конфига
#   - финальная проверка входа с возможностью отката
# =============================================================================

# curl|sudo bash: stdin = pipe, ввод с клавиатуры не работает.
# Копируем скрипт во временный файл и перезапускаем с stdin/stdout на /dev/tty.
if [ -z "${DSS_REEXEC:-}" ]; then
    _bss="${BASH_SOURCE[0]:-}"
    _need_reexec=0
    if [ ! -f "$_bss" ]; then
        _need_reexec=1
    elif [ ! -t 0 ]; then
        _need_reexec=1
    fi
    if [ "$_need_reexec" = 1 ]; then
        _tmp="$(mktemp /tmp/dss.XXXXXX.sh)"
        _copied=0
        if [ -f "$_bss" ]; then
            cp "$_bss" "$_tmp" && _copied=1
        else
            for _fd in 255 254 253 63 62 61; do
                if [ -r "/proc/self/fd/$_fd" ] && cat "/proc/self/fd/$_fd" > "$_tmp" 2>/dev/null; then
                    if [ -s "$_tmp" ] && grep -q "How-To-Secure-A-Linux-Server" "$_tmp" 2>/dev/null; then
                        _copied=1
                        break
                    fi
                fi
            done
            if [ "$_copied" != 1 ]; then
                _url="${DSS_SCRIPT_URL:-https://raw.githubusercontent.com/2Mechanic/Default-Security-Server/main/dss.sh}"
                if command -v curl >/dev/null 2>&1 && curl -fsSL "$_url" -o "$_tmp"; then
                    if [ -s "$_tmp" ] && grep -q "How-To-Secure-A-Linux-Server" "$_tmp" 2>/dev/null; then
                        _copied=1
                    fi
                fi
            fi
        fi
        if [ "$_copied" != 1 ]; then
            rm -f "$_tmp"
            echo "[!] Не удалось подготовить интерактивный запуск через pipe."
            echo "    Сделай так:"
            echo "    curl -fsSL <URL> -o /tmp/dss.sh && sudo bash /tmp/dss.sh"
            exit 1
        fi
        chmod 700 "$_tmp"
        export DSS_REEXEC=1
        echo "[*] Перезапуск с TTY для интерактивного ввода..."
        if [ -c /dev/tty ]; then
            exec bash "$_tmp" "$@" </dev/tty >/dev/tty 2>/dev/tty
        else
            exec bash "$_tmp" "$@"
        fi
    fi
fi

set -e
[ -n "${DEBUG:-}" ] && set -x

# =============================================================================
# Глобальные переменные
# =============================================================================
SCRIPT_VERSION="v6.1"
LAST_STEP="Подготовка"
TS="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="/root/dss-backup-$TS"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
PAM_SSHD="/etc/pam.d/sshd"
SUDOERS_FILE="/etc/sudoers.d/99-sudousers"

NEW_USER_NAME=""
USER_PASSWORD=""
ROOT_PASSWORD=""
NEW_SSH_PORT="${NEW_SSH_PORT:-}"
CREDS_SHOWN=0          # итоговые данные уже выведены

SSH_CHANGED=0          # конфиги SSH/PAM уже изменены
SSH_RESTARTED=0        # была попытка перезапуска sshd
SSH_APPLIED_OK=0       # sshd успешно слушает новый порт
SOCKET_UNIT=""         # ssh.socket / sshd.socket, если был активен
SOCKET_SWITCHED=0
SSH_SERVICE=""
SSH_SERVICE_WAS_ENABLED=""
SSHD_BIN=""
OLD_SSH_PORTS=""
ROLLBACK_DONE=0
FIREWALL=""
APT_UPDATED=0

# Ключи sshd, которые задаёт скрипт (в нижнем регистре).
# Их активные копии в sshd_config и sshd_config.d/*.conf комментируются,
# чтобы действовали только значения скрипта. AllowUsers тоже комментируется:
# вместе с AllowGroups он может заблокировать нового пользователя.
SSHD_KEYS="port allowgroups allowusers permitrootlogin passwordauthentication pubkeyauthentication permitemptypasswords hostkey kexalgorithms ciphers macs loglevel x11forwarding allowtcpforwarding maxauthtries clientaliveinterval clientalivecountmax usepam challengeresponseauthentication kbdinteractiveauthentication authenticationmethods"
KEYS_RE="$(echo $SSHD_KEYS | tr ' ' '|')"

# =============================================================================
# Функции
# =============================================================================

# Бэкап файла с сохранением пути: /etc/ssh/sshd_config -> $BACKUP_DIR/etc/ssh/sshd_config
backup_file() {
    local f="$1"
    if [ -e "$BACKUP_DIR$f" ]; then
        return 0
    fi
    mkdir -p "$BACKUP_DIR$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR$f"
    echo "$f" >> "$BACKUP_DIR/.files"
}

# Откат конфигурации SSH/PAM/socket к исходному состоянию
rollback_ssh() {
    if [ "$ROLLBACK_DONE" = 1 ]; then
        return 0
    fi
    ROLLBACK_DONE=1
    set +e
    echo ""
    echo "[!] ОТКАТ: восстанавливаю конфигурацию SSH/PAM из $BACKUP_DIR"
    if [ -f "$BACKUP_DIR/.files" ]; then
        while IFS= read -r _f; do
            [ -n "$_f" ] || continue
            if cp -a "$BACKUP_DIR$_f" "$_f"; then
                echo "    [+] восстановлен $_f"
            fi
        done < "$BACKUP_DIR/.files"
    fi
    systemctl daemon-reload 2>/dev/null
    if [ "$SOCKET_SWITCHED" = 1 ]; then
        systemctl stop "$SSH_SERVICE" 2>/dev/null
        if [ "$SSH_SERVICE_WAS_ENABLED" != "enabled" ]; then
            systemctl disable "$SSH_SERVICE" 2>/dev/null
        fi
        systemctl enable --now "$SOCKET_UNIT" 2>/dev/null
        systemctl restart "$SOCKET_UNIT" 2>/dev/null
        echo "    [+] $SOCKET_UNIT снова включён"
    elif [ "$SSH_RESTARTED" = 1 ]; then
        if systemctl restart "$SSH_SERVICE" 2>/dev/null; then
            echo "    [+] $SSH_SERVICE перезапущен со старым конфигом"
        else
            echo "    [!] $SSH_SERVICE не перезапустился — проверь: journalctl -u $SSH_SERVICE"
        fi
    fi
    if [ -n "$OLD_SSH_PORTS" ]; then
        if [ "$FIREWALL" = "ufw" ] && ufw status 2>/dev/null | grep -q "Status: active"; then
            for _p in $OLD_SSH_PORTS; do
                ufw allow "$_p/tcp" comment "SSH (rollback)" >/dev/null 2>&1
            done
            echo "    [+] UFW: открыты старые порты SSH: $OLD_SSH_PORTS"
        elif [ "$FIREWALL" = "firewalld" ]; then
            for _p in $OLD_SSH_PORTS; do
                firewall-cmd --permanent --add-port="$_p/tcp" >/dev/null 2>&1
            done
            firewall-cmd --reload >/dev/null 2>&1
            echo "    [+] firewalld: открыты старые порты SSH: $OLD_SSH_PORTS"
        fi
    fi
    echo "[!] Откат завершён. SSH должен работать как раньше (порт: ${OLD_SSH_PORTS:-22})."
    echo "    Пользователь, группы, sudo и пароли (включая root) НЕ откатывались."
}

# Вывод логина/паролей при аварийном завершении (чтобы не потерять новый пароль root)
emergency_creds() {
    if [ "$CREDS_SHOWN" = 1 ]; then
        return 0
    fi
    if [ -z "$USER_PASSWORD" ] && [ -z "$ROOT_PASSWORD" ]; then
        return 0
    fi
    echo ""
    echo "=============================================="
    echo "  [!] СКРИПТ ЗАВЕРШИЛСЯ С ОШИБКОЙ"
    echo "  Пароли УЖЕ изменены — сохрани их:"
    echo "=============================================="
    [ -n "$NEW_USER_NAME" ] && echo "  Логин:        $NEW_USER_NAME"
    [ -n "$USER_PASSWORD" ] && echo "  Пароль:       $USER_PASSWORD"
    [ -n "$ROOT_PASSWORD" ] && echo "  Пароль root:  $ROOT_PASSWORD"
    echo "  Бэкапы:       $BACKUP_DIR"
    echo "=============================================="
    CREDS_SHOWN=1
}

on_error() {
    local rc=$?
    trap - ERR
    echo ""
    echo "[!] Скрипт упал (код $rc). Последний шаг: $LAST_STEP"
    echo "    Запусти с отладкой: DEBUG=1 sudo bash dss.sh"
    exit "${rc:-1}"
}

# Срабатывает при ЛЮБОМ выходе:
#  - если SSH уже изменён, но не применён успешно — откат
#  - если пароли сменены, но не выведены — выводим
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$SSH_CHANGED" = 1 ] && [ "$SSH_APPLIED_OK" != 1 ]; then
        rollback_ssh
    fi
    emergency_creds
}

trap on_error ERR
trap on_exit EXIT

# Всегда читаем с TTY
ask() {
    local _v=""
    if [ -c /dev/tty ] && [ -r /dev/tty ]; then
        read -r _v </dev/tty || _v=""
    elif [ -t 0 ]; then
        read -r _v || _v=""
    else
        echo "[!] Нет TTY для ввода. Запусти: sudo bash dss.sh (не через pipe)."
        exit 1
    fi
    printf -v "$1" '%s' "$_v"
}

# apt/dpkg занят? Работает и без fuser.
apt_busy() {
    if command -v fuser >/dev/null 2>&1; then
        if fuser -s /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -x 'apt|apt-get|aptitude|dpkg' >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    return 1
}

wait_apt() {
    local i=0
    while apt_busy; do
        if [ "$i" -eq 0 ]; then
            echo "[*] Ожидаю освобождения apt/dpkg (unattended-upgrades или другой процесс)..."
        fi
        sleep 5
        i=$((i + 1))
        if [ "$i" -ge 60 ]; then
            echo "[!] apt занят больше 5 минут"
            return 1
        fi
    done
    return 0
}

# Универсальная установка пакетов. Вызывать только в if / с || true.
pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then
        wait_apt || true
        if [ "$APT_UPDATED" = 0 ]; then
            apt-get -o DPkg::Lock::Timeout=300 update -qq || true
            APT_UPDATED=1
        fi
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@"
    else
        echo "[!] Нет apt/dnf/yum — установи вручную: $*"
        return 1
    fi
}

ensure_epel() {
    if command -v rpm >/dev/null 2>&1 && ! rpm -q epel-release >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y epel-release >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y epel-release >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

# Пароль 16 символов; fallback на /dev/urandom, если нет openssl
gen_password() {
    local p=""
    if command -v openssl >/dev/null 2>&1; then
        p="$(openssl rand -base64 48 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 16 || true)"
    fi
    if [ "${#p}" -lt 16 ]; then
        p="$(LC_ALL=C tr -dc 'A-Za-z0-9' 2>/dev/null < /dev/urandom | head -c 16 || true)"
    fi
    printf '%s' "$p"
}

# 0 — порт слушается, 1 — нет, 2 — нельзя проверить (нет ss)
port_listening() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        if ss -tln 2>/dev/null | awk 'NR>1 {print $4}' | grep -qE "[:.]${p}\$"; then
            return 0
        fi
        return 1
    fi
    return 2
}

# SSH_CONNECTION текущей сессии (работает и через sudo: ищем в окружении родителей)
find_ssh_connection() {
    local pid="$$" ppid="" v="" i
    if [ -n "${SSH_CONNECTION:-}" ]; then
        printf '%s' "$SSH_CONNECTION"
        return 0
    fi
    for i in $(seq 1 20); do
        ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
        if [ -z "$ppid" ] || [ "$ppid" = "0" ] || [ "$ppid" = "1" ]; then
            break
        fi
        pid="$ppid"
        if [ -r "/proc/$pid/environ" ]; then
            v="$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" | sed -n 's/^SSH_CONNECTION=//p' | head -n 1 || true)"
            if [ -n "$v" ]; then
                printf '%s' "$v"
                return 0
            fi
        fi
    done
    return 0
}

# Оставляет только алгоритмы, которые поддерживает установленный OpenSSH
filter_algos() {
    local type="$1" list="$2" fallback="$3" sup="" out="" a
    if command -v ssh >/dev/null 2>&1; then
        sup="$(ssh -Q "$type" 2>/dev/null || true)"
    fi
    if [ -z "$sup" ]; then
        printf '%s' "$fallback"
        return 0
    fi
    for a in ${list//,/ }; do
        if printf '%s\n' "$sup" | grep -qxF "$a"; then
            out="${out:+$out,}$a"
        fi
    done
    if [ -z "$out" ]; then
        out="$fallback"
    fi
    printf '%s' "$out"
}

# Комментирует ключи из SSHD_KEYS (вне блоков Match) и убирает старый блок DSS
disable_keys_in_file() {
    local f="$1" tmp
    tmp="$(mktemp)"
    awk -v re="^[ \t]*(${KEYS_RE})[ \t=]" '
        /^# >>> DSS BEGIN/ { skip = 1; next }
        /^# <<< DSS END/   { skip = 0; next }
        skip { next }
        /^[ \t]*[Mm][Aa][Tt][Cc][Hh][ \t]/ { m = 1 }
        { if (!m && tolower($0) ~ re) print "# DSS-disabled: " $0; else print }
    ' "$f" > "$tmp"
    if ! cmp -s "$f" "$tmp"; then
        backup_file "$f"
        cat "$tmp" > "$f"
        echo "    [*] отключены конфликтующие параметры в $f"
    fi
    rm -f "$tmp"
}

# =============================================================================
# Проверки окружения
# =============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: запускай с root. Пример: sudo bash dss.sh"
    exit 1
fi

if ! command -v useradd &>/dev/null || ! command -v groupadd &>/dev/null; then
    echo "Ошибка: нужен Linux с useradd/groupadd (Debian/Ubuntu/CentOS). Запускай скрипт НА СЕРВЕРЕ, не на своём ПК."
    exit 1
fi

if ! command -v systemctl &>/dev/null; then
    echo "Ошибка: нужен systemd (systemctl)."
    exit 1
fi

if ! command -v chpasswd &>/dev/null; then
    echo "Ошибка: не найден chpasswd (пакет passwd / shadow-utils)."
    exit 1
fi

SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
if [ -z "$SSHD_BIN" ]; then
    for _p in /usr/sbin/sshd /sbin/sshd; do
        if [ -x "$_p" ]; then SSHD_BIN="$_p"; break; fi
    done
fi
if [ -z "$SSHD_BIN" ]; then
    echo "Ошибка: не найден sshd (OpenSSH server). Установи openssh-server."
    exit 1
fi

if systemctl cat ssh.service >/dev/null 2>&1; then
    SSH_SERVICE="ssh.service"
elif systemctl cat sshd.service >/dev/null 2>&1; then
    SSH_SERVICE="sshd.service"
else
    echo "Ошибка: не найдена служба ssh.service / sshd.service."
    exit 1
fi

for _s in ssh.socket sshd.socket; do
    if systemctl is-active --quiet "$_s" 2>/dev/null || [ "$(systemctl is-enabled "$_s" 2>/dev/null || true)" = "enabled" ]; then
        SOCKET_UNIT="$_s"
        break
    fi
done

echo ">>> $SCRIPT_VERSION — sshd -t, автооткат, ssh.socket, смена пароля root"
echo ">>> Хост: $(hostname). Служба SSH: $SSH_SERVICE${SOCKET_UNIT:+ (через $SOCKET_UNIT)}"
echo ""

# =============================================================================
# Параметры
# =============================================================================
echo "[*] Параметры..."
echo ""

printf "Введите желаемый логин [по умолчанию snegg000]: "
ask INPUT_USER
NEW_USER_NAME="${INPUT_USER:-snegg000}"
NEW_USER_NAME="${NEW_USER_NAME// /}"
if [ -z "$NEW_USER_NAME" ]; then NEW_USER_NAME="snegg000"; fi
if [ "$NEW_USER_NAME" = "root" ]; then
    echo "[!] Логин не может быть root. Выход."
    exit 1
fi

printf "Включать 2FA (OTP по коду из приложения)? (y/n) [y]: "
ask INPUT_2FA
case "${INPUT_2FA,,}" in
    n|no) ENABLE_2FA="n" ;;
    *)    ENABLE_2FA="y" ;;
esac

printf "Устанавливать NetBird? (y/n) [n]: "
ask INPUT_NETBIRD
case "${INPUT_NETBIRD,,}" in
    y|yes) ENABLE_NETBIRD="y" ;;
    *)     ENABLE_NETBIRD="n" ;;
esac

NETBIRD_SETUP_KEY=""
if [ "$ENABLE_NETBIRD" = "y" ]; then
    printf "Setup key NetBird (Enter — только установить, без netbird up): "
    ask NETBIRD_SETUP_KEY
    NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY// /}"
fi

PUBKEY="${1:-${PUBKEY:-}}"

if [ -n "$NEW_SSH_PORT" ]; then
    if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_SSH_PORT" -lt 1024 ] || [ "$NEW_SSH_PORT" -gt 65535 ]; then
        echo "[!] NEW_SSH_PORT должен быть числом 1024–65535"
        exit 1
    fi
    if port_listening "$NEW_SSH_PORT"; then
        echo "[!] Порт $NEW_SSH_PORT уже занят другим процессом"
        exit 1
    fi
else
    for _i in $(seq 1 30); do
        if command -v shuf &>/dev/null; then
            _cand="$(shuf -i 20000-65000 -n 1)"
        else
            _cand=$((20000 + RANDOM % 45001))
        fi
        if ! port_listening "$_cand"; then
            NEW_SSH_PORT="$_cand"
            break
        fi
    done
    if [ -z "$NEW_SSH_PORT" ]; then
        echo "[!] Не удалось подобрать свободный порт"
        exit 1
    fi
fi

echo "[+] Пользователь: $NEW_USER_NAME, порт SSH: $NEW_SSH_PORT, 2FA: $ENABLE_2FA, NetBird: $ENABLE_NETBIRD"
echo "[+] Пароль root будет заменён на случайный"
echo ""

# =============================================================================
# Шаг 0: пакеты и данные о текущей сессии (до любых изменений)
# =============================================================================
LAST_STEP="Шаг 0/10: проверки и пакеты"
echo ">>> $LAST_STEP"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
echo "[+] Бэкапы будут в $BACKUP_DIR"

if ! command -v sudo &>/dev/null; then
    echo "[*] sudo не найден — устанавливаю..."
    pkg_install sudo || true
fi
if ! command -v sudo &>/dev/null; then
    echo "[!] sudo не установился. Без него после запрета root по SSH нельзя получить root. Выход (ничего не изменено)."
    exit 1
fi
echo "[+] sudo есть"

if [ "$ENABLE_2FA" = "y" ] && ! command -v google-authenticator &>/dev/null; then
    echo "[*] Устанавливаю Google Authenticator PAM..."
    if command -v apt-get &>/dev/null; then
        pkg_install libpam-google-authenticator || true
    else
        ensure_epel
        pkg_install google-authenticator || true
    fi
    if ! command -v google-authenticator &>/dev/null; then
        echo "[!] google-authenticator не установился. Запусти снова без 2FA или установи пакет вручную. Выход (ничего не изменено)."
        exit 1
    fi
fi
if [ "$ENABLE_2FA" = "y" ]; then
    if ! find /lib /lib64 /usr/lib /usr/lib64 -name pam_google_authenticator.so 2>/dev/null | grep -q .; then
        echo "[!] Не найден модуль pam_google_authenticator.so. Выход (ничего не изменено)."
        exit 1
    fi
    echo "[+] google-authenticator и PAM-модуль есть"
fi

# Хост-ключи (создаст недостающие)
ssh-keygen -A >/dev/null 2>&1 || true
mkdir -p /run/sshd
chmod 0755 /run/sshd

# Текущая SSH-сессия: IP клиента и порт сервера
SSH_CONN="$(find_ssh_connection)"
CLIENT_IP=""
_srv_port=""
if [ -n "$SSH_CONN" ]; then
    CLIENT_IP="$(printf '%s' "$SSH_CONN" | awk '{print $1}')"
    _srv_port="$(printf '%s' "$SSH_CONN" | awk '{print $4}')"
fi

OLD_SSH_PORTS="$("$SSHD_BIN" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u | tr '\n' ' ' || true)"
if [ -n "$_srv_port" ]; then
    case " $OLD_SSH_PORTS " in
        *" $_srv_port "*) ;;
        *) OLD_SSH_PORTS="$OLD_SSH_PORTS $_srv_port" ;;
    esac
fi
read -ra _ports_arr <<< "$OLD_SSH_PORTS"
OLD_SSH_PORTS="${_ports_arr[*]}"
if [ -z "$OLD_SSH_PORTS" ]; then OLD_SSH_PORTS="22"; fi
echo "[+] Текущий порт(ы) SSH: $OLD_SSH_PORTS${CLIENT_IP:+, твой IP: $CLIENT_IP}"

# =============================================================================
# Шаг 1: группы
# =============================================================================
LAST_STEP="Шаг 1/10: группы"
echo ""
echo ">>> $LAST_STEP"
getent group sshusers >/dev/null 2>&1 || groupadd sshusers
getent group sudousers >/dev/null 2>&1 || groupadd sudousers
echo "[+] Группы sshusers, sudousers готовы"

# =============================================================================
# Шаг 2: пользователь + пароль root
# =============================================================================
LAST_STEP="Шаг 2/10: пользователь $NEW_USER_NAME и пароль root"
echo ">>> $LAST_STEP"

# Генерация обоих паролей
_up="$(gen_password)"
_rp="$(gen_password)"
_tries=0
while [ "$_rp" = "$_up" ] && [ "$_tries" -lt 5 ]; do
    _rp="$(gen_password)"
    _tries=$((_tries + 1))
done
if [ "${#_up}" -ne 16 ] || [ "${#_rp}" -ne 16 ] || [ "$_rp" = "$_up" ]; then
    echo "[!] Не удалось сгенерировать пароли (нет openssl и /dev/urandom?). Выход (ничего не изменено)."
    exit 1
fi

# Пароль нового пользователя
if id "$NEW_USER_NAME" &>/dev/null; then
    echo "[*] Пользователь $NEW_USER_NAME уже есть, добавляю в группы и задаю новый пароль..."
    usermod -aG sshusers,sudousers "$NEW_USER_NAME"
    echo "${NEW_USER_NAME}:${_up}" | chpasswd
    USER_PASSWORD="$_up"
    echo "[+] Группы обновлены, пароль сменён (новый — в конце вывода)"
else
    echo "[*] Создаю пользователя $NEW_USER_NAME со случайным паролем..."
    useradd -m -s /bin/bash -g sshusers -G sshusers,sudousers "$NEW_USER_NAME"
    echo "${NEW_USER_NAME}:${_up}" | chpasswd
    USER_PASSWORD="$_up"
    echo "[+] Пользователь создан, пароль установлен"
fi

# Пароль root
echo "[*] Меняю пароль root..."
cp -a /etc/shadow "$BACKUP_DIR/shadow.orig"
chmod 600 "$BACKUP_DIR/shadow.orig"
echo "root:${_rp}" | chpasswd
ROOT_PASSWORD="$_rp"
# Если пароль root был заблокирован (облачные образы) — chpasswd задаёт новый хеш;
# на всякий случай снимаем блокировку, чтобы работала консоль провайдера / su
passwd -u root >/dev/null 2>&1 || true
_rs="$(passwd -S root 2>/dev/null | awk '{print $2}' || true)"
case "$_rs" in
    P|PS) echo "[+] Пароль root сменён (новый — в конце вывода)" ;;
    *)    echo "[!] Пароль root установлен, но статус: '${_rs:-неизвестно}'. Проверь: passwd -S root" ;;
esac
unset _up _rp
echo "    Старый /etc/shadow сохранён в $BACKUP_DIR/shadow.orig"

# =============================================================================
# Шаг 3: sudo
# =============================================================================
LAST_STEP="Шаг 3/10: sudo"
echo ">>> $LAST_STEP"
mkdir -p /etc/sudoers.d
chmod 750 /etc/sudoers.d
if ! grep -qE '^[[:space:]]*[#@]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers 2>/dev/null; then
    cp -a /etc/sudoers "$BACKUP_DIR/sudoers.orig"
    echo '#includedir /etc/sudoers.d' >> /etc/sudoers
    echo "[*] В /etc/sudoers добавлен #includedir /etc/sudoers.d"
fi
_sud_tmp="$(mktemp)"
echo "%sudousers   ALL=(ALL:ALL) ALL" > "$_sud_tmp"
if ! visudo -cf "$_sud_tmp" >/dev/null; then
    rm -f "$_sud_tmp"
    echo "[!] visudo отверг правило sudoers. Выход."
    exit 1
fi
install -m 440 -o root -g root "$_sud_tmp" "$SUDOERS_FILE"
rm -f "$_sud_tmp"
if ! visudo -c >/dev/null; then
    echo "[!] visudo -c: ошибка в sudoers! Удаляю $SUDOERS_FILE."
    rm -f "$SUDOERS_FILE"
    exit 1
fi
if sudo -l -U "$NEW_USER_NAME" 2>/dev/null | grep -q "(ALL"; then
    echo "[+] sudo для $NEW_USER_NAME работает"
else
    echo "[!] Внимание: sudo -l не показывает прав для $NEW_USER_NAME — проверь вручную"
fi

# =============================================================================
# Шаг 4: SSH-ключ
# =============================================================================
LAST_STEP="Шаг 4/10: SSH-ключ"
echo ">>> $LAST_STEP"
if [ -z "$PUBKEY" ]; then
    echo "[*] Вставь публичный SSH-ключ (одна строка, cat ~/.ssh/id_ed25519.pub):"
    ask PUBKEY
fi
PUBKEY="${PUBKEY//$'\r'/}"
if [ -z "$PUBKEY" ]; then
    echo "Публичный ключ не введён. Выход."
    exit 1
fi
_kt="$(mktemp)"
printf '%s\n' "$PUBKEY" > "$_kt"
if ! ssh-keygen -l -f "$_kt" >/dev/null 2>&1; then
    rm -f "$_kt"
    echo "[!] Это не публичный SSH-ключ (нужна строка вида 'ssh-ed25519 AAAA... comment'). Выход."
    exit 1
fi
echo "[+] Ключ валиден: $(ssh-keygen -l -f "$_kt" 2>/dev/null)"
rm -f "$_kt"

USER_HOME="$(getent passwd "$NEW_USER_NAME" | cut -d: -f6)"
USER_GROUP="$(id -gn "$NEW_USER_NAME" 2>/dev/null || echo sshusers)"
mkdir -p "${USER_HOME}/.ssh"
touch "${USER_HOME}/.ssh/authorized_keys"
if grep -qxF "$PUBKEY" "${USER_HOME}/.ssh/authorized_keys"; then
    echo "[+] Ключ уже есть в authorized_keys"
else
    printf '%s\n' "$PUBKEY" >> "${USER_HOME}/.ssh/authorized_keys"
    echo "[+] Ключ записан в ${USER_HOME}/.ssh/authorized_keys"
fi
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"
chown -R "${NEW_USER_NAME}:${USER_GROUP}" "${USER_HOME}/.ssh"

# =============================================================================
# Шаг 5: sshd_config
# =============================================================================
LAST_STEP="Шаг 5/10: sshd_config"
echo ">>> $LAST_STEP"
backup_file "$SSHD_CONFIG"
SSH_CHANGED=1

KEX_WANT="mlkem768x25519-sha256,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256"
KEX_FALLBACK="curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256"
CIPHERS_WANT="chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
MACS_WANT="hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256"
KEX="$(filter_algos kex "$KEX_WANT" "$KEX_FALLBACK")"
CIPHERS="$(filter_algos cipher "$CIPHERS_WANT" "$CIPHERS_WANT")"
MACS="$(filter_algos mac "$MACS_WANT" "$MACS_WANT")"

HOSTKEY_LINES=""
for _k in /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_rsa_key; do
    if [ -f "$_k" ]; then
        HOSTKEY_LINES="${HOSTKEY_LINES}HostKey ${_k}"$'\n'
    fi
done
if [ -z "$HOSTKEY_LINES" ]; then
    echo "[!] Нет хост-ключей ed25519/rsa в /etc/ssh. Откат."
    exit 1
fi

echo "[*] Пишу блок настроек в начало $SSHD_CONFIG (первое значение в sshd имеет приоритет)..."
_block="$(mktemp)"
{
    echo "# >>> DSS BEGIN — dss.sh $SCRIPT_VERSION ($TS). Блок стоит первым и имеет приоритет."
    echo "Port $NEW_SSH_PORT"
    echo "AllowGroups sshusers"
    echo "PermitRootLogin no"
    echo "PasswordAuthentication no"
    echo "PermitEmptyPasswords no"
    echo "PubkeyAuthentication yes"
    printf '%s' "$HOSTKEY_LINES"
    echo "KexAlgorithms $KEX"
    echo "Ciphers $CIPHERS"
    echo "MACs $MACS"
    echo "LogLevel VERBOSE"
    echo "X11Forwarding no"
    echo "AllowTcpForwarding no"
    echo "MaxAuthTries 3"
    echo "ClientAliveInterval 120"
    echo "ClientAliveCountMax 2"
    echo "UsePAM yes"
    if [ "$ENABLE_2FA" = "y" ]; then
        echo "KbdInteractiveAuthentication yes"
        echo "AuthenticationMethods publickey,keyboard-interactive:pam"
    else
        echo "KbdInteractiveAuthentication no"
        echo "AuthenticationMethods publickey"
    fi
    echo "# <<< DSS END"
} > "$_block"

_rest="$(mktemp)"
awk -v re="^[ \t]*(${KEYS_RE})[ \t=]" '
    /^# >>> DSS BEGIN/ { skip = 1; next }
    /^# <<< DSS END/   { skip = 0; next }
    skip { next }
    /^[ \t]*[Mm][Aa][Tt][Cc][Hh][ \t]/ { m = 1 }
    { if (!m && tolower($0) ~ re) print "# DSS-disabled: " $0; else print }
' "$SSHD_CONFIG" > "$_rest"
cat "$_block" "$_rest" > "$SSHD_CONFIG"
rm -f "$_block" "$_rest"

if [ -d "$SSHD_CONFIG_D" ]; then
    for _f in "$SSHD_CONFIG_D"/*.conf; do
        if [ -f "$_f" ]; then
            disable_keys_in_file "$_f"
        fi
    done
fi

echo "[*] Проверка синтаксиса: sshd -t"
if ! "$SSHD_BIN" -t -f "$SSHD_CONFIG"; then
    echo "[!] sshd -t нашёл ошибку в конфиге. Откат."
    exit 1
fi
echo "[+] Синтаксис sshd_config в порядке"

echo "[*] Проверка эффективных значений: sshd -T"
if ! _eff="$("$SSHD_BIN" -T -f "$SSHD_CONFIG" 2>&1)"; then
    echo "[!] sshd -T завершился с ошибкой:"
    echo "$_eff"
    exit 1
fi
_eff_ports="$(printf '%s\n' "$_eff" | awk '$1=="port"{print $2}' | sort -u | tr '\n' ' ')"
read -ra _eff_arr <<< "$_eff_ports"
_eff_ports="${_eff_arr[*]}"
if [ "$_eff_ports" != "$NEW_SSH_PORT" ]; then
    echo "[!] Эффективный порт(ы) sshd: '$_eff_ports', ожидался '$NEW_SSH_PORT'. Откат."
    exit 1
fi
for _pair in "passwordauthentication no" "permitrootlogin no" "pubkeyauthentication yes"; do
    if ! printf '%s\n' "$_eff" | grep -qix "$_pair"; then
        echo "[!] Эффективное значение не '$_pair' (что-то перекрывает настройки). Откат."
        exit 1
    fi
done
echo "[+] Эффективный конфиг: Port $NEW_SSH_PORT, пароли и root запрещены"

# =============================================================================
# Шаг 6: PAM / 2FA
# =============================================================================
LAST_STEP="Шаг 6/10: PAM / 2FA"
echo ">>> $LAST_STEP"
if [ "$ENABLE_2FA" = "y" ]; then
    if [ ! -f "$PAM_SSHD" ]; then
        echo "[!] Нет $PAM_SSHD — 2FA через PAM невозможна. Откат."
        exit 1
    fi
    backup_file "$PAM_SSHD"
    _pam_tmp="$(mktemp)"
    {
        echo "# >>> DSS 2FA BEGIN"
        echo "auth       required     pam_google_authenticator.so nullok"
        echo "auth       required     pam_permit.so"
        echo "# <<< DSS 2FA END"
        sed -e '/^# >>> DSS 2FA BEGIN/,/^# <<< DSS 2FA END/d' \
            -e '/^[^#]*pam_google_authenticator/d' "$PAM_SSHD"
    } > "$_pam_tmp"
    cat "$_pam_tmp" > "$PAM_SSHD"
    rm -f "$_pam_tmp"
    # Debian/Ubuntu: не спрашивать пароль Unix после ключа + OTP
    if grep -qE '^[[:space:]]*@include[[:space:]]+common-auth' "$PAM_SSHD"; then
        sed -i -E 's/^([[:space:]]*@include[[:space:]]+common-auth.*)$/# DSS-disabled: \1/' "$PAM_SSHD"
        echo "[+] @include common-auth отключён"
    fi
    # RHEL/Rocky/Alma: то же самое для password-auth
    if grep -qE '^[[:space:]]*auth[[:space:]]+substack[[:space:]]+password-auth' "$PAM_SSHD"; then
        sed -i -E 's/^([[:space:]]*auth[[:space:]]+substack[[:space:]]+password-auth.*)$/# DSS-disabled: \1/' "$PAM_SSHD"
        echo "[+] auth substack password-auth отключён"
    fi
    echo "[+] PAM: ключ + OTP (nullok + pam_permit: без настроенного OTP вход только по ключу)"
else
    echo "[+] 2FA выключена — PAM не трогаю (вход только по ключу, PAM-auth не используется)"
fi

# =============================================================================
# Шаг 7: применение SSH (SELinux, ssh.socket, перезапуск, проверка порта)
# =============================================================================
LAST_STEP="Шаг 7/10: применение SSH"
echo ">>> $LAST_STEP"

if command -v getenforce &>/dev/null; then
    _se="$(getenforce 2>/dev/null || echo Disabled)"
    if [ "$_se" != "Disabled" ]; then
        echo "[*] SELinux: $_se — регистрирую порт $NEW_SSH_PORT как ssh_port_t..."
        if ! command -v semanage &>/dev/null; then
            pkg_install policycoreutils-python-utils >/dev/null 2>&1 || pkg_install policycoreutils-python >/dev/null 2>&1 || true
        fi
        _se_ok=0
        if command -v semanage &>/dev/null; then
            if semanage port -a -t ssh_port_t -p tcp "$NEW_SSH_PORT" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$NEW_SSH_PORT" 2>/dev/null; then
                _se_ok=1
            fi
        fi
        if [ "$_se_ok" = 1 ]; then
            echo "[+] SELinux: порт $NEW_SSH_PORT разрешён для sshd"
        elif [ "$_se" = "Enforcing" ]; then
            echo "[!] SELinux Enforcing, а порт зарегистрировать не удалось — sshd не сможет его открыть. Откат."
            exit 1
        else
            echo "[!] SELinux Permissive: порт не зарегистрирован (сейчас не мешает, но сделай: semanage port -a -t ssh_port_t -p tcp $NEW_SSH_PORT)"
        fi
    fi
fi

if [ -n "$SOCKET_UNIT" ]; then
    echo "[*] SSH работает через $SOCKET_UNIT (socket activation)."
    echo "    Переключаю на обычную службу $SSH_SERVICE, чтобы порт брался из sshd_config..."
    SSH_SERVICE_WAS_ENABLED="$(systemctl is-enabled "$SSH_SERVICE" 2>/dev/null || true)"
    SOCKET_SWITCHED=1
    systemctl disable --now "$SOCKET_UNIT"
    for _f in /etc/systemd/system/ssh.service.d/00-socket.conf /etc/systemd/system/ssh.socket.d/addresses.conf; do
        if [ -f "$_f" ]; then
            backup_file "$_f"
            rm -f "$_f"
        fi
    done
    systemctl daemon-reload
    systemctl enable "$SSH_SERVICE"
    echo "[+] $SOCKET_UNIT отключён, $SSH_SERVICE включён"
fi

SSH_RESTARTED=1
echo "[*] Перезапускаю $SSH_SERVICE..."
if ! systemctl restart "$SSH_SERVICE"; then
    echo "[!] $SSH_SERVICE не запустился:"
    journalctl -u "$SSH_SERVICE" -n 20 --no-pager 2>/dev/null || true
    exit 1
fi

_listen=1
for _i in 1 2 3 4 5 6 7 8 9 10; do
    _rc=0
    port_listening "$NEW_SSH_PORT" || _rc=$?
    if [ "$_rc" = 0 ]; then _listen=0; break; fi
    if [ "$_rc" = 2 ]; then _listen=2; break; fi
    sleep 1
done
if [ "$_listen" = 0 ]; then
    echo "[+] sshd слушает порт $NEW_SSH_PORT"
elif [ "$_listen" = 2 ]; then
    if systemctl is-active --quiet "$SSH_SERVICE"; then
        echo "[!] Утилиты ss нет — порт не проверить, но $SSH_SERVICE активен"
    else
        echo "[!] $SSH_SERVICE не активен. Откат."
        exit 1
    fi
else
    echo "[!] sshd НЕ слушает порт $NEW_SSH_PORT. Откат."
    journalctl -u "$SSH_SERVICE" -n 20 --no-pager 2>/dev/null || true
    exit 1
fi
SSH_APPLIED_OK=1

# =============================================================================
# Шаг 8: фаервол
# =============================================================================
LAST_STEP="Шаг 8/10: фаервол"
echo ">>> $LAST_STEP"
if systemctl is-active --quiet firewalld 2>/dev/null; then
    FIREWALL="firewalld"
    echo "[*] Активен firewalld — использую его (UFW рядом с firewalld ставить нельзя)"
    firewall-cmd --permanent --add-port="$NEW_SSH_PORT/tcp"
    if [ "$ENABLE_NETBIRD" = "y" ]; then
        firewall-cmd --permanent --add-port=51820/udp
    fi
    firewall-cmd --reload
    echo "[+] firewalld: открыт $NEW_SSH_PORT/tcp"
    if [ "$ENABLE_NETBIRD" = "y" ]; then echo "[+] firewalld: открыт 51820/udp (NetBird)"; fi
else
    if ! command -v ufw &>/dev/null; then
        echo "[*] Устанавливаю UFW..."
        if ! command -v apt-get &>/dev/null; then ensure_epel; fi
        pkg_install ufw || true
    fi
    if command -v ufw &>/dev/null; then
        FIREWALL="ufw"
        ufw default deny incoming
        ufw default allow outgoing
        ufw logging on
        ufw logging high
        ufw allow "$NEW_SSH_PORT/tcp" comment "SSH"
        if [ "$ENABLE_NETBIRD" = "y" ]; then
            ufw allow 51820/udp comment "NetBird"
        fi
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            echo "[+] UFW уже включён"
        else
            ufw --force enable
            echo "[+] UFW включён"
        fi
        if ufw status 2>/dev/null | grep -qE "^${NEW_SSH_PORT}/tcp[[:space:]]+ALLOW"; then
            echo "[+] UFW: правило $NEW_SSH_PORT/tcp активно"
        else
            echo "[!] UFW: правило для $NEW_SSH_PORT/tcp не найдено — выключаю UFW, чтобы не потерять доступ"
            ufw --force disable || true
            FIREWALL=""
        fi
    else
        echo "[!] UFW не установился; открой порт $NEW_SSH_PORT/tcp вручную"
        if [ "$ENABLE_NETBIRD" = "y" ]; then echo "[!] Также открой 51820/udp для NetBird"; fi
    fi
fi

# =============================================================================
# Шаг 9: fail2ban
# =============================================================================
LAST_STEP="Шаг 9/10: fail2ban"
echo ">>> $LAST_STEP"
if ! command -v fail2ban-client &>/dev/null; then
    echo "[*] Устанавливаю fail2ban..."
    if ! command -v apt-get &>/dev/null; then ensure_epel; fi
    pkg_install fail2ban || true
fi

if command -v fail2ban-client &>/dev/null; then
    if [ "$FIREWALL" = "ufw" ]; then
        command -v ipset &>/dev/null || pkg_install ipset || true
        F2B_BANACTION="iptables-ipset-proto6-allports"
    elif [ "$FIREWALL" = "firewalld" ]; then
        F2B_BANACTION="firewallcmd-allports"
    else
        F2B_BANACTION="iptables-allports"
    fi

    # Есть rsyslog → логи в файлах; нет → читаем journald
    if systemctl is-active --quiet rsyslog 2>/dev/null || systemctl is-active --quiet syslog-ng 2>/dev/null; then
        F2B_MODE="file"
    else
        F2B_MODE="journal"
        echo "[*] rsyslog не найден — fail2ban будет читать journald"
        pkg_install python3-systemd >/dev/null 2>&1 || true
    fi

    if [ "$F2B_MODE" = "journal" ]; then
        SSHD_SRC="backend = systemd
journalmatch = _COMM=sshd + _COMM=sshd-session"
        ALLPORTS_SRC="backend = systemd
journalmatch = _TRANSPORT=kernel"
    else
        SSHD_SRC="logpath = %(sshd_log)s"
        ALLPORTS_SRC="logpath = /var/log/ufw.log"
        if [ "$FIREWALL" = "ufw" ] && [ ! -f /var/log/ufw.log ]; then
            touch /var/log/ufw.log
            if id syslog &>/dev/null; then chown syslog:adm /var/log/ufw.log; fi
            chmod 640 /var/log/ufw.log
        fi
    fi

    cat > /etc/fail2ban/filter.d/allports.conf << 'FILTEREOF'
[Definition]
failregex = ^.*?\[UFW BLOCK\].*SRC=<HOST>.*$
ignoreregex =
FILTEREOF

    IGNOREIP_BASE="127.0.0.1/8 ::1"
    if [ -n "$CLIENT_IP" ]; then
        IGNOREIP_BASE="$IGNOREIP_BASE $CLIENT_IP"
        echo "[+] IP текущей SSH-сессии в ignoreip: $CLIENT_IP"
    else
        echo "[!] IP SSH-сессии не определён — добавь свой IP вручную ниже, иначе можешь забанить сам себя"
    fi
    printf "Доп. IP для ignoreip (через пробел, Enter — пропустить): "
    ask INPUT_IGNOREIP
    read -ra _ign_arr <<< "$INPUT_IGNOREIP"
    INPUT_IGNOREIP="${_ign_arr[*]}"
    IGNOREIP="$IGNOREIP_BASE${INPUT_IGNOREIP:+ $INPUT_IGNOREIP}"
    echo "[+] ignoreip: $IGNOREIP"

    if [ -f /etc/fail2ban/jail.local ]; then
        cp -a /etc/fail2ban/jail.local "$BACKUP_DIR/jail.local.orig"
    fi
    ALLPORTS_ENABLED="false"
    if [ "$FIREWALL" = "ufw" ]; then ALLPORTS_ENABLED="true"; fi

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 5
ignoreip = $IGNOREIP
banaction = $F2B_BANACTION

[sshd]
enabled = true
port = $NEW_SSH_PORT
filter = sshd
$SSHD_SRC
maxretry = 5
bantime = 24h

[allports]
enabled = $ALLPORTS_ENABLED
port = 0:65535
filter = allports
$ALLPORTS_SRC
maxretry = 5
bantime = 24h
EOF

    if fail2ban-client -t >/dev/null 2>&1; then
        echo "[+] Конфиг fail2ban валиден"
    else
        echo "[!] fail2ban-client -t нашёл ошибки:"
        fail2ban-client -t 2>&1 | tail -n 10 || true
    fi
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
    sleep 2
    if systemctl is-active --quiet fail2ban; then
        echo "[+] fail2ban работает (banaction: $F2B_BANACTION, режим: $F2B_MODE)"
    else
        echo "[!] fail2ban НЕ запустился. Смотри: journalctl -u fail2ban -n 30"
    fi
else
    echo "[!] fail2ban не установлен; установи вручную и настрой jail для порта $NEW_SSH_PORT"
fi

# =============================================================================
# Шаг 10: NetBird (опционально)
# =============================================================================
if [ "$ENABLE_NETBIRD" = "y" ]; then
    LAST_STEP="Шаг 10/10: NetBird"
    echo ""
    echo ">>> $LAST_STEP"
    if ! command -v curl &>/dev/null; then
        pkg_install curl || true
    fi
    if ! command -v curl &>/dev/null; then
        echo "[!] curl не найден; установи NetBird вручную: curl -fsSL https://pkgs.netbird.io/install.sh | sh"
    elif command -v netbird &>/dev/null; then
        echo "[+] NetBird уже установлен: $(netbird version 2>/dev/null || echo ok)"
    else
        if SKIP_UI_APP=true curl -fsSL https://pkgs.netbird.io/install.sh | sh; then
            echo "[+] NetBird установлен"
        else
            echo "[!] Установка NetBird не удалась. Вручную: SKIP_UI_APP=true curl -fsSL https://pkgs.netbird.io/install.sh | sh"
        fi
    fi
    if command -v netbird &>/dev/null; then
        systemctl enable netbird 2>/dev/null || true
        if [ -n "$NETBIRD_SETUP_KEY" ]; then
            if netbird up --setup-key "$NETBIRD_SETUP_KEY"; then
                echo "[+] NetBird подключён"
            else
                echo "[!] netbird up не удался. После скрипта: netbird up --setup-key <KEY>"
            fi
        else
            echo "[*] Setup key не задан. После скрипта: netbird up --setup-key <KEY>"
        fi
    fi
fi

# =============================================================================
# 2FA для пользователя
# =============================================================================
if [ "$ENABLE_2FA" = "y" ]; then
    LAST_STEP="2FA для $NEW_USER_NAME"
    echo ""
    echo "[*] Настройка 2FA для $NEW_USER_NAME."
    echo "    Отсканируй QR в приложении и СОХРАНИ аварийные коды (emergency scratch codes)."
    echo ""
    GA_FILE="${USER_HOME}/.google_authenticator"
    if sudo -H -u "$NEW_USER_NAME" google-authenticator -t -d -f -r 3 -R 30 -w 17 -s "$GA_FILE" && [ -f "$GA_FILE" ]; then
        echo "[+] 2FA настроен: $GA_FILE"
    else
        echo "[!] 2FA не настроился. Пока вход работает только по ключу (nullok)."
        echo "    Выполни: sudo -u $NEW_USER_NAME google-authenticator"
    fi
fi

# =============================================================================
# Итог
# =============================================================================
LAST_STEP="Итог"
echo ""
echo "=============================================="
echo "  СОХРАНИ ЭТИ ДАННЫЕ (менеджер паролей)"
echo "  Root по SSH отключён."
echo "=============================================="
echo "  Хост:           $(hostname)"
echo "  Порт SSH:       $NEW_SSH_PORT"
echo ""
echo "  Логин:          $NEW_USER_NAME"
echo "  Пароль:         $USER_PASSWORD   (для sudo)"
echo ""
echo "  Логин root:     root"
echo "  Пароль root:    $ROOT_PASSWORD   (консоль провайдера / su -)"
echo ""
echo "  Бэкапы:         $BACKUP_DIR"
echo ""
echo "  Подключение:"
echo "  ssh -p $NEW_SSH_PORT $NEW_USER_NAME@<IP_СЕРВЕРА>"
echo ""
if [ "$ENABLE_2FA" = "y" ]; then
    echo "  Вход:           ключ + код 2FA (OTP)"
else
    echo "  Вход:           только ключ"
fi
echo "  2FA:            $ENABLE_2FA"
echo "  Фаервол:        ${FIREWALL:-не настроен}"
if [ "$ENABLE_NETBIRD" = "y" ]; then
    echo "  NetBird:        установлен, открыт 51820/udp"
    if [ -z "$NETBIRD_SETUP_KEY" ]; then echo "                  выполни: netbird up --setup-key <KEY>"; fi
else
    echo "  NetBird:        нет"
fi
echo ""
echo "  Если у провайдера есть свой фаервол (Security Group) — открой там $NEW_SSH_PORT/tcp!"
echo "=============================================="
CREDS_SHOWN=1

# =============================================================================
# Финальная проверка входа с возможностью отката
# =============================================================================
echo ""
echo "=============================================="
echo "  ПРОВЕРКА ДОСТУПА — НЕ ЗАКРЫВАЙ ЭТУ СЕССИЮ!"
echo "=============================================="
echo "  Открой НОВЫЙ терминал и выполни:"
echo "    ssh -p $NEW_SSH_PORT $NEW_USER_NAME@<IP_СЕРВЕРА>"
echo "  Затем там же: sudo -v   (ввести пароль пользователя выше)"
echo "  И проверь root: su -    (ввести пароль root выше)"
echo ""
printf "Вход и sudo работают? (y — да, n — откатить настройки SSH) [y]: "
ask INPUT_CHECK
case "${INPUT_CHECK,,}" in
    n|no|н|нет)
        rollback_ssh
        echo ""
        echo "[!] SSH возвращён к исходному состоянию. Разберись с причиной и запусти скрипт снова."
        echo "[!] Пароли пользователя и root остались НОВЫМИ (см. выше)."
        ;;
    *)
        echo "[+] Отлично, доступ подтверждён."
        ;;
esac

echo ""
echo ">>> Всё готово. Хост: $(hostname)."
echo ">>> Скрипт $SCRIPT_VERSION завершён."

# Удалить локальную копию скрипта
SCRIPT_PATH=""
if [ -n "${BASH_SOURCE[0]}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"
elif [ -n "$0" ] && [ "$0" != "bash" ] && [ -f "$0" ]; then
    SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
fi
if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ] && [ -w "$SCRIPT_PATH" ]; then
    rm -f "$SCRIPT_PATH"
    echo "[+] Локальная копия скрипта удалена."
fi
exit 0
