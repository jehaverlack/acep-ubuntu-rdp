#!/bin/bash

# Ensure running as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root or with sudo"
  exit 1
fi

# 1. Ask for the target username
read -p "Enter the username you want to configure for RDP: " RDP_USER

# Verify user exists
if ! id "$RDP_USER" >/dev/null 2>&1; then
    echo "Error: User '$RDP_USER' does not exist."
    exit 1
fi

echo "--- Harmonizing System State for: $RDP_USER ---"

# 2. Install packages (Apt is naturally idempotent)
apt update && apt install -y openssh-server xrdp dbus-x11 xserver-xorg-core xorgxrdp

# 3. Secure RDP Configuration (THE IDEMPOTENT FIX)
# We delete ALL port lines and then add exactly one. 
# This fixes the 'trans_listen_address failed' error.
sed -i '/^port=/d' /etc/xrdp/xrdp.ini
echo "port=tcp://127.0.0.1:3389" >> /etc/xrdp/xrdp.ini

# Safe group addition (prevents 'already a member' warnings)
id -nG xrdp | grep -qw "ssl-cert" || adduser xrdp ssl-cert

# Fix SSL file permissions (State-based correction)
chown root:ssl-cert /etc/xrdp/key.pem
chmod 640 /etc/xrdp/key.pem

# 4. Polkit Rules (Atomic overwrite)
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/45-allow-colord.rules <<EOF
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.color-manager.create-device" ||
         action.id == "org.freedesktop.color-manager.create-profile" ||
         action.id == "org.freedesktop.color-manager.delete-device" ||
         action.id == "org.freedesktop.color-manager.delete-profile" ||
         action.id == "org.freedesktop.color-manager.modify-device" ||
         action.id == "org.freedesktop.color-manager.modify-profile") &&
        subject.isInGroup("users")) {
        return polkit.Result.YES;
    }
});
EOF
id -nG "$RDP_USER" | grep -qw "users" || usermod -aG users "$RDP_USER"

# 5. Xwrapper Configuration (State-based correction)
if [ -f /etc/X11/Xwrapper.config ]; then
    sed -i 's/allowed_users=.*/allowed_users=console/g' /etc/X11/Xwrapper.config
else
    echo "allowed_users=console" > /etc/X11/Xwrapper.config
fi

# 6. User .xsession (Atomic overwrite)
USER_HOME=$(eval echo ~$RDP_USER)
cat > "$USER_HOME/.xsession" <<EOF
#!/bin/bash
export LIBGL_ALWAYS_SOFTWARE=1
export GSK_RENDERER=cairo
export NO_AT_BRIDGE=1
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_SESSION_TYPE=x11
exec dbus-run-session -- gnome-session
EOF

chown "$RDP_USER":"$RDP_USER" "$USER_HOME/.xsession"
chmod +x "$USER_HOME/.xsession"

# 7. Final Service Sync & Port Clearance
echo "Cleaning up hung sockets and starting services..."
systemctl stop xrdp 2>/dev/null || true
# Force-clear the port in case a zombie process is holding it
fuser -k 3389/tcp 2>/dev/null || true

systemctl enable --now ssh
systemctl restart xrdp-sesman
systemctl restart xrdp

# Verification block
if ss -lnt | grep -q 3389; then
    echo "--- SUCCESS: System is listening on 3389 ---"
else
    echo "--- FAILED: Port 3389 is still not listening. ---"
fi