#!/bin/bash
# =============================================================================
# Готовый скрипт по гайду How-To-Secure-A-Linux-Server.
# Запуск ТОЛЬКО на целевом Linux-сервере: ssh user@сервер → там: sudo bash setup-ssh-secure.sh
# Если падает с "command not found" — на сервере выполни: sed -i 's/\r$//' setup-ssh-secure.sh
# =============================================================================

set -e
[ -n "$DEBUG" ] && set -x
LAST_STEP=""
trap 'echo ""; echo "[!] Скрипт упал. Последний шаг: $LAST_STEP"; echo "    Запусти с отладкой: DEBUG=1 sudo bash setup-ssh-secure.sh"; exit 1' ERR

# ---------- Обязательно root ----------
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: запускай с root. Пример: sudo bash setup-ssh-secure.sh"
    exit 1
fi

# ---------- Обязательно Linux с useradd/groupadd ----------
if ! command -v useradd &>/dev/null || ! command -v groupadd &>/dev/null; then
    echo "Ошибка: нужен Linux с useradd/groupadd (Debian/Ubuntu/CentOS). Запускай скрипт НА СЕРВЕРЕ, не на своём ПК."
    exit 1
fi

echo ">>> v5 — при существующем пользователе пароль всегда новый (выводится в конце)"
echo ">>> Хост: $(hostname). Запуск на этом сервере. Пользователь: root."
echo ""

# ---------- Параметры ----------
echo "[*] Параметры..."
echo ""
printf "Введите желаемый логин [по умолчанию snegg000]: "
read -r INPUT_USER
NEW_USER_NAME="${INPUT_USER:-snegg000}"
NEW_USER_NAME="${NEW_USER_NAME// /}"
[ -z "$NEW_USER_NAME" ] && NEW_USER_NAME="snegg000"

printf "Включать 2FA (OTP по коду из приложения)? (y/n) [y]: "
read -r INPUT_2FA
ENABLE_2FA="${INPUT_2FA:-y}"
ENABLE_2FA="${ENABLE_2FA,,}"
[ "$ENABLE_2FA" != "n" ] && [ "$ENABLE_2FA" != "no" ] && ENABLE_2FA="y" || ENABLE_2FA="n"

PUBKEY="${1:-${PUBKEY:-}}"
if [ -z "$NEW_SSH_PORT" ]; then
    if command -v shuf &>/dev/null; then
        NEW_SSH_PORT=$(shuf -i 20000-65000 -n 1)
    else
        NEW_SSH_PORT=$((20000 + RANDOM % 45001))
    fi
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_SUFFIX="-BACKUP-$(date +%Y%m%d%H%M%S)"

echo "[+] Пользователь: $NEW_USER_NAME, порт SSH: $NEW_SSH_PORT"
echo ""

# ---------- Группы (как в гайде) ----------
LAST_STEP="Шаг 1/8: группы"
echo ""
echo ">>> $LAST_STEP"
echo "[*] Создаю группы sshusers и sudousers..."
getent group sshusers >/dev/null 2>&1 || groupadd sshusers
getent group sudousers >/dev/null 2>&1 || groupadd sudousers
echo "[+] Группы sshusers, sudousers готовы"

# ---------- Новый пользователь с паролем ----------
LAST_STEP="Шаг 2/8: пользователь $NEW_USER_NAME"
echo ">>> $LAST_STEP"
if id "$NEW_USER_NAME" &>/dev/null; then
    echo "[*] Пользователь $NEW_USER_NAME уже есть, добавляю в группы и задаю новый пароль..."
    usermod -aG sshusers "$NEW_USER_NAME"
    usermod -aG sudousers "$NEW_USER_NAME"
    USER_PASSWORD="$(openssl rand -base64 16)"
    echo "${NEW_USER_NAME}:${USER_PASSWORD}" | chpasswd
    echo "[+] Группы обновлены, пароль сменён (новый — в конце вывода)"
else
    echo "[*] Создаю пользователя $NEW_USER_NAME с случайным паролем..."
    USER_PASSWORD="$(openssl rand -base64 16)"
    useradd -m -s /bin/bash -g sshusers -G sshusers,sudousers "$NEW_USER_NAME"
    echo "${NEW_USER_NAME}:${USER_PASSWORD}" | chpasswd
    echo "[+] Пользователь создан, пароль установлен"
fi

# ---------- Sudo для sudousers ----------
LAST_STEP="Шаг 3/8: sudo"
echo ">>> $LAST_STEP"
echo "[*] Настраиваю sudo для группы sudousers..."
SUDOERS_FILE="/etc/sudoers.d/99-sudousers"
echo "%sudousers   ALL=(ALL:ALL) ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
echo "[+] Файл $SUDOERS_FILE создан"

# ---------- SSH-ключ для нового пользователя ----------
LAST_STEP="Шаг 4/8: SSH-ключ"
echo ">>> $LAST_STEP"
if [ -z "$PUBKEY" ]; then
    echo "[*] Вставь публичный SSH-ключ (одна строка, cat ~/.ssh/id_ed25519.pub):"
    read -r PUBKEY
fi
if [ -z "$PUBKEY" ]; then
    echo "Публичный ключ не введён. Выход."
    exit 1
fi
echo "[*] Добавляю ключ в authorized_keys пользователя $NEW_USER_NAME..."
USER_HOME="$(getent passwd "$NEW_USER_NAME" | cut -d: -f6)"
USER_GROUP="$(id -gn "$NEW_USER_NAME" 2>/dev/null)" || USER_GROUP="sshusers"
mkdir -p "${USER_HOME}/.ssh"
echo "$PUBKEY" >> "${USER_HOME}/.ssh/authorized_keys"
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"
chown -R "${NEW_USER_NAME}:${USER_GROUP}" "${USER_HOME}/.ssh"
echo "[+] Ключ записан в ${USER_HOME}/.ssh/authorized_keys"

# ---------- Бэкап и настройка sshd ----------
LAST_STEP="Шаг 5/8: sshd_config"
echo ">>> $LAST_STEP"
echo "[*] Бэкап конфига: ${SSHD_CONFIG}${BACKUP_SUFFIX}"
cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}${BACKUP_SUFFIX}"

