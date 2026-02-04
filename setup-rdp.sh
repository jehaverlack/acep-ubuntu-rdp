#!/bin/bash

# Ensure running as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root or with sudo"
  exit 1
fi

read -p "Enter the username for RDP: " RDP_USER
USER_HOME=$(eval echo ~$RDP_USER)

echo "--- Installing Full Stack (Matches your manual history) ---"
apt update
apt install -y openssh-server xrdp xorgxrdp dbus-x11 xserver-xorg-core

# 1. Config xrdp.ini to listen only on Localhost (Idempotent)
sed -i '/^port=/d' /etc/xrdp/xrdp.ini
sed -i '/\[Globals\]/a port=tcp://127.0.0.1:3389' /etc/xrdp/xrdp.ini

# 2. SSL Group (Your history line 6)
adduser xrdp ssl-cert 2>/dev/null || true

# 3. X11 Wrapper (Your history line 11)
echo "allowed_users=anybody" > /etc/X11/Xwrapper.config

# 4. Polkit (Your history line 24 - but using 24.04 JS rules)
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

# 5. The .xsession (Mirrors your working ubnt-demo config)
cat > "$USER_HOME/.xsession" <<EOF
#!/bin/bash
# Force Software Rendering
export LIBGL_ALWAYS_SOFTWARE=1

# Fix the DBus connection (Your exact working manual logic)
if [ -z "\$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval \$(dbus-launch --sh-syntax --exit-with-session)
fi

# GNOME environment variables
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_SESSION_TYPE=x11

# Start the session
exec gnome-session
EOF

chown "$RDP_USER":"$RDP_USER" "$USER_HOME/.xsession"
chmod 755 "$USER_HOME/.xsession"

# 6. Service Restart
systemctl restart xrdp
systemctl enable --now ssh

echo "--- SETUP COMPLETE ---"
echo "Connect RDP to localhost:3390 via SSH tunnel."