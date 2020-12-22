#!/bin/sh

set -e

[ -z "${MYSQL_PASSWD}" ] && MYSQL_PASSWD=H@ssam00
[ -z "${MOODLE_PASSWD}" ] && MOODLE_PASSWD=H@ssam00
[ -z "${MOODLE_FQDN}" ] && MOODLE_FQDN=arch

mysql_install()
{
  sudo pacman -Sy --noconfirm mariadb

  # Install database.
  sudo mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql

  sudo systemctl enable mariadb
  sudo systemctl start mariadb

  # Password configuration.
  cat <<EOF | sudo mysql_secure_installation

y
${MYSQL_PASSWD}
${MYSQL_PASSWD}
n
y
y
y
EOF

  cat<<EOF | sudo mysql -uroot -p${MYSQL_PASSWD}
CREATE DATABASE IF NOT EXISTS moodle DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
ALTER DATABASE moodle DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
GRANT ALL PRIVILEGES ON moodle.* TO moodle@localhost
  IDENTIFIED BY '${MOODLE_PASSWD}';
exit
EOF
}

php_install()
{
  # Enable PHP extension.
  sudo pacman -Sy --noconfirm php php-gd php-intl
  sudo sed -i /etc/php/php.ini \
       -e 's/^;extension=pdo_mysql.so/extension=pdo_mysql.so/g' \
       -e 's/^;extension=mysqli.so/extension=mysqli.so/g' \
       -e 's/^;extension=gd.so/extension=gd.so/g' \
       -e 's/^;extension=iconv.so/extension=iconv.so/g' \
       -e 's/^;extension=xmlrpc.so/extension=xmlrpc.so/g' \
       -e 's/^;extension=soap.so/extension=soap.so/g' \
       -e 's/^;extension=intl.so/extension=intl.so/g' \
       -e 's/^;zend_extension=opcache.so/zend_extension=opcache.so/g' \
       -e 's/^;opcache.enable=1/opcache.enable=1/g'
}

moodle_install()
{
  sudo pacman -Sy --noconfirm git base-devel
  sudo mkdir -p /usr/share/webapps
  sudo mkdir -p /var/lib/moodle
  sudo chmod -R 777 /var/lib/moodle
  cd /usr/share/webapps
  sudo wget http://sourceforge.net/projects/moodle/files/Moodle/stable39/moodle-latest-39.tgz
  sudo tar zxvf moodle-latest-39.tgz -C /usr/share/webapps/
  cd /usr/share/webapps/moodle
  cat <<EOF | sudo tee config.php
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype = 'mariadb';
\$CFG->dbhost = 'localhost';
\$CFG->dbname = 'moodle';
\$CFG->dbuser = 'moodle';
\$CFG->dbpass = '${MOODLE_PASSWD}';
\$CFG->prefix = 'mdl_';

\$CFG->wwwroot = 'https://${MOODLE_FQDN}/moodle';
\$CFG->dirroot = '/usr/share/webapps/moodle';
\$CFG->dataroot = '/var/lib/moodle';
\$CFG->directorypermissions = 0750;
\$CFG->admin = 'admin';

\$CFG->pathtodu = '/usr/bin/du';
\$CFG->unzip = '/usr/bin/unzip';
\$CFG->zip = '/usr/bin/zip';

\$CFG->respectsessionsettings = true;
\$CFG->disableupdatenotifications = true;
\$CFG->enablehtmlpurifier = true;

if (file_exists("\$CFG->dirroot/lib/setup.php"))  {
  include_once("\$CFG->dirroot/lib/setup.php");
} else {
  if (\$CFG->dirroot == dirname(__FILE__)) {
    echo "<p>Could not find this file: \$CFG->dirroot/lib/setup.php</p>";
    echo "<p>Are you sure all your files have been uploaded?</p>";
  } else {
    echo "<p>Error detected in config.php</p>";
    echo "<p>Error in: \\\$CFG->dirroot = '\$CFG->dirroot';</p>";
    echo "<p>Try this: \\\$CFG->dirroot = '".dirname(__FILE__)."';</p>";
  }
  die;
}
EOF
}

apache_install()
{
  sudo pacman -Sy --noconfirm apache php-apache
  sudo systemctl enable httpd

  # php configuration.
  sudo sed -i /etc/httpd/conf/httpd.conf \
       -e 's/^LoadModule mpm_event_module/#LoadModule mpm_event_module/g' \
       -e 's/^#LoadModule mpm_prefork_module/LoadModule mpm_prefork_module/g'
  cat <<EOF | sudo tee -a /etc/httpd/conf/httpd.conf
LoadModule php7_module modules/libphp7.so
AddHandler php7-script php
Include conf/extra/php7_module.conf
EOF

  # ssl configuration.
  # Country Name (2 letter code) [AU]:
  # State or Province Name (full name) [Some-State]:
  # Locality Name (eg, city) []:
  # Organization Name (eg, company) [Internet Widgits Pty Ltd]:
  # Organizational Unit Name (eg, section) []:
  # Common Name (e.g. server FQDN or YOUR name) []:
  # Email Address []:
  cat <<EOF | sudo openssl req -new -x509 -nodes -newkey rsa:4096 -days 1095 \
                   -keyout /etc/httpd/conf/server.key \
                   -out /etc/httpd/conf/server.crt
AU
Some-State
city
company
section
${MOODLE_FQDN}

EOF
  sudo sed -i /etc/httpd/conf/httpd.conf \
       -e 's/^#LoadModule ssl_module/LoadModule ssl_module/g' \
       -e 's/^#LoadModule socache_shmcb_module/LoadModule socache_shmcb_module/g'
  cat <<EOF | sudo tee -a /etc/httpd/conf/httpd.conf
Include conf/extra/httpd-ssl.conf
EOF

  # rewrite configuration.
  sudo sed -i /etc/httpd/conf/httpd.conf \
       -e 's/^#LoadModule rewrite_module/LoadModule rewrite_module/g'
  cat << EOF | sudo tee /etc/httpd/conf/extra/redirect-to-https.conf
RewriteEngine On
RewriteCond %{HTTPS} off
RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI}
EOF
  cat <<EOF | sudo tee -a /etc/httpd/conf/httpd.conf
Include conf/extra/redirect-to-https.conf
EOF

cat <<EOF | sudo tee /etc/httpd/conf/extra/moodle.conf
Alias /moodle /usr/share/webapps/moodle

<Directory /usr/share/webapps/moodle>
  Options FollowSymLinks MultiViews
  AllowOverride None
  Require all granted

  php_flag magic_quotes_gpc Off
  php_flag magic_quotes_runtime Off
  php_flag file_uploads On
  php_flag session.auto_start Off
  php_flag session.bug_compat_warn Off
  php_value upload_max_filesize 600M
  php_value post_max_size 600M
</Directory>
EOF
  cat <<EOF | sudo tee -a /etc/httpd/conf/httpd.conf
Include conf/extra/moodle.conf
EOF

  sudo systemctl restart httpd
}

moodle_main()
{
  mysql_install
  php_install
  moodle_install
  apache_install
}

moodle_main
# After the script finished:

# sudo nano /etc/php/php.ini
#UnComment:
#extension=curl
#extension=iconv
#extension=mysqli
#extension=zip
#extension=gd
#extension=intl
#extension=xmlrpc
#extension=soap
#zend_extension=opcache.enable

#[intl]
#intl.default_locale = en_utf8
#intl.error_level = E_WARNING

#sudo systemctl restart httpd
