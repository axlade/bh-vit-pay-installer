#!/bin/bash
#
# Script d'installation automatisée :
#   - Paymenter (facturation)
#   - Site vitrine (Nginx + accès SFTP/FTP)
#
# Cible : Debian 12 / Ubuntu 22.04+ fraîchement installé
# À lancer en root : bash setup.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Couleurs / helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

[[ $EUID -eq 0 ]] || error "Ce script doit être lancé en root."

# Se placer dans un dossier sûr (évite getcwd() failed si lancé depuis un dossier supprimé)
cd /root 2>/dev/null || cd /

# ---------------------------------------------------------------------------
# Saisie utilisateur
# ---------------------------------------------------------------------------
echo "=============================================="
echo "  Installation Paymenter + Site vitrine"
echo "=============================================="
read -rp "Domaine du Paymenter (ex: billing.exemple.fr)  : " PAYMENTER_DOMAIN
read -rp "Domaine du site vitrine (ex: exemple.fr)       : " VITRINE_DOMAIN
echo "--- Compte administrateur Paymenter ---"
read -rp "Email admin (connexion + SSL)                  : " ADMIN_EMAIL
read -rp "Prénom admin                                   : " ADMIN_FIRSTNAME
read -rp "Nom admin                                      : " ADMIN_LASTNAME
read -rsp "Mot de passe admin Paymenter                 : " ADMIN_PASS; echo
echo "--- Accès FTP site vitrine ---"
read -rp "Utilisateur FTP pour le site vitrine           : " FTP_USER
read -rsp "Mot de passe FTP                              : " FTP_PASS; echo
read -rsp "Mot de passe root MySQL à définir             : " MYSQL_ROOT_PASS; echo

[[ -n "$PAYMENTER_DOMAIN" && -n "$VITRINE_DOMAIN" && -n "$ADMIN_EMAIL" \
   && -n "$ADMIN_FIRSTNAME" && -n "$ADMIN_LASTNAME" && -n "$ADMIN_PASS" \
   && -n "$FTP_USER" && -n "$FTP_PASS" && -n "$MYSQL_ROOT_PASS" ]] \
   || error "Tous les champs sont obligatoires."

PAYMENTER_DB_PASS=$(openssl rand -base64 20 | tr -d '/+=' | head -c 24)
VITRINE_ROOT="/var/www/vitrine"

# ---------------------------------------------------------------------------
# Paquets de base
# ---------------------------------------------------------------------------
info "Mise à jour du système et installation des dépendances..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y software-properties-common curl wget gnupg2 ca-certificates \
    lsb-release apt-transport-https unzip git tar vsftpd cron
systemctl enable --now cron

# Dépôt PHP (Sury)
if ! grep -rq "packages.sury.org" /etc/apt/sources.list.d/ 2>/dev/null; then
    curl -sSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list
fi

# Dépôt Redis + MariaDB via distro
apt-get update -y
info "Installation de Nginx, PHP 8.3, MariaDB, Redis..."
apt-get install -y nginx mariadb-server redis-server \
    php8.3 php8.3-{cli,fpm,gd,mysql,mbstring,bcmath,xml,curl,zip,intl,tokenizer,common,readline,redis}

systemctl enable --now nginx mariadb redis-server php8.3-fpm

# Composer
if ! command -v composer &>/dev/null; then
    info "Installation de Composer..."
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
fi

# ---------------------------------------------------------------------------
# Sécurisation MySQL + bases
# ---------------------------------------------------------------------------
info "Configuration de MariaDB..."
mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
CREATE DATABASE paymenter;
CREATE USER 'paymenter'@'127.0.0.1' IDENTIFIED BY '${PAYMENTER_DB_PASS}';
GRANT ALL PRIVILEGES ON paymenter.* TO 'paymenter'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# ---------------------------------------------------------------------------
# Installation Paymenter
# ---------------------------------------------------------------------------
info "Installation de Paymenter..."
mkdir -p /var/www/paymenter
cd /var/www/paymenter
curl -Ls https://github.com/paymenter/paymenter/releases/latest/download/paymenter.tar.gz | tar -xzv
chmod -R 755 storage/* bootstrap/cache/

cp .env.example .env
composer install --no-dev --optimize-autoloader --no-interaction

# Configuration .env
sed -i "s|APP_URL=.*|APP_URL=https://${PAYMENTER_DOMAIN}|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=paymenter|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=paymenter|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${PAYMENTER_DB_PASS}|" .env
sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|" .env

php artisan key:generate --force
php artisan storage:link
php artisan migrate --force
php artisan db:seed --force || warn "Seeder déjà exécuté ou avertissement ignoré."

chown -R www-data:www-data /var/www/paymenter

# Cron + queue worker
( crontab -l 2>/dev/null; echo "* * * * * php /var/www/paymenter/artisan schedule:run >> /dev/null 2>&1" ) | crontab -

cat > /etc/systemd/system/paymenter.service <<EOF
[Unit]
Description=Paymenter Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/paymenter/artisan queue:work --tries=3
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now paymenter.service

# ---------------------------------------------------------------------------
# Site vitrine (dossier + fichier par défaut)
# ---------------------------------------------------------------------------
info "Préparation du dossier du site vitrine..."
mkdir -p "$VITRINE_ROOT"
cat > "$VITRINE_ROOT/index.html" <<EOF
<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8">
<title>${VITRINE_DOMAIN}</title></head>
<body style="font-family:sans-serif;text-align:center;margin-top:15%">
<h1>${VITRINE_DOMAIN}</h1>
<p>Déposez les fichiers de votre site via FTP dans ce dossier.</p>
</body></html>
EOF

# ---------------------------------------------------------------------------
# Compte FTP (SFTP/FTP) pointant sur le dossier vitrine
# ---------------------------------------------------------------------------
info "Création du compte FTP pour le site vitrine..."
if ! id "$FTP_USER" &>/dev/null; then
    useradd -m -d "$VITRINE_ROOT" -s /usr/sbin/nologin "$FTP_USER"
fi
echo "${FTP_USER}:${FTP_PASS}" | chpasswd
chown -R "$FTP_USER":www-data "$VITRINE_ROOT"
chmod -R 775 "$VITRINE_ROOT"

# Config vsftpd (FTP explicite sur TLS)
cat > /etc/vsftpd.conf <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=002
chroot_local_user=YES
allow_writeable_chroot=YES
user_sub_token=\$USER
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
EOF
echo "$FTP_USER" > /etc/vsftpd.userlist
systemctl restart vsftpd
systemctl enable vsftpd

# ---------------------------------------------------------------------------
# Configuration Nginx
# ---------------------------------------------------------------------------
info "Configuration de Nginx..."

# Vhost site vitrine
cat > /etc/nginx/sites-available/vitrine.conf <<EOF
server {
    listen 80;
    server_name ${VITRINE_DOMAIN} www.${VITRINE_DOMAIN};
    root ${VITRINE_ROOT};
    index index.html index.htm index.php;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }
}
EOF

# Vhost Paymenter (Laravel)
cat > /etc/nginx/sites-available/paymenter.conf <<EOF
server {
    listen 80;
    server_name ${PAYMENTER_DOMAIN};
    root /var/www/paymenter/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/vitrine.conf   /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/paymenter.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ---------------------------------------------------------------------------
# Certificats SSL (Let's Encrypt)
# ---------------------------------------------------------------------------
info "Installation des certificats SSL..."
apt-get install -y certbot python3-certbot-nginx
certbot --nginx --non-interactive --agree-tos --redirect \
    -m "$ADMIN_EMAIL" \
    -d "$PAYMENTER_DOMAIN" \
    -d "$VITRINE_DOMAIN" -d "www.${VITRINE_DOMAIN}" \
    || warn "Certbot a échoué (DNS non propagé ?). Relancez : certbot --nginx"

# ---------------------------------------------------------------------------
# Compte admin Paymenter
# ---------------------------------------------------------------------------
info "Création du compte administrateur Paymenter..."
cd /var/www/paymenter
php artisan app:user:create \
    --name="$ADMIN_FIRSTNAME $ADMIN_LASTNAME" \
    --email="$ADMIN_EMAIL" \
    --password="$ADMIN_PASS" \
    --admin --no-interaction 2>/dev/null \
  || php artisan app:user --no-interaction 2>/dev/null \
  || warn "Créez l'admin manuellement : php artisan app:user"

# ---------------------------------------------------------------------------
# Récapitulatif
# ---------------------------------------------------------------------------
echo
echo "=============================================="
echo -e "${GREEN}  Installation terminée${NC}"
echo "=============================================="
echo "Paymenter      : https://${PAYMENTER_DOMAIN}/admin (login: ${ADMIN_EMAIL})"
echo "Site vitrine   : https://${VITRINE_DOMAIN}"
echo "Dossier site   : ${VITRINE_ROOT}"
echo "FTP host       : ${VITRINE_DOMAIN} (port 21, FTP explicite/TLS)"
echo "FTP user       : ${FTP_USER}"
echo "DB Paymenter   : paymenter / (mdp généré, voir /var/www/paymenter/.env)"
echo "----------------------------------------------"
echo "Étapes restantes pour le client :"
echo "  1. Se connecter à Paymenter et configurer produits/paiements"
echo "  2. Déposer les fichiers du site vitrine par FTP dans ${VITRINE_ROOT}"
echo "=============================================="