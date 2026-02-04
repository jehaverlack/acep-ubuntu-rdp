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

echo "--- Harmonizing System State for: $RDP_USER ---"

# 2. Package Installation (Matches your history line 4 & 30)
apt update
apt install -y openssh-server xrdp xserver-xorg-core dbus-x11 xorgxrdp

# 3. Secure xrdp.ini Reconstruction
# Fixes the duplicate port issue and forces TLS for the tunnel
sed -i '/^port=/d' /etc/xrdp/xrdp.ini
sed -i '/\[Globals\]/a port=tcp://127.0.0.1:3389' /etc/xrdp/xrdp.ini

# 4. Permissions (Matches your history line 6)
adduser xrdp ssl-cert 2>/dev/null || true
chown root:ssl-cert /etc/xrdp/key.pem
chmod 640 /etc/xrdp/key.pem

# 5. X11 Wrapper (Matches your history line 11)
# 24.04 Desktop requires 'anybody' to allow XRDP to start its own X server
echo "allowed_users=anybody" > /etc/X11/Xwrapper.config

# 6. Polkit Rule (Matches your history line 24, updated for 24.04 JS format)
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

# 7. User .xsession (Matches your history line 4 & 9)
# Use dbus-run-session to ensure GNOME 46 doesn't crash on the 'Cyan' screen
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

# 8. Service Sync
echo "Restarting services and clearing stale locks..."
systemctl stop xrdp xrdp-sesman 2>/dev/null || true

# Important: We kill only GUI/RDP processes to avoid kicking you off SSH
pgrep -u "$RDP_USER" -f "gnome-session|dbus|xrdp" | xargs kill -9 2>/dev/null || true

systemctl enable --now ssh
systemctl restart xrdp-sesman
systemctl restart xrdp

# 9. Verification
sleep 2
if ss -lnt | grep -q 3389; then
    echo "--- SUCCESS ---"
    echo "Connect RDP to localhost:3390 after running:"
    echo "ssh -L 3390:127.0.0.1:3389 $RDP_USER@$(hostname -I | awk '{print $1}')"
else
    echo "--- FAILED: Port 3389 still not listening ---"
fi