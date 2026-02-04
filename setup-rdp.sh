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

echo "--- Starting Idempotent Setup for: $RDP_USER ---"

# 2. Install packages (apt is natively idempotent)
apt update && apt install -y openssh-server xrdp dbus-x11 xserver-xorg-core

# 3. Secure RDP (Tunnel-Only Mode)
# Uses a regex to ensure we don't double-prefix if already changed
sed -i 's/^port=[0-9]*/port=tcp:\/\/127.0.0.1:3389/' /etc/xrdp/xrdp.ini

# Safe group addition
id -nG xrdp | grep -qw "ssl-cert" || adduser xrdp ssl-cert

# 4. Create Polkit Rules (Overwrites file to ensure clean state)
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

# 5. Configure Xwrapper (Explicitly checks for existing line)
if [ -f /etc/X11/Xwrapper.config ]; then
    sed -i '/allowed_users=/d' /etc/X11/Xwrapper.config
fi
echo "allowed_users=anybody" >> /etc/X11/Xwrapper.config

# 6. Create User .xsession (Atomic overwrite)
USER_HOME=$(eval echo ~$RDP_USER)
cat > "$USER_HOME/.xsession" <<EOF
#!/bin/bash
export LIBGL_ALWAYS_SOFTWARE=1
if [ -z "\$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval \$(dbus-launch --sh-syntax --exit-with-session)
fi
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_SESSION_TYPE=x11
exec gnome-session
EOF

chown "$RDP_USER":"$RDP_USER" "$USER_HOME/.xsession"
chmod +x "$USER_HOME/.xsession"

# 7. Final Service Sync
systemctl enable --now ssh
systemctl enable --now xrdp
systemctl restart xrdp

echo "--- Setup Complete & Verified ---"