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

echo ">>> v2 — chown по USER_GROUP (id -gn), не user:user"
echo ">>> Хост: $(hostname). Запуск на этом сервере. Пользователь: root."
echo ">>> Если настраиваешь другой сервер — зайди на него по SSH и запусти скрипт там."
echo ""

# ---------- Параметры ----------
# Сбрасываем env, чтобы не подхватить admin с сервера — дефолт только из скрипта
unset NEW_USER_NAME
NEW_USER_NAME="${NEW_USER_NAME:-snegg000}"
PUBKEY="${1:-${PUBKEY:-}}"
# Порт: без shuf (не везде есть) — fallback на $RANDOM
if [ -z "$NEW_SSH_PORT" ]; then
    if command -v shuf &>/dev/null; then
        NEW_SSH_PORT=$(shuf -i 20000-65000 -n 1)
    else
        NEW_SSH_PORT=$((20000 + RANDOM % 45001))
    fi
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_SUFFIX="-BACKUP-$(date +%Y%m%d%H%M%S)"

# ---------- Запрос публичного ключа, если не передан ----------
if [ -z "$PUBKEY" ]; then
    echo "Вставь публичный SSH-ключ (одна строка, например из cat ~/.ssh/id_ed25519.pub):"
    read -r PUBKEY
fi
if [ -z "$PUBKEY" ]; then
    echo "Публичный ключ не введён. Выход."
    exit 1
fi

echo "[*] Пользователь: $NEW_USER_NAME"
echo "[*] Порт SSH: $NEW_SSH_PORT"
echo ""

# ---------- Группы (как в гайде) ----------
LAST_STEP="Шаг 1/7: группы"
echo ">>> $LAST_STEP"
getent group sshusers >/dev/null 2>&1 || groupadd sshusers
getent group sudousers >/dev/null 2>&1 || groupadd sudousers
echo "[+] Группы sshusers, sudousers готовы"

# ---------- Новый пользователь с паролем ----------
LAST_STEP="Шаг 2/7: пользователь $NEW_USER_NAME"
echo ">>> $LAST_STEP"
if id "$NEW_USER_NAME" &>/dev/null; then
    echo "[*] Пользователь $NEW_USER_NAME уже есть, добавляю в группы"
    usermod -aG sshusers "$NEW_USER_NAME"
    usermod -aG sudousers "$NEW_USER_NAME"
    USER_PASSWORD="(не менялся, задан ранее)"
else
    USER_PASSWORD="$(openssl rand -base64 16)"
    useradd -m -s /bin/bash -g sshusers -G sshusers,sudousers "$NEW_USER_NAME"
    echo "${NEW_USER_NAME}:${USER_PASSWORD}" | chpasswd
    echo "[+] Создан пользователь $NEW_USER_NAME"
fi

# ---------- Sudo для sudousers ----------
LAST_STEP="Шаг 3/7: sudo"
echo ">>> $LAST_STEP"
SUDOERS_FILE="/etc/sudoers.d/99-sudousers"
echo "%sudousers   ALL=(ALL:ALL) ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
echo "[+] Sudo: группа sudousers"

# ---------- SSH-ключ для нового пользователя ----------
LAST_STEP="Шаг 4/7: SSH-ключ"
echo ">>> $LAST_STEP"
USER_HOME="$(getent passwd "$NEW_USER_NAME" | cut -d: -f6)"
USER_GROUP="$(id -gn "$NEW_USER_NAME" 2>/dev/null)" || USER_GROUP="sshusers"
mkdir -p "${USER_HOME}/.ssh"
echo "$PUBKEY" >> "${USER_HOME}/.ssh/authorized_keys"
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"
chown -R "${NEW_USER_NAME}:${USER_GROUP}" "${USER_HOME}/.ssh"
echo "[+] Публичный ключ добавлен в ~/.ssh/authorized_keys"

# ---------- Бэкап и настройка sshd ----------
LAST_STEP="Шаг 5/7: sshd_config"
echo ">>> $LAST_STEP"
cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}${BACKUP_SUFFIX}"

set_sshd() {
    local key="$1"
    local value="$2"
    if grep -qE "^#?\s*${key}\s+" "$SSHD_CONFIG"; then
        sed -i -E "s|^#?\s*${key}\s+.*|${key} ${value}|" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

# Порт и только пользователи из sshusers
set_sshd "Port" "$NEW_SSH_PORT"
set_sshd "AllowGroups" "sshusers"
set_sshd "PermitRootLogin" "no"
set_sshd "PasswordAuthentication" "no"
set_sshd "PubkeyAuthentication" "yes"

# Алгоритмы (Mozilla)
set_sshd "HostKey" "/etc/ssh/ssh_host_ed25519_key"
set_sshd "HostKey" "/etc/ssh/ssh_host_rsa_key"
set_sshd "KexAlgorithms" "curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256"
set_sshd "Ciphers" "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
set_sshd "MACs" "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256"
set_sshd "LogLevel" "VERBOSE"

set_sshd "X11Forwarding" "no"
set_sshd "AllowTcpForwarding" "no"
set_sshd "PermitEmptyPasswords" "no"
set_sshd "MaxAuthTries" "3"
set_sshd "ClientAliveInterval" "120"
set_sshd "ClientAliveCountMax" "2"

# ---------- 2FA (OTP): ключ сначала, потом запрос кода ----------
set_sshd "UsePAM" "yes"
set_sshd "ChallengeResponseAuthentication" "yes"
set_sshd "KbdInteractiveAuthentication" "yes"
set_sshd "AuthenticationMethods" "publickey,keyboard-interactive:pam"
echo "[+] sshd: 2FA (OTP) включён в настройках"

# Проверка: порт реально записан в конфиг
if grep -qE "^Port\s+${NEW_SSH_PORT}" "$SSHD_CONFIG"; then
    echo "[+] Проверка: в $SSHD_CONFIG записан Port $NEW_SSH_PORT"
else
    echo "[!] Ошибка: Port $NEW_SSH_PORT не найден в $SSHD_CONFIG"
    exit 1
fi

# ---------- Установка и настройка PAM для 2FA ----------
LAST_STEP="Шаг 6/7: PAM / 2FA"
echo ">>> $LAST_STEP"
if ! command -v google-authenticator &>/dev/null; then
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
fi
PAM_SSHD="/etc/pam.d/sshd"
if [ -f "$PAM_SSHD" ] && ! grep -q "pam_google_authenticator" "$PAM_SSHD"; then
    cp -a "$PAM_SSHD" "${PAM_SSHD}${BACKUP_SUFFIX}"
    sed -i '1i auth       required     pam_google_authenticator.so nullok' "$PAM_SSHD"
    echo "[+] PAM: добавлен pam_google_authenticator (2FA)"
fi
if [ -f "$PAM_SSHD" ]; then
    grep -q "pam_google_authenticator" "$PAM_SSHD" && echo "[+] Проверка: строка pam_google_authenticator есть в $PAM_SSHD"
fi

echo "[+] sshd настроен: ключ + 2FA, root выключен, порт $NEW_SSH_PORT"

# ---------- UFW: как в гайде — default deny, allow outgoing, логирование, SSH ----------
LAST_STEP="Шаг 7/7: UFW"
echo ">>> $LAST_STEP"
if command -v ufw &>/dev/null; then
    ufw default deny incoming
    ufw default allow outgoing
    echo "[+] UFW: default deny incoming, allow outgoing"
    ufw logging on
    ufw logging high
    echo "[+] UFW: логирование включено (high), логи: /var/log/ufw.log"
    ufw allow "$NEW_SSH_PORT/tcp" comment "SSH"
    echo "[+] UFW: добавлено правило — порт $NEW_SSH_PORT/tcp"
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "[+] UFW уже включён, правила применились"
    else
        echo "[!] UFW установлен, но выключен. Включи после проверки входа: ufw enable"
    fi
else
    echo "[*] UFW не установлен; если пользуешься фаерволом — открой порт $NEW_SSH_PORT вручную"
fi

# ---------- Настройка 2FA для пользователя (интерактивно: отсканируй QR в приложении) ----------
echo ""
echo "[*] Настройка 2FA для пользователя $NEW_USER_NAME."
echo "    Отсканируй QR в приложении (Google Authenticator и т.п.), на вопросы отвечай y."
echo ""
if sudo -u "$NEW_USER_NAME" google-authenticator -t -d -f -r 3 -R 30 -w 17 2>/dev/null; then
    echo "[+] 2FA настроен."
else
    echo "[!] 2FA не настроился (нет терминала или ошибка). После первого входа по SSH выполни:"
    echo "    sudo -u $NEW_USER_NAME google-authenticator"
    echo "    Ответь y на все вопросы, отсканируй QR, затем перезапусти SSH: systemctl restart sshd"
fi

# ---------- Перезапуск SSH ----------
if systemctl restart sshd 2>/dev/null; then
    echo "[+] SSH перезапущен (sshd)"
elif systemctl restart ssh 2>/dev/null; then
    echo "[+] SSH перезапущен (ssh)"
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
echo "  Вход: ключ + код 2FA (OTP). Пароль нужен для sudo."
echo "=============================================="
echo ""
echo ">>> Всё готово. Изменения применены на этом хосте ($(hostname))."
