#!/usr/bin/env bash
set -euo pipefail

### ---------------------------
### Pre-flight checks
### ---------------------------
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This installer must be run as root"
  exit 1
fi

. /etc/os-release
if [ "$VERSION_CODENAME" != "bookworm" ]; then
  echo "ERROR: Only Debian 12 (bookworm) is supported"
  exit 1
fi

### ---------------------------
### Base system
### ---------------------------
echo "=== System update ==="
apt update
apt -y upgrade

echo "=== Base packages ==="
apt install -y sudo wget gnupg ca-certificates apt-transport-https

### ---------------------------
### Apache + PHP
### ---------------------------
echo "=== Apache + PHP ==="
apt install -y apache2 php libapache2-mod-php
systemctl enable apache2
systemctl restart apache2

### ---------------------------
### WireGuard
### ---------------------------
echo "=== WireGuard ==="
apt install -y wireguard wireguard-tools openresolv
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

WG_PRIV=$(wg genkey)
WG_PUB=$(echo "$WG_PRIV" | wg pubkey)

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $WG_PRIV
Address = 10.255.255.1/32
ListenPort = 51820

[Peer]
PublicKey = $WG_PUB
Endpoint = 127.0.0.1:51820
EOF

chmod 600 /etc/wireguard/wg0.conf
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0 || true

### ---------------------------
### 3CX repository
### ---------------------------
echo "=== Configuring 3CX repository ==="

machinearch=$(dpkg --print-architecture)
tcxrepo="http://repo.3cx.com"
tcxkey="/usr/share/keyrings/3cx-archive-keyring.gpg"

wget -qO - "$tcxrepo/key.pub" | gpg --dearmor | tee "$tcxkey" >/dev/null

cat > /etc/apt/sources.list.d/3cxpbx.list <<EOF
deb [arch=$machinearch by-hash=yes signed-by=$tcxkey] $tcxrepo/3cx bookworm main
deb [arch=$machinearch by-hash=yes signed-by=$tcxkey] $tcxrepo/3cx bookworm-testing main
EOF

apt update

if apt-cache show 3cxsbc >/dev/null 2>&1; then
  apt install -y 3cxsbc
else
  echo "WARNING: 3cxsbc package not available for this architecture"
fi



echo "=== Set DNS ==="

mkdir -p /etc/resolvconf/resolv.conf.d

cat > /etc/resolvconf/resolv.conf.d/base <<'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF

chmod 755 /etc/resolvconf/resolv.conf.d/base
chown root:root /etc/resolvconf/resolv.conf.d/base

resolvconf -u



### ---------------------------
### Helper scripts
### ---------------------------
echo "=== Helper scripts ==="

cat > /usr/local/sbin/update-3cxsbc.sh <<'EOF'
#!/usr/bin/env bash
set -e

URL="$1"
KEY="$2"
CONF="/etc/3cxsbc.conf"
SERVICE_USER="tcxsbc"

if [[ -z "$URL" || -z "$KEY" ]]; then exit 1; fi

echo "ProvLink=${URL}/sbc/${KEY}" > "$CONF"
chown "$SERVICE_USER":"$SERVICE_USER" "$CONF"
chmod 660 "$CONF"

systemctl restart 3cxsbc || true
EOF

chmod 700 /usr/local/sbin/update-3cxsbc.sh
chown root:root /usr/local/sbin/update-3cxsbc.sh

cat > /usr/local/sbin/update-wireguard.sh <<'EOF'
#!/usr/bin/env bash
set -e

INPUT="$1"
CONF="/etc/wireguard/wg0.conf"

POSTUP='PostUp = /usr/local/sbin/wg-conditional-route.sh up'
PREDOWN='PreDown = /usr/local/sbin/wg-conditional-route.sh down'
if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
    echo "Usage: $0 <input-wireguard.conf>"
    exit 1
fi

tmp="$(mktemp)"

awk -v postup="$POSTUP" -v predown="$PREDOWN" '
BEGIN {
    in_interface = 0
    wrote_post = 0
    wrote_pre  = 0
}

# Strip all AllowedIPs (handled later)
/^AllowedIPs[[:space:]]*=/ {
    next
}

# Interface section start
/^\[Interface\]/ {
    in_interface = 1
    print
    next
}

# Peer section start – close Interface section
/^\[Peer\]/ {
    if (in_interface) {
        if (!wrote_post) print postup
        if (!wrote_pre)  print predown
        in_interface = 0
    }
    print
    next
}

# Replace PostUp / PreDown if they exist
/^PostUp[[:space:]]*=/ {
    print postup
    wrote_post = 1
    next
}

/^PreDown[[:space:]]*=/ {
    print predown
    wrote_pre = 1
    next
}

{
    print
}

# Handle configs with no [Peer] section
END {
    if (in_interface) {
        if (!wrote_post) print postup
        if (!wrote_pre)  print predown
    }
}
' "$INPUT" > "$tmp"

# Append peer directives as per original script
{
    echo "AllowedIPs = 192.168.3.1/32"
    echo "PersistentKeepalive = 25"
} >> "$tmp"

mv "$tmp" "$CONF"
chmod 600 "$CONF"
chown root:root "$CONF"

systemctl restart wg-quick@wg0
EOF

chmod 700 /usr/local/sbin/update-wireguard.sh

cat > /usr/local/sbin/wg-conditional-route.sh <<'EOF'

#!/bin/bash
set -e

WG_IFACE="wg0"
SUBNET="192.168.22.0/24"

ACTION="$1"

# Check if subnet exists on a non-WireGuard interface
subnet_on_lan() {
    ip route show "$SUBNET" | grep -vq "$WG_IFACE"
}

case "$ACTION" in
    up)
        if subnet_on_lan; then
            echo "[wg] $SUBNET already present on LAN, skipping VPN route"
        else
            echo "[wg] Adding $SUBNET via WireGuard"
            ip route add "$SUBNET" dev "$WG_IFACE"
        fi
        ;;
    down)
        if ip route show "$SUBNET" | grep -q "$WG_IFACE"; then
            echo "[wg] Removing $SUBNET from WireGuard"
            ip route del "$SUBNET" dev "$WG_IFACE"
        fi
        ;;
    *)
        echo "Usage: $0 {up|down}"
        exit 1
        ;;
esac

EOF

chmod 700 /usr/local/sbin/wg-conditional-route.sh

### ---------------------------
### Sudo rules
### ---------------------------
echo "=== Sudo rules ==="
cat > /etc/sudoers.d/config-portal <<EOF
www-data ALL=(root) NOPASSWD: /usr/local/sbin/update-3cxsbc.sh
www-data ALL=(root) NOPASSWD: /usr/local/sbin/update-wireguard.sh
EOF
chmod 440 /etc/sudoers.d/config-portal

### ---------------------------
### Web UI (CSS FIXED – NO read -d)
### ---------------------------
echo "=== Web UI ==="

