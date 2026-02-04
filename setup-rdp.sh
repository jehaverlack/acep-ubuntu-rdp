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

echo "--- Starting Hardened Idempotent Setup for: $RDP_USER ---"

# 2. Install packages 
apt update && apt install -y openssh-server xrdp dbus-x11 xserver-xorg-core xorgxrdp

# 3. Secure RDP & Fix SSL Permissions (Fixes the 'Permission Denied' log error)
sed -i 's/^port=[0-9]*/port=tcp:\/\/127.0.0.1:3389/' /etc/xrdp/xrdp.ini

# Ensure xrdp can actually read the keys
adduser xrdp ssl-cert
chown root:ssl-cert /etc/xrdp/key.pem
chmod 640 /etc/xrdp/key.pem

# 4. Create Polkit Rules
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

# 5. Reset Xwrapper to Console (Matches your working 'ubnt-demo' setup)
if [ -f /etc/X11/Xwrapper.config ]; then
    sed -i 's/allowed_users=.*/allowed_users=console/g' /etc/X11/Xwrapper.config
fi

# 6. Create User .xsession (The 'Cyan Screen' Fix)
USER_HOME=$(eval echo ~$RDP_USER)
cat > "$USER_HOME/.xsession" <<EOF
#!/bin/bash
# Force Software Rendering
export LIBGL_ALWAYS_SOFTWARE=1
export GSK_RENDERER=cairo
export NO_AT_BRIDGE=1

# Session variables
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_SESSION_TYPE=x11

# The 'dbus-run-session' wrapper is the most reliable way to 
# avoid the Cyan screen on 24.04 by creating a fresh bus.
exec dbus-run-session -- gnome-session
EOF

chown "$RDP_USER":"$RDP_USER" "$USER_HOME/.xsession"
chmod +x "$USER_HOME/.xsession"

# 7. Final Service Sync & Session Cleanup
# Clean up any failed D-Bus or X11 sockets from previous tries
pkill -u "$RDP_USER" || true
rm -rf /run/user/$(id -u "$RDP_USER") || true

systemctl enable --now ssh
systemctl enable --now xrdp
systemctl restart xrdp

echo "--- Setup Complete ---"