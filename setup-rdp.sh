#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root or with sudo"
  exit
fi

# 1. Ask for the target username
read -p "Enter the username you want to configure for RDP: " RDP_USER

# Verify user exists
if ! id "$RDP_USER" >/dev/null 2>&1; then
    echo "Error: User '$RDP_USER' does not exist. Create the user first."
    exit
fi

echo "--- Starting setup for user: $RDP_USER ---"

# 2. Install necessary packages
echo "Installing dependencies..."
apt update
apt install -y openssh-server xrdp dbus-x11 xserver-xorg-core

# 3. Secure RDP (Tunnel-Only Mode)
echo "Configuring RDP for SSH Tunneling only..."
sed -i 's/port=3389/port=tcp:\/\/127.0.0.1:3389/g' /etc/xrdp/xrdp.ini
adduser xrdp ssl-cert

# 4. Create the Polkit Rule to prevent logout loops
echo "Setting up Polkit rules for Color Manager..."
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
usermod -aG users "$RDP_USER"

# 5. Configure the Xwrapper
echo "Configuring Xwrapper permissions..."
if [ -f /etc/X11/Xwrapper.config ]; then
    sed -i 's/allowed_users=console/allowed_users=anybody/g' /etc/X11/Xwrapper.config
else
    echo "allowed_users=anybody" > /etc/X11/Xwrapper.config
fi

# 6. Create the user-specific .xsession file
echo "Configuring .xsession for $RDP_USER..."
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

# Set proper ownership and permissions
chown "$RDP_USER":"$RDP_USER" "$USER_HOME/.xsession"
chmod +x "$USER_HOME/.xsession"

# 7. Restart services
systemctl restart xrdp
systemctl enable xrdp

echo "--- Setup Complete ---"
echo "1. Close your KVM window (or log out of $RDP_USER physically)."
echo "2. On Windows, run: ssh -L 3390:127.0.0.1:3389 $RDP_USER@$(hostname -I | awk '{print $1}')"
echo "3. Connect Windows RDP to: localhost:3390"