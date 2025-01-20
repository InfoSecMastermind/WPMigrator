#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Prompt for input parameters
read -p $'\033[1;36mEnter your domain (e.g., yourdomain.com):\033[0m ' DOMAIN
read -p $'\033[1;36mEnter your Cloudways server IP:\033[0m ' CLOUDWAYS_SERVER
read -p $'\033[1;36mEnter your Cloudways username:\033[0m ' CLOUDWAYS_USER
read -sp $'\033[1;36mEnter your Cloudways password:\033[0m ' CLOUDWAYS_PASS
echo ""
read -p $'\033[1;36mEnter your Cloudways app name:\033[0m ' APP_NAME
read -p $'\033[1;36mEnter your local database name:\033[0m ' LOCAL_DB_NAME
read -p $'\033[1;36mEnter your local database username:\033[0m ' LOCAL_DB_USER
read -sp $'\033[1;36mEnter your local database password:\033[0m ' LOCAL_DB_PASS
echo ""
read -p $'\033[1;36mEnter your local database host (default: localhost):\033[0m ' LOCAL_DB_HOST
read -p $'\033[1;36mEnter your local web root (default: /var/www/html/public_html):\033[0m ' WEB_ROOT

# Set default values if not provided
LOCAL_DB_HOST=${LOCAL_DB_HOST:-localhost}
WEB_ROOT=${WEB_ROOT:-/var/www/html/public_html}

# Function to check if a package is installed, remove and reinstall
verify_and_reinstall_package() {
    PACKAGE=$1
    if dpkg -l | grep -q "$PACKAGE"; then
        echo "$PACKAGE is installed. Removing..."
        apt-get remove --purge -y "$PACKAGE"
        apt-get autoremove -y
    fi
    echo "Installing $PACKAGE..."
    apt-get install -y "$PACKAGE"
}

# Function to ensure MariaDB is installed and running
install_and_start_mariadb() {
    echo "Removing any existing MariaDB installation..."
    apt-get remove --purge -y mariadb-server mariadb-client
    apt-get autoremove -y

    echo "Installing MariaDB..."
    apt-get install -y mariadb-server mariadb-client php8.3-mysql

    echo "Starting MariaDB service..."
    systemctl start mariadb
    systemctl enable mariadb
    echo "MariaDB installed and started successfully."
}

# Function to determine the installed PHP version
get_php_version() {
    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
    echo "Detected PHP version: $PHP_VERSION"
}

# Function to install and configure required packages
install_stack() {
    echo "Installing required packages..."
    apt-get update
    verify_and_reinstall_package "nginx"
    verify_and_reinstall_package "varnish"
    verify_and_reinstall_package "apache2"
    verify_and_reinstall_package "php-fpm"
    verify_and_reinstall_package "sshpass"
    verify_and_reinstall_package "rsync"

    get_php_version

    echo "Configuring PHP-FPM to listen on port 9000..."
    sed -i 's/listen = \/run\/php\/php.*-fpm.sock/listen = 127.0.0.1:9000/' /etc/php/$PHP_VERSION/fpm/pool.d/www.conf
    a2enmod mpm_event
    a2enconf php8.3-fpm

    
    systemctl restart php$PHP_VERSION-fpm


    echo "Configuring Apache to run on port 8080 and forward PHP to PHP-FPM..."
    sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html/public_html|' /etc/apache2/sites-available/000-default.conf
    sed -i 's|</VirtualHost>|<FilesMatch \.php$>\n    SetHandler "proxy:fcgi://127.0.0.1:9000"\n</FilesMatch>\n</VirtualHost>|' /etc/apache2/sites-available/000-default.conf
    sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf
    sed -i 's/80/8080/' /etc/apache2/sites-available/000-default.conf
    systemctl restart apache2

    echo "Configuring Nginx as a reverse proxy..."
    cat <<EOF >/etc/nginx/sites-available/default
server {
    listen 80;
    listen [::]:80;
    root /var/www/html/public_html;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    root /var/www/html/public_html;
    server_name $DOMAIN;

    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    systemctl restart nginx && a2enmod proxy proxy_fcgi && systemctl restart apache2

    echo "Installing and starting MariaDB..."
    install_and_start_mariadb

    echo "Stack installed and configured."
}

# Function to verify and download existing backup from Cloudways server using rsync
backup_from_cloudways() {
    echo "Connecting to Cloudways server to verify backup..."
    sshpass -p "$CLOUDWAYS_PASS" ssh -v -o ConnectTimeout=10 "$CLOUDWAYS_USER@$CLOUDWAYS_SERVER" "ls -la /mnt/data/home/master/applications/$APP_NAME/local_backups/backup.tgz"
    if [ $? -ne 0 ]; then
        echo "Backup directory not found on Cloudways server"
        exit 1
    fi
    echo "Downloading backup from Cloudways server..."
    sshpass -p "$CLOUDWAYS_PASS" rsync -avz -e ssh "$CLOUDWAYS_USER@$CLOUDWAYS_SERVER:/mnt/data/home/master/applications/$APP_NAME/local_backups/backup.tgz" .
    if [ $? -ne 0 ]; then
        echo "Failed to download backup from Cloudways server"
        exit 1
    fi
    echo "Backup fetched successfully."
}

# Function to restore backup locally
restore_backup() {
    echo "Restoring backup locally..."
    tar xzf backup.tgz -C "$WEB_ROOT"
    SQL_FILE=$(find "$WEB_ROOT" -maxdepth 1 -name "*.sql")  # Searching in the directory above public_html
    if [[ -n "$SQL_FILE" ]]; then
        echo "Creating database $LOCAL_DB_NAME if it doesn't exist..."
        mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS $LOCAL_DB_NAME;
GRANT ALL PRIVILEGES ON $LOCAL_DB_NAME.* TO '$LOCAL_DB_USER'@'localhost' IDENTIFIED BY '$LOCAL_DB_PASS';
FLUSH PRIVILEGES;
EOF
        echo "Importing database from $SQL_FILE..."
        mysql -u "$LOCAL_DB_USER" -p"$LOCAL_DB_PASS" -h "$LOCAL_DB_HOST" "$LOCAL_DB_NAME" < "$SQL_FILE"
    else
        echo "No SQL file found in the directory above public_html!"
    fi
    echo "Backup restored successfully."
}

# Function to configure Varnish failover
configure_varnish_failover() {
    echo "Configuring Varnish failover..."
    cat <<EOF >/etc/varnish/default.vcl
vcl 4.0;

backend default {
    .host = "127.0.0.1";
    .port = "8080";
    .probe = {
        .url = "/";
        .timeout = 5s;
        .interval = 10s;
        .window = 5;
        .threshold = 3;
    }
}

sub vcl_recv {
    if (!std.healthy(default)) {
        set req.backend_hint = apache;
    }
}

backend apache {
    .host = "127.0.0.1";
    .port = "8080";
}
EOF
    systemctl restart varnish
    echo "Varnish failover configured."
}


disable_redis_in_wp_config() {
    if [ -f "$WEB_ROOT/public_html/wp-config.php" ]; then
        echo "Updating wp-config.php to disable Redis..."
        sed -i "s/define( 'WP_REDIS_DISABLED', false );/define( 'WP_REDIS_DISABLED', true );/" "$WEB_ROOT/public_html/wp-config.php"
    else
        echo "wp-config.php file not found in $WEB_ROOT/public_html/"
    fi
}


# Main execution
install_stack
backup_from_cloudways
restore_backup
configure_varnish_failover
disable_redis_in_wp_config

echo "Setup complete! Your website is now running at http://$DOMAIN"
]


mig3.sh

[#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Prompt for input parameters
read -p "Enter your domain (e.g., yourdomain.com): " DOMAIN
read -p "Enter your Cloudways server IP: " CLOUDWAYS_SERVER
read -p "Enter your Cloudways username: " CLOUDWAYS_USER
read -sp "Enter your Cloudways password: " CLOUDWAYS_PASS
echo ""
read -p "Enter your Cloudways app name: " APP_NAME
read -p "Enter your local database name: " LOCAL_DB_NAME
read -p "Enter your local database username: " LOCAL_DB_USER
read -sp "Enter your local database password: " LOCAL_DB_PASS
echo ""
read -p "Enter your local database host (default: localhost): " LOCAL_DB_HOST
read -p "Enter your local web root (default: /var/www/html/public_html): " WEB_ROOT

# Set default values if not provided
LOCAL_DB_HOST=${LOCAL_DB_HOST:-localhost}
WEB_ROOT=${WEB_ROOT:-/var/www/html/public_html}

# Function to check if a package is installed, remove and reinstall
verify_and_reinstall_package() {
    PACKAGE=$1
    if dpkg -l | grep -q "$PACKAGE"; then
        echo "$PACKAGE is installed. Removing..."
        apt-get remove --purge -y "$PACKAGE"
        apt-get autoremove -y
    fi
    echo "Installing $PACKAGE..."
    apt-get install -y "$PACKAGE"
}

# Function to ensure MariaDB is installed and running
install_and_start_mariadb() {
    echo "Removing any existing MariaDB installation..."
    apt-get remove --purge -y mariadb-server mariadb-client
    apt-get autoremove -y

    echo "Installing MariaDB..."
    apt-get install -y mariadb-server mariadb-client

    echo "Starting MariaDB service..."
    systemctl start mariadb
    systemctl enable mariadb
    echo "MariaDB installed and started successfully."
}

# Function to determine the installed PHP version
get_php_version() {
    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
    echo "Detected PHP version: $PHP_VERSION"
}

# Function to install and configure required packages
install_stack() {
    echo "Installing required packages..."
    apt-get update
    verify_and_reinstall_package "nginx"
    verify_and_reinstall_package "varnish"
    verify_and_reinstall_package "apache2"
    verify_and_reinstall_package "php-fpm"
    verify_and_reinstall_package "sshpass"
    verify_and_reinstall_package "rsync"

    get_php_version

    echo "Configuring PHP-FPM to listen on port 9000..."
    sed -i 's/listen = \/run\/php\/php.*-fpm.sock/listen = 127.0.0.1:9000/' /etc/php/$PHP_VERSION/fpm/pool.d/www.conf
    systemctl restart php$PHP_VERSION-fpm

    echo "Configuring Apache to run on port 8080 and forward PHP to PHP-FPM..."
    sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html/public_html|' /etc/apache2/sites-available/000-default.conf
    sed -i 's|</VirtualHost>|<FilesMatch \.php$>\n    SetHandler "proxy:fcgi://127.0.0.1:9000"\n</FilesMatch>\n</VirtualHost>|' /etc/apache2/sites-available/000-default.conf
    sed -i 's/Listen 80/Listen 8080/' /etc/apache2/ports.conf
    sed -i 's/80/8080/' /etc/apache2/sites-available/000-default.conf
    rm /var/www/html/index.html
    apt install php8.3-mysql
    a2enmod mpm_event

    a2enconf php$PHP_VERSION-fpm
    a2dismod mpm_prefork
    systemctl restart apache2

    echo "Configuring Nginx as a reverse proxy..."
    cat <<EOF >/etc/nginx/sites-available/default
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:6081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $DOMAIN;

    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    location / {
        proxy_pass http://127.0.0.1:6081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    systemctl restart nginx

    echo "Installing and starting MariaDB..."
    install_and_start_mariadb

    echo "Stack installed and configured."
}

# Function to verify and download existing backup from Cloudways server using rsync
backup_from_cloudways() {
    echo "Connecting to Cloudways server to verify backup..."
    sshpass -p "$CLOUDWAYS_PASS" ssh -v -o ConnectTimeout=10 "$CLOUDWAYS_USER@$CLOUDWAYS_SERVER" "ls -la /mnt/data/home/master/applications/$APP_NAME/local_backups/backup.tgz"
    if [ $? -ne 0 ]; then
        echo "Backup directory not found on Cloudways server"
        exit 1
    fi
    echo "Downloading backup from Cloudways server..."
    sshpass -p "$CLOUDWAYS_PASS" rsync -avz -e ssh "$CLOUDWAYS_USER@$CLOUDWAYS_SERVER:/mnt/data/home/master/applications/$APP_NAME/local_backups/backup.tgz" .
    if [ $? -ne 0 ]; then
        echo "Failed to download backup from Cloudways server"
        exit 1
    fi
    echo "Backup fetched successfully."
}

# Function to restore backup locally
restore_backup() {
    echo "Restoring backup locally..."
    tar xzf backup.tgz -C "$WEB_ROOT"
    SQL_FILE=$(find "$WEB_ROOT/.." -maxdepth 1 -name "*.sql")  # Searching in the directory above public_html
    if [[ -n "$SQL_FILE" ]]; then
        echo "Creating database $LOCAL_DB_NAME if it doesn't exist..."
        mysql -u root -p <<EOF
CREATE DATABASE IF NOT EXISTS $LOCAL_DB_NAME;
GRANT ALL PRIVILEGES ON $LOCAL_DB_NAME.* TO '$LOCAL_DB_USER'@'localhost' IDENTIFIED BY '$LOCAL_DB_PASS';
FLUSH PRIVILEGES;
EOF
        echo "Importing database from $SQL_FILE..."
        mysql -u "$LOCAL_DB_USER" -p"$LOCAL_DB_PASS" -h "$LOCAL_DB_HOST" "$LOCAL_DB_NAME" < "$SQL_FILE"
    else
        echo "No SQL file found in the directory above public_html!"
    fi
    echo "Backup restored successfully."
}

# Function to configure Varnish failover
configure_varnish_failover() {
    echo "Configuring Varnish failover..."
    cat <<EOF >/etc/varnish/default.vcl
vcl 4.0;

backend default {
    .host = "127.0.0.1";
    .port = "8080";
    .probe = {
        .url = "/";
        .timeout = 5s;
        .interval = 10s;
        .window = 5;
        .threshold = 3;
    }
}

sub vcl_recv {
    if (!std.healthy(default)) {
        set req.backend_hint = apache;
    }
}

backend apache {
    .host = "127.0.0.1";
    .port = "8080";
}
EOF
    systemctl restart varnish
    echo "Varnish failover configured."
}

# Update wp-config.php to disable Redis
disable_redis_in_wp_config() {
    if [ -f "$WEB_ROOT/wp-config.php" ]; then
        echo "Updating wp-config.php to disable Redis..."
        sed -i "s/define( 'WP_REDIS_DISABLED', false );/define( 'WP_REDIS_DISABLED', true );/" "$WEB_ROOT/wp-config.php"
    fi
}

# Main execution
install_stack
backup_from_cloudways
restore_backup
configure_varnish_failover
disable_redis_in_wp_config

echo "Setup complete! Your website is now running at http://$DOMAIN"
