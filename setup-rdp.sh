#!/bin/bash

# Ensure running as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root or with sudo"
  exit 1
fi

# 1. Configuration
read -p "Enter the username for RDP: " RDP_USER
USER_HOME=$(eval echo ~$RDP_USER)

if ! id "$RDP_USER" >/dev/null 2>&1; then
    echo "Error: User '$RDP_USER' does not exist."
    exit 1
fi

echo "--- Configuring Idempotent RDP for Ubuntu 24.04 ---"

# 2. Package Installation (Idempotent)
apt update && apt install -y openssh-server xrdp xorgxrdp dbus-x11

# 3. xrdp.ini Reconstruction (The Port 3389 Fix)
# We rebuild the [Globals] section to ensure no duplicate port lines exist
sed -i '/^port=/d' /etc/xrdp/xrdp.ini
sed -i '/\[Globals\]/a port=tcp://127.0.0.1:3389' /etc/xrdp/xrdp.ini

# 4. SSL & System Permissions
adduser xrdp ssl-cert 2>/dev/null || true
chown root:ssl-cert /etc/xrdp/key.pem
chmod 640 /etc/xrdp/key.pem

# 5. X11 Permissions (Critical for Desktop installs)
# Allowing 'anybody' is safer for headless RDP on Desktop versions
if [ -f /etc/X11/Xwrapper.config ]; then
    sed -i 's/allowed_users=.*/allowed_users=anybody/g' /etc/X11/Xwrapper.config
else
    echo "allowed_users=anybody" > /etc/X11/Xwrapper.config
fi

# 6. Polkit Rules (Fixes 'Authentication Required' popups)
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/45-allow-colord.rules <<EOF
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.color-manager.create-device" ||
         action.id == "org.freedesktop.color-manager.create-profile") &&
        subject.isInGroup("users")) {
        return polkit.Result.YES;
    }
});
EOF

# 7. User .xsession (The GNOME 46 'Cyan Screen' Killer)
# We use dbus-run-session to force a clean environment
cat > "$USER_HOME/.xsession" <<EOF
#!/bin/bash
export LIBGL_ALWAYS_SOFTWARE=1
export GSK_RENDERER=cairo
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_SESSION_TYPE=x11
export GNOME_SHELL_SESSION_MODE=ubuntu
exec dbus-run-session -- gnome-session
EOF
chown "$RDP_USER":"$RDP_USER" "$USER_HOME/.xsession"
chmod +x "$USER_HOME/.xsession"

# 8. Service Reset & Session Cleanup
echo "Cleaning up sessions and restarting..."
systemctl stop xrdp xrdp-sesman 2>/dev/null || true

# IMPORTANT: Kill any existing session for this user to release D-Bus locks
pkill -9 -u "$RDP_USER" || true

systemctl enable --now ssh
systemctl restart xrdp-sesman
systemctl restart xrdp

# 9. Final Verification
sleep 2
if ss -lnt | grep -q 3389; then
    echo "--- SETUP SUCCESSFUL ---"
    echo "1. Connect via SSH: ssh -L 3390:127.0.0.1:3389 $RDP_USER@IP"
    echo "2. Connect RDP to: localhost:3390"
    echo "NOTE: You MUST be logged out of the VM console for this to work."
else
    echo "--- SETUP FAILED: Service did not bind to port ---"
fi