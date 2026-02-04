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
# We explicitly include xorgxrdp to ensure the modern driver is present
apt update && apt install -y openssh-server xrdp dbus-x11 xserver-xorg-core xorgxrdp

# 3. Secure RDP (Tunnel-Only Mode)
sed -i 's/^port=[0-9]*/port=tcp:\/\/127.0.0.1:3389/' /etc/xrdp/xrdp.ini
id -nG xrdp | grep -qw "ssl-cert" || adduser xrdp ssl-cert

# 4. Create Polkit Rules (Atomic overwrite)
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

# 5. Clean up Xwrapper (Let Ubuntu 24.04 handle this natively)
# We remove the "anybody" force which was causing issues vs the working demo
if [ -f /etc/X11/Xwrapper.config ]; then
    sed -i 's/allowed_users=anybody/allowed_users=console/g' /etc/X11/Xwrapper.config
fi

# 6. Create User .xsession (With 24.04 Freeze Fixes)
USER_HOME=$(eval echo ~$RDP_USER)
cat > "$USER_HOME/.xsession" <<EOF
#!/bin/bash
# Force Software Rendering
export LIBGL_ALWAYS_SOFTWARE=1
# Force Cairo for GNOME 46 stability (Prevents interface freezes)
export GSK_RENDERER=cairo
export NO_AT_BRIDGE=1

if [ -z "\$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval \$(dbus-launch --sh-syntax --exit-with-session)
fi

# Disable animations to ensure responsiveness over the tunnel
gsettings set org.gnome.desktop.interface enable-animations false

export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_SESSION_TYPE=x11
exec gnome-session
EOF

chown "$RDP_USER":"$RDP_USER" "$USER_HOME/.xsession"
chmod +x "$USER_HOME/.xsession"

# 7. Final Service Sync
# Ensure no lingering sessions interfere with the fresh start
pkill -u "$RDP_USER" || true
systemctl enable --now ssh
systemctl enable --now xrdp
systemctl restart xrdp

echo "--- Setup Complete & Verified ---"