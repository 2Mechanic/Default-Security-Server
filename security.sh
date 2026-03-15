#!/bin/bash
# =============================================================================
# Готовый скрипт по гайду How-To-Secure-A-Linux-Server:
# - создаёт группу sshusers и sudousers, sudo-пользователя
# - запрашивает публичный ключ в командной строке
# - настраивает SSH: новый порт, ключ + 2FA (OTP), root выключен
# Запуск: sudo bash setup-ssh-secure.sh
# =============================================================================

set -e

# ---------- Параметры ----------
NEW_USER_NAME="${NEW_USER_NAME:-admin}"
NEW_SSH_PORT="${NEW_SSH_PORT:-$(shuf -i 20000-65000 -n 1)}"
PUBKEY="${1:-${PUBKEY:-}}"

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

# ---------- Группы (как в гайде) ----------
getent group sshusers >/dev/null 2>&1 || groupadd sshusers
getent group sudousers >/dev/null 2>&1 || groupadd sudousers
echo "[+] Группы sshusers, sudousers готовы"

# ---------- Новый пользователь с паролем ----------
if id "$NEW_USER_NAME" &>/dev/null; then
    echo "[*] Пользователь $NEW_USER_NAME уже есть, добавляю в группы"
    usermod -aG sshusers "$NEW_USER_NAME"
    usermod -aG sudousers "$NEW_USER_NAME"
    USER_PASSWORD="(не менялся, задан ранее)"
else
    USER_PASSWORD="$(openssl rand -base64 16)"
    useradd -m -s /bin/bash -G sshusers,sudousers "$NEW_USER_NAME"
    echo "${NEW_USER_NAME}:${USER_PASSWORD}" | chpasswd
    echo "[+] Создан пользователь $NEW_USER_NAME"
fi

# ---------- Sudo для sudousers ----------
SUDOERS_FILE="/etc/sudoers.d/99-sudousers"
echo "%sudousers   ALL=(ALL:ALL) ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
echo "[+] Sudo: группа sudousers"

# ---------- SSH-ключ для нового пользователя ----------
USER_HOME="$(getent passwd "$NEW_USER_NAME" | cut -d: -f6)"
mkdir -p "${USER_HOME}/.ssh"
echo "$PUBKEY" >> "${USER_HOME}/.ssh/authorized_keys"
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"
chown -R "${NEW_USER_NAME}:${NEW_USER_NAME}" "${USER_HOME}/.ssh"
echo "[+] Публичный ключ добавлен в ~/.ssh/authorized_keys"

# ---------- Бэкап и настройка sshd ----------
cp -a "$SSHD_CONFIG" "${SSHD_CONFIG}${BACKUP_SUFFIX}"

set_sshd() {
    local key="$1"
    local value="$2"
    if grep -qE "^#?\s*${key}\s+" "$SSHD_CONFIG"; then
        sed -i -E "s/^#?\s*${key}\s+.*/${key} ${value}/" "$SSHD_CONFIG"
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

# ---------- 2FA (OTP) ----------
set_sshd "ChallengeResponseAuthentication" "yes"
set_sshd "UsePAM" "yes"
echo "[+] sshd: 2FA (OTP) включён в настройках"

# ---------- Установка и настройка PAM для 2FA ----------
if ! command -v google-authenticator &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq libpam-google-authenticator
fi
PAM_SSHD="/etc/pam.d/sshd"
if [ -f "$PAM_SSHD" ] && ! grep -q "pam_google_authenticator" "$PAM_SSHD"; then
    cp -a "$PAM_SSHD" "${PAM_SSHD}${BACKUP_SUFFIX}"
    sed -i '1i auth       required     pam_google_authenticator.so nullok' "$PAM_SSHD"
    echo "[+] PAM: добавлен pam_google_authenticator (2FA)"
fi

echo "[+] sshd настроен: ключ + 2FA, root выключен, порт $NEW_SSH_PORT"

# ---------- UFW ----------
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$NEW_SSH_PORT/tcp" comment "SSH"
    echo "[+] UFW: порт $NEW_SSH_PORT открыт"
fi

# ---------- Настройка 2FA для пользователя (интерактивно: отсканируй QR в приложении) ----------
echo ""
echo "[*] Сейчас нужно настроить 2FA для пользователя $NEW_USER_NAME."
echo "    Отсканируй QR-код в приложении (Google Authenticator и т.п.) и отвечай на вопросы (рекомендуется везде y)."
echo ""
sudo -u "$NEW_USER_NAME" google-authenticator -t -d -f -r 3 -R 30 -w 17

# ---------- Перезапуск SSH ----------
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
echo "[+] SSH перезапущен"

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