# Index
cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Configuration Portal</title><style>
body{font-family:Arial,sans-serif;background:#f4f4f4;text-align:center;margin-top:80px}
.box{background:#fff;width:420px;margin:auto;padding:30px;border-radius:8px}
input{width:100%;padding:8px;margin-top:5px;margin-bottom:15px}
button{width:100%;padding:12px;border:none;border-radius:6px;font-size:16px;cursor:pointer}
button:hover{opacity:.9}
a{display:block;margin-top:15px;text-decoration:none}
.success{color:#2b7a0b}
.error{color:#b00020}
</style></head>
<body><div class="box">
<h1>Configuration Portal</h1>
<a href="/sbc.html"><button style="background:#0078d7;color:#fff">Configure 3CX SBC</button></a>
<a href="/wireguard.html"><button style="background:#2b7a0b;color:#fff">Configure WireGuard</button></a>
</div></body></html>
EOF

# SBC form
cat > /var/www/html/sbc.html <<'EOF'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>Configuration Portal</title><style>
body{font-family:Arial,sans-serif;background:#f4f4f4;text-align:center;margin-top:80px}
.box{background:#fff;width:420px;margin:auto;padding:30px;border-radius:8px}
input{width:100%;padding:8px;margin-top:5px;margin-bottom:15px}
button{width:100%;padding:12px;border:none;border-radius:6px;font-size:16px;cursor:pointer}
button:hover{opacity:.9}
a{display:block;margin-top:15px;text-decoration:none}
a.back{display:block;padding:15px;margin:15px 0;color:#fff;text-decoration:none;border-radius:6px}
.back{background:#0078d7}
.success{color:#2b7a0b}
.error{color:#b00020}
</style></head>
<body>
<div class="box">
<h1>3CX SBC Configuration</h1>
<form action="/sbc.php" method="post">
Provisioning URL:<br>
<input name="url" required style="width:400px"><br><br>
Authentication Key:<br>
<input name="key" required style="width:400px"><br><br>
<button type="submit" style="background:#2b7a0b;color:#fff">Apply</button>
</form>
<p><a href="/index.html" class="back">Back</a></p>
</div>
</body>
</html>
EOF

# SBC handler (with 5s redirect)
cat > /var/www/html/sbc.php <<'EOF'
<?php
$ok = false;
if (isset($_POST['url'], $_POST['key'])) {
  exec(
    sprintf(
      'sudo /usr/local/sbin/update-3cxsbc.sh %s %s',
      escapeshellarg($_POST['url']),
      escapeshellarg($_POST['key'])
    ),
    $o,
    $rc
  );
  $ok = ($rc === 0);
}
?>
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="5;url=/index.html">
<title>SBC Update</title>
<style>
body{text-align:center;margin-top:80px;font-family:Arial}
.success{color:#2b7a0b}
.error{color:#b00020}
</style>
</head>
<body>
<h1 class="<?= $ok ? 'success' : 'error' ?>">
<?= $ok ? '✅ SBC updated successfully' : '❌ SBC update failed' ?>
</h1>
<p>Returning to menu in 5 seconds…</p>
</body>
</html>
EOF

# WireGuard form
cat > /var/www/html/wireguard.html <<'EOF'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>Configuration Portal</title><style>
body{font-family:Arial,sans-serif;background:#f4f4f4;text-align:center;margin-top:80px}
.box{background:#fff;width:420px;margin:auto;padding:30px;border-radius:8px}
input{width:100%;padding:8px;margin-top:5px;margin-bottom:15px}
button{width:100%;padding:12px;border:none;border-radius:6px;font-size:16px;cursor:pointer}
button:hover{opacity:.9}
a{display:block;margin-top:15px;text-decoration:none}
a.back{display:block;padding:15px;margin:15px 0;color:#fff;text-decoration:none;border-radius:6px}
.back{background:#0078d7}
.success{color:#2b7a0b}
.error{color:#b00020}
</style></head>
<body>
<div class="box">
<h1>WireGuard Configuration Upload</h1>
<form action="/wireguard.php" method="post" enctype="multipart/form-data">
<input type="file" name="wgconf" accept=".conf" required><br><br>
<button type="submit" style="background:#2b7a0b;color:#fff">Upload & Apply</button>
</form>
<p><a href="/index.html" class="back">Back</a></p>
</div>
</body>
</html>
EOF

# WireGuard handler (with 5s redirect)
cat > /var/www/html/wireguard.php <<'EOF'
<?php
$ok = false;
if (isset($_FILES['wgconf']) && $_FILES['wgconf']['error'] === UPLOAD_ERR_OK) {
  exec(
    'sudo /usr/local/sbin/update-wireguard.sh ' .
    escapeshellarg($_FILES['wgconf']['tmp_name']),
    $o,
    $rc
  );
  $ok = ($rc === 0);
}
?>
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="5;url=/index.html">
<title>WireGuard Update</title>
<style>
body{text-align:center;margin-top:80px;font-family:Arial}
.success{color:#2b7a0b}
.error{color:#b00020}
</style>
</head>
<body>
<h1 class="<?= $ok ? 'success' : 'error' ?>">
<?= $ok ? '✅ WireGuard updated successfully' : '❌ WireGuard update failed' ?>
</h1>
<p>Returning to menu in 5 seconds…</p>
</body>
</html>
EOF


chown www-data:www-data /var/www/html/*.php
chmod 644 /var/www/html/*.html

systemctl restart apache2

echo "=== INSTALL COMPLETE ==="
echo "Open http://<device-ip>/"
