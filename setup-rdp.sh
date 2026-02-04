#!/usr/bin/env bash
set -euo pipefail

# Ensure running as root
if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root or with sudo"
  exit 1
fi

# ---- Prompt / Validate user ----
read -rp "Enter the username for RDP: " RDP_USER
if [[ -z "${RDP_USER}" ]]; then
  echo "Error: username cannot be empty."
  exit 1
fi

if ! id "${RDP_USER}" >/dev/null 2>&1; then
  echo "Error: User '${RDP_USER}' does not exist."
  exit 1
fi

USER_HOME="$(getent passwd "${RDP_USER}" | cut -d: -f6)"
if [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]]; then
  echo "Error: Could not determine home directory for '${RDP_USER}'."
  exit 1
fi

echo "--- Installing Full Stack (Ubuntu 24.04 Desktop) ---"
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y openssh-server xrdp xorgxrdp dbus-x11 xserver-xorg-core

# ---- 1) Configure XRDP to listen only on localhost (idempotent) ----
XRDP_INI="/etc/xrdp/xrdp.ini"
RDP_BIND="127.0.0.1"
RDP_PORT="3389"
PORT_LINE="port=tcp://${RDP_BIND}:${RDP_PORT}"

if [[ ! -f "${XRDP_INI}" ]]; then
  echo "Error: ${XRDP_INI} not found."
  exit 1
fi

# Ensure exactly one correct port line exists in [Globals]
# - remove any existing port= lines within [Globals]
# - then ensure the correct one is present within [Globals]
sed -i '/^\[Globals\]/,/^\[/{s/^port=.*/__DELETE__&/;}' "${XRDP_INI}"
sed -i '/^__DELETE__port=/d' "${XRDP_INI}"

if ! awk '
  BEGIN{in=0; ok=0}
  /^\[Globals\]/{in=1; next}
  /^\[/{in=0}
  in && $0=="'"${PORT_LINE}"'" {ok=1}
  END{exit ok?0:1}
' "${XRDP_INI}"; then
  # Insert right after [Globals]
  sed -i "/^\[Globals\]/a ${PORT_LINE}" "${XRDP_INI}"
fi

# ---- 2) SSL group membership for xrdp (idempotent) ----
usermod -aG ssl-cert xrdp

# Some installs have these; set perms if present
if [[ -f /etc/xrdp/key.pem ]]; then
  chown root:ssl-cert /etc/xrdp/key.pem
  chmod 640 /etc/xrdp/key.pem
fi
if [[ -f /etc/xrdp/cert.pem ]]; then
  chown root:ssl-cert /etc/xrdp/cert.pem
  chmod 640 /etc/xrdp/cert.pem
fi

# ---- 3) X11 Wrapper permissions (idempotent) ----
mkdir -p /etc/X11
XWRAP="/etc/X11/Xwrapper.config"
if [[ -f "${XWRAP}" ]]; then
  if grep -q '^allowed_users=' "${XWRAP}"; then
    sed -i 's/^allowed_users=.*/allowed_users=anybody/' "${XWRAP}"
  else
    echo 'allowed_users=anybody' >> "${XWRAP}"
  fi
else
  echo 'allowed_users=anybody' > "${XWRAP}"
fi

# ---- 4) Polkit rule for colord (overwrite is acceptable) ----
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/45-allow-colord.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.color-manager.create-device" ||
         action.id == "org.freedesktop.color-manager.create-profile") &&
        subject.isInGroup("users")) {
        return polkit.Result.YES;
    }
});
EOF

# ---- 5) User .xsession (overwrite is acceptable / idempotent outcome) ----
cat > "${USER_HOME}/.xsession" <<'EOF'
#!/bin/bash
# Force Software Rendering (useful on some VM/driver combos)
export LIBGL_ALWAYS_SOFTWARE=1

# Fix DBus connection
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval "$(dbus-launch --sh-syntax --exit-with-session)"
fi

# GNOME environment variables (Ubuntu session)
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_SESSION_TYPE=x11

exec gnome-session
EOF

chown "${RDP_USER}:${RDP_USER}" "${USER_HOME}/.xsession"
chmod 0755 "${USER_HOME}/.xsession"

# ---- 6) Clear user sessions to avoid "ghost" locks ----
echo "Clearing sessions for ${RDP_USER}..."
loginctl terminate-user "${RDP_USER}" 2>/dev/null || true
sleep 1

# ---- 7) Restart / enable services ----
systemctl enable --now ssh
systemctl restart xrdp

# ---- 8) Verify binding ----
sleep 2
if ss -lnt | grep -q "127.0.0.1:${RDP_PORT}"; then
  echo "--- SETUP SUCCESSFUL ---"
  echo "XRDP is listening on ${RDP_BIND}:${RDP_PORT} (localhost only)."
  echo
  echo "From Windows, run:"
  echo "  ssh -N -L 3390:127.0.0.1:3389 ${RDP_USER}@<IP>"
  echo
  echo "Then Remote Desktop to:"
  echo "  localhost:3390"
  echo
  echo "Note: If you have issues, log out of the Ubuntu console session for ${RDP_USER}."
else
  echo "--- SETUP FAILED ---"
  echo "XRDP is not listening on ${RDP_BIND}:${RDP_PORT}."
  echo "Check: journalctl -u xrdp --no-pager | tail -200"
  exit 1
fi
