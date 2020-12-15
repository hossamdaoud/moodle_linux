#!/bin/sh -e

[ -z "${MOODLE_FQDN}" ] && \
  MOODLE_FQDN=$(hostname -f)
[ -z "${MOODLE_PASSWD}" ] && \
  MOODLE_PASSWD=moodle

mysql_install()
{
  sudo zypper -n in mariadb
  sudo systemctl enable mysql
  sudo systemctl start mysql

  cat<<EOF | sudo mysql -uroot
CREATE DATABASE moodle DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
GRANT ALL PRIVILEGES ON moodle.* TO moodle@localhost
  IDENTIFIED BY '${MOODLE_PASSWD}';
exit
EOF
}

moodle_install()
{
  # The moodle needs the following php extensions.
  # curl iconv mbstring openssl tokenizer xmlrpc soap ctype zip zlib
  # gd simplexml spl pcre dom xml xmlreader intl json hash fileinfo.
  sudo zypper -n in php7 php7-mysql php7-gd php7-intl php7-mbstring \
       php7-zip php7-soap php7-xmlrpc php7-curl php7-zlib php7-fileinfo \
       php7-openssl

  sudo zypper -n in git

  sudo mkdir -p /srv/www/moodle

  cd /usr/share
  sudo git clone https://github.com/moodle/moodle
  cd moodle
  sudo git checkout v3.4.2 -b v3.4.2

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
\$CFG->dirroot = '/usr/share/moodle';
\$CFG->dataroot = '/srv/www/moodle';
\$CFG->directorypermissions = 0750;
\$CFG->admin = 'admin';

\$CFG->pathtodu = '$(which du)';
\$CFG->unzip = '$(which unzip)';
\$CFG->zip = '$(which zip)';

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
  sudo zypper -n in apache2 apache2-mod_php7
  sudo gensslcert

  sudo chown -R wwwrun:root /srv/www/moodle

  cat <<EOF | sudo tee /etc/apache2/conf.d/moodle.conf
<VirtualHost _default_:443>
  SSLEngine on
  SSLCertificateFile /etc/apache2/ssl.crt/$(hostname -f)-server.crt
  SSLCertificateKeyFile /etc/apache2/ssl.key/$(hostname -f)-server.key

  Alias /moodle /usr/share/moodle

  <Directory /usr/share/moodle>
    Options FollowSymLinks MultiViews
    AllowOverride None
    Require all granted

    php_flag magic_quotes_gpc Off
    php_flag magic_quotes_runtime Off
    php_flag file_uploads On
    php_flag session.auto_start Off
    php_flag session.bug_compat_warn Off
    php_value upload_max_filesize 2M
    php_value post_max_size 2M
  </Directory>
</VirtualHost>
EOF

  sudo firewall-cmd --add-service=https --permanent
  sudo firewall-cmd --reload

  sudo a2enflag SSL
  sudo a2enmod ssl
  sudo a2enmod php7
  sudo systemctl enable apache2
  sudo systemctl restart apache2
}

moodle_main()
{
  mysql_install
  moodle_install
  apache_install
}

moodle_main