set_sshd() {
    local key="$1"
    local value="$2"
    if grep -qE "^#?[[:space:]]*${key}[[:space:]]+" "$SSHD_CONFIG"; then
        sed -i -E "s#^\\#?[[:space:]]*${key}[[:space:]]+.*#${key} ${value}#" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

echo "[*] Настраиваю sshd: порт, группы, аутентификация..."
set_sshd "Port" "$NEW_SSH_PORT"
set_sshd "AllowGroups" "sshusers"
set_sshd "PermitRootLogin" "no"
set_sshd "PasswordAuthentication" "no"
set_sshd "PubkeyAuthentication" "yes"

echo "[*] Настраиваю sshd: алгоритмы (Mozilla)..."
set_sshd "HostKey" "/etc/ssh/ssh_host_ed25519_key"
set_sshd "HostKey" "/etc/ssh/ssh_host_rsa_key"
set_sshd "KexAlgorithms" "curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256"
set_sshd "Ciphers" "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
set_sshd "MACs" "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256"
set_sshd "LogLevel" "VERBOSE"

echo "[*] Настраиваю sshd: ограничения сессии..."
set_sshd "X11Forwarding" "no"
set_sshd "AllowTcpForwarding" "no"
set_sshd "PermitEmptyPasswords" "no"
set_sshd "MaxAuthTries" "3"
set_sshd "ClientAliveInterval" "120"
set_sshd "ClientAliveCountMax" "2"

if [ "$ENABLE_2FA" = "y" ]; then
    echo "[*] Настраиваю sshd: 2FA (OTP)..."
    set_sshd "UsePAM" "yes"
    set_sshd "ChallengeResponseAuthentication" "yes"
    set_sshd "KbdInteractiveAuthentication" "yes"
    set_sshd "AuthenticationMethods" "publickey,keyboard-interactive:pam"
    echo "[+] sshd_config: ключ + 2FA"
else
    echo "[*] Настраиваю sshd: вход только по ключу (без 2FA)..."
    set_sshd "UsePAM" "yes"
    set_sshd "AuthenticationMethods" "publickey"
    echo "[+] sshd_config: только ключ"
fi
echo "[+] sshd_config записан, порт $NEW_SSH_PORT"

# Проверка: порт реально записан в конфиг
if grep -qE "^Port\s+${NEW_SSH_PORT}" "$SSHD_CONFIG"; then
    echo "[+] Проверка: в $SSHD_CONFIG записан Port $NEW_SSH_PORT"
else
    echo "[!] Ошибка: Port $NEW_SSH_PORT не найден в $SSHD_CONFIG"
    exit 1
fi

# ---------- Установка и настройка PAM (2FA по желанию) ----------
LAST_STEP="Шаг 6/8: PAM / 2FA"
echo ">>> $LAST_STEP"
PAM_SSHD="/etc/pam.d/sshd"
if [ "$ENABLE_2FA" = "y" ]; then
    if ! command -v google-authenticator &>/dev/null; then
        echo "[*] Устанавливаю libpam-google-authenticator..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq libpam-google-authenticator
        elif command -v dnf &>/dev/null; then
            dnf install -y libpam-google-authenticator
        elif command -v yum &>/dev/null; then
            yum install -y libpam-google-authenticator
        else
            echo "[!] Установи вручную: libpam-google-authenticator (apt/dnf/yum)"
            exit 1
        fi
        echo "[+] Пакет установлен"
    fi
    if [ -f "$PAM_SSHD" ] && ! grep -q "pam_google_authenticator" "$PAM_SSHD"; then
        echo "[*] Добавляю pam_google_authenticator в $PAM_SSHD..."
        cp -a "$PAM_SSHD" "${PAM_SSHD}${BACKUP_SUFFIX}"
        sed -i '1i auth       required     pam_google_authenticator.so nullok' "$PAM_SSHD"
        echo "[+] PAM: 2FA включён"
    fi
fi
if [ -f "$PAM_SSHD" ] && grep -qE "^[^#]*@include.*common-auth" "$PAM_SSHD"; then
    echo "[*] Отключаю запрос пароля при SSH (вход по ключу без пароля)..."
    sed -i -E 's/^([^#]*@include.*common-auth)/# \1  # отключено: ключ без пароля/' "$PAM_SSHD"
    echo "[+] Пароль при входе по SSH отключён"
fi
echo "[+] PAM для sshd настроен"

# ---------- UFW: установка (если нет), настройка, включение ----------
LAST_STEP="Шаг 7/8: UFW"
echo ">>> $LAST_STEP"
echo "[*] Настраиваю UFW..."
if ! command -v ufw &>/dev/null; then
    echo "[*] Uстанавливаю UFW..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y ufw
    elif command -v dnf &>/dev/null; then
        dnf install -y ufw
    elif command -v yum &>/dev/null; then
        yum install -y ufw
    fi
fi
if command -v ufw &>/dev/null; then
    echo "[*] UFW: задаю политики по умолчанию (deny incoming, allow outgoing)..."
    ufw default deny incoming
    ufw default allow outgoing
    echo "[+] UFW: политики заданы"
    echo "[*] UFW: включаю логирование (уровень high)..."
    ufw logging on
    ufw logging high
    echo "[+] UFW: логи в /var/log/ufw.log"
    echo "[*] UFW: разрешаю порт $NEW_SSH_PORT/tcp для SSH..."
    ufw allow "$NEW_SSH_PORT/tcp" comment "SSH"
    echo "[+] UFW: правило для порта $NEW_SSH_PORT добавлено"
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "[+] UFW уже включён"
    else
        echo "[*] UFW: включаю фаервол (порт $NEW_SSH_PORT уже разрешён)..."
        ufw --force enable
        echo "[+] UFW включён"
    fi
    echo "[+] Настройка UFW завершена"
else
    echo "[!] UFW не установился; открой порт $NEW_SSH_PORT вручную в фаерволе"
fi

# ---------- Fail2ban по гайду: ожидание apt lock, установка, sshd jail ----------
LAST_STEP="Шаг 8/8: fail2ban"
echo ">>> $LAST_STEP"
echo "[*] Настраиваю fail2ban (защита от перебора SSH)..."

wait_apt() {
    local i=0
    while true; do
        if command -v fuser &>/dev/null; then
            fuser -s /var/lib/dpkg/lock-frontend 2>/dev/null || fuser -s /var/lib/dpkg/lock 2>/dev/null || break
        else
            [ -f /var/lib/dpkg/lock-frontend ] || [ -f /var/lib/dpkg/lock ] || break
        fi
        [ $i -eq 0 ] && echo "[*] Ожидаю освобождения apt/dpkg (unattended-upgrades или другой процесс)..."
        sleep 5
        i=$((i + 1))
        [ $i -ge 24 ] && { echo "[!] apt занят больше 2 мин, пропускаю установку fail2ban"; return 1; }
    done
    return 0
}

install_f2b() {
    if command -v apt-get &>/dev/null; then
        wait_apt || return 1
        echo "[*] Обновляю список пакетов..."
        apt-get update -qq || true
        wait_apt || return 1
        echo "[*] Устанавливаю пакет fail2ban (вывод ниже)..."
        apt-get install -y fail2ban || return 1
    elif command -v dnf &>/dev/null; then
        echo "[*] Устанавливаю fail2ban (dnf)..."
        dnf install -y fail2ban || return 1
    elif command -v yum &>/dev/null; then
        echo "[*] Устанавливаю fail2ban (yum)..."
        yum install -y fail2ban || return 1
    else
        echo "[!] Нет apt/dnf/yum; установи fail2ban вручную"
        return 1
    fi
}

if ! command -v fail2ban-client &>/dev/null; then
    if ! install_f2b; then
        echo "[!] Установка fail2ban не удалась. После скрипта выполни вручную:"
        echo "    sudo apt-get update && sudo apt-get install -y fail2ban"
    fi
fi
if command -v fail2ban-client &>/dev/null; then
    F2B_JAIL="/etc/fail2ban/jail.local"
    F2B_FILTER_ALLPORTS="/etc/fail2ban/filter.d/allports.conf"
    echo "[*] Создаю фильтр allports (UFW BLOCK) и $F2B_JAIL..."
    cat > "$F2B_FILTER_ALLPORTS" << 'FILTEREOF'
[Definition]
failregex = ^.*?\[UFW BLOCK\].*SRC=<HOST>.*$
ignoreregex =
FILTEREOF
    echo "[*] Создаю $F2B_JAIL (jail sshd + allports)..."
    if command -v ufw &>/dev/null; then
        BANACTION="banaction = ufw"
    else
        BANACTION=""
    fi
    cat > "$F2B_JAIL" << EOF
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 179.43.176.163
$BANACTION

[sshd]
enabled = true
port = $NEW_SSH_PORT
filter = sshd
logpath = %(sshd_log)s
maxretry = 5
bantime = 24h

[allports]
enabled = true
port = 0:65535
filter = allports
logpath = /var/log/ufw.log
maxretry = 5
bantime = 24h
EOF
    echo "[+] Конфиг записан: bantime 24h, findtime 10m, maxretry 5"
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    echo "[+] fail2ban включён и перезапущен"
else
    echo "[*] fail2ban не установлен; установи вручную и настрой jail для порта $NEW_SSH_PORT"
fi

# ---------- Настройка 2FA для пользователя (если включено) ----------
if [ "$ENABLE_2FA" = "y" ]; then
    echo ""
    echo "[*] Настройка 2FA для пользователя $NEW_USER_NAME..."
    echo "    Отсканируй QR в приложении (Google Authenticator и т.п.), на вопросы отвечай y."
    echo ""
    if sudo -u "$NEW_USER_NAME" google-authenticator -t -d -f -r 3 -R 30 -w 17 2>/dev/null; then
        echo "[+] 2FA настроен."
    else
        echo "[!] 2FA не настроился (нет терминала или ошибка). После первого входа по SSH выполни:"
        echo "    sudo -u $NEW_USER_NAME google-authenticator"
        echo "    Ответь y на все вопросы, отсканируй QR, затем перезапусти SSH: systemctl restart sshd"
    fi
fi

# ---------- Перезапуск SSH ----------
echo "[*] Перезапускаю службу SSH..."
if systemctl restart sshd 2>/dev/null; then
    echo "[+] Служба sshd перезапущена"
elif systemctl restart ssh 2>/dev/null; then
    echo "[+] Служба ssh перезапущена"
else
    echo "[!] Не удалось перезапустить SSH (sshd/ssh). Выполни вручную: systemctl restart sshd или systemctl restart ssh"
    exit 1
fi

# ---------- Итог: логин, пароль, порт ----------
echo ""
echo "=============================================="
echo "  Сохрани эти данные. Root по SSH отключён."
echo "=============================================="
echo "  Логин:       $NEW_USER_NAME"
echo "  Пароль:      $USER_PASSWORD"
echo "  Порт SSH:    $NEW_SSH_PORT"
echo ""
echo "  Подключение:"
echo "  ssh -p $NEW_SSH_PORT $NEW_USER_NAME@<IP_СЕРВЕРА>"
echo ""
if [ "$ENABLE_2FA" = "y" ]; then
    echo "  Вход: ключ + код 2FA (OTP). Пароль нужен для sudo."
else
    echo "  Вход: только ключ. Пароль нужен для sudo."
fi
echo "=============================================="
echo ""
echo ">>> Всё готово. Изменения применены на этом хосте ($(hostname))."
echo ">>> Скрипт v5 завершён."

# Удалить локальную копию скрипта (если запускали файл, а не curl | bash)
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
