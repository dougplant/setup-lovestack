# - script to fully setup a CentOS 7 instance with the Mugo LoveStack
# todo:
# - move the httpd and mariadb systemctl enable calls to the end of the script, generally biased against having them run if they're not fully set up
# - decide what to do about APC (or other op code cache) which is not currently being installed


# escape for MySQL, just don't want to break any queries, not looking for injection attacks or anything
stringGlobal=""
function escapeForSQL() {
    string=$1
    string=${string//\\/\\\\}
    string=${string//\'/\\\'}
    string=${string//\"/\\\"}
    stringGlobal=$string
}

# get the various inputs needed from the user:

# get the name of the filesystem and db user
fileSystemUserName=""
while [ "$fileSystemUserName" == "" ]; do
    read -p "Enter username (for db account and fs ownership): " fileSystemUserName
done

# get password for the (single) filesystem user, this will be how to SSH into the host
fileSystemUserPassword=""
while [ "$fileSystemUserPassword" == "" ]; do
    read -p "Enter fs password for this user:" fileSystemUserPassword
done
escapeForSQL $fileSystemUserPassword
fileSystemUserPassword=$stringGlobal

# get password for the database use (so as to not use root)
databaseUserPassword=""
while [ "$databaseUserPassword" == "" ]; do
    read -p "Enter db password for this user:" databaseUserPassword
done
escapeForSQL $databaseUserPassword
databaseUserPassword=$stringGlobal

# get password for the root database password
rootUserPassword=""
while [ "$rootUserPassword" == "" ]; do
    read -p "Enter db password for the root user:" rootUserPassword
done
escapeForSQL $rootUserPassword
rootUserPassword=$stringGlobal

# get intended domain name
domainName=""
while [ "$domainName" == "" ]; do
    read -p "Enter the full domain name for this host:" domainName
done

# just for debugging purposes, dump the various input values we've captured
echo "file-system-user name:" $fileSystemUserName
echo "file-system-user ssh password:" $fileSystemUserPassword
echo "file-system-user database password:" $databaseUserPassword
echo "root-user database password:" $rootUserPassword
echo "the full domain name:" $domainName


if false; then


# install Apache
yum -y install httpd

# confirm apache installation: test that it is serving content, at least via localhost
yum -y install wget
echo "hello world" > /var/www/html/index.html
systemctl start httpd
apacheTest=$(wget localhost -O- -q)
if [ "$apacheTest" != "hello world" ]; then
  echo "Apache installation failed. Exiting."
  systemctl stop httpd
  exit 1
else
  echo "Apache is OK, at least serving content via localhost"
fi
# stop apache because security
systemctl stop httpd

# make Apache restartable
systemctl enable httpd

# install maria DB for CentOs 7
yum -y install mariadb-server mariadb

# start the server
systemctl start mariadb

# check the status of the server
mysqlTest=$(systemctl status mariadb)
if [[ $mysqlTest =~ "Started MariaDB database server" ]]; then
    echo "Maria DB is running ok"
else
    echo "Maria DB installation failed. Exiting."
    systemctl stop mariadb
    exit 1
fi
# make mariadb restartable
systemctl enable mariadb

# set up the ez publish database
mysql -u root -e "use mysql; create database $fileSystemUserName charset utf8"
mysql -u root -e "use mysql; CREATE USER '$fileSystemUserName'@'localhost' IDENTIFIED BY '$databaseUserPassword'"
mysql -u root -e "use mysql; GRANT ALL PRIVILEGES ON $fileSystemUserName.* TO '$fileSystemUserName'@'localhost';"

# strip out the demo, and other insecure default stuff in mysql
# also, setup the root database user password
mysql -u root <<-EOF
UPDATE mysql.user SET Password=PASSWORD('$rootUserPassword') WHERE User='root';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
FLUSH PRIVILEGES;
EOF

# set up PHP, to get the minimum version required by lovestack, this is some extra work
# we wind up with, PHP v 5.6 (5.6.32 in testing)
# used instructions from here: https://rpms.remirepo.net/wizard/

yum -y install php php-mysql
yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
yum -y install http://rpms.remirepo.net/enterprise/remi-release-7.rpm
yum -y install yum-utils
yum-config-manager -y --enable remi-php56
yum -y update

# replace the line starting with ;date.timezone =
# capture the "date.timezone =" part
# and replace the whole line with date.timezone = America/Vancouver
sed -i 's#^\;\(date.timezone\s*=\s*\).*$#\1 America/Vancouver#' /etc/php.ini

yum -y install php-gd
yum -y install php-xml
yum -y install php-mbstring
yum -y install ImageMagick
yum -y install php-pear
yum -y install php-devel
yum -y install gcc

# install ezcomponents
pear channel-discover components.ez.no
pear install -a ezc/eZComponents

yum -y install git
cd /var/www/html
git clone https://github.com/mugoweb/ezpublish-legacy.git $domainName

# install ezfind ... not sure if we're going to make it work or not ...
cd /var/www/html/$domainName/extension
git clone https://github.com/mugoweb/ezfind.git ezfind

# set up permissions; this is more or less copied from the ezp install wizard
cd /var/www/html/$domainName
sudo chmod -R ug+rwx design extension settings settings/siteaccess var var/cache var/cache/ini var/log
sudo chown -R apache:apache design extension settings settings/siteaccess var var/cache var/cache/ini var/log

cd /var/www/html/$domainName
sudo chmod -R ug+rwx var/log
sudo chown -R apache:apache var/log

# set up eep
cd /var
git clone https://github.com/mugoweb/eep.git eep
cd /usr/bin
ln -s -T /var/eep/eep.php eep
# eep settings:
sed -i 's#\.\/\.eepdata#\/tmp\/\.eepdata#' /var/eep/eepSetting.php
sed -i 's#"\.\/"#"\/tmp\/"#' /var/eep/eepSetting.php



fi



# set up virtual host
cd /var/www/html/$domainName
eep use ezroot .
cd /etc/httpd/conf.d
eep kb vhost > $domainName.conf
sed -i "s#<<<servername>>>#$domainName#" /etc/httpd/conf.d/$domainName.conf
sed -i "s#apache_error\.log\.txt#apache_error\.log#" /etc/httpd/conf.d/$domainName.conf

# hack around SELinux 
# NOTE I am not sure that this is correct ...
semanage fcontext -a -t httpd_sys_rw_content_t '/var/www/html(/.*)?'
restorecon -R /var/www/html

















