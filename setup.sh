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

if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then exit 1; fi

grep -v '^AllowedIPs' "$INPUT" > "$CONF"
echo "AllowedIPs = 192.168.22.0/24, 192.168.9.0/24" >> "$CONF"
echo "PersistentKeepalive = 25" >> "$CONF"

chmod 600 "$CONF"
chown root:root "$CONF"

systemctl restart wg-quick@wg0
EOF

chmod 700 /usr/local/sbin/update-wireguard.sh

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
