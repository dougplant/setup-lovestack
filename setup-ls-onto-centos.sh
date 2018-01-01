# - script to fully setup a CentOS 7 instance with the Mugo LoveStack
# todo:
# - move the httpd and mariadb systemctl enable calls to the end of the script, generally biased against having them run if they're not fully set up
# - decide what to do about APC (or other op code cache) which is not currently being installed
# - setup the ezfind extension; activate it and secure it
# - set up the systemctl for solr
# - set up ezflow
# - install the stock db schema, and the lovestack patches?
# - do some good and standard mysql perf tweaks
# - review setting up Varnish by default

# other extensions:
# https://github.com/ezsystems/ezstarrating.git
# https://github.com/ezsystems/ezdemo.git
# https://github.com/ezsystems/ezmultiupload
# https://github.com/ezsystems/eztags.git
# https://github.com/ezsystems/ezscriptmonitor.git
# https://github.com/ezsystems/ezgmaplocation.git
# https://github.com/ezsystems/ezodf.git
# https://github.com/ezsystems/ezie.git
# https://github.com/ezsystems/ezautosave.git
# https://github.com/ezsystems/ezsi.git
# https://github.com/ezsystems/ezsurvey.git
# https://github.com/ezsystems/ezmbpaex.git (automatic password expiry)
# https://github.com/ezsystems/ezstyleeditor.git
# https://github.com/ezsystems/ezlightbox.git	

# other packages:
# https://github.com/ezsystems/ezflow.git
# https://github.com/ezsystems/ezwt.git
# https://github.com/ezsystems/ezwebin.git
# https://github.com/ezsystems/ezcomments.git

#--------------------------------------------------------------------------------------------------------

# escape for MySQL, just don't want to break any queries, not looking for injection attacks or anything
stringGlobal=""
function escapeForSQL() {
    string=$1
    string=${string//\\/\\\\}
    string=${string//\'/\\\'}
    string=${string//\"/\\\"}
    stringGlobal=$string
}

# install some utilities
function install_utilities() {
	yum -y install vim
	yum -y install tree
	yum -y install git
	#yum -y install gcc
}

function install_apache() {
	# install Apache
	yum -y install httpd

	# confirm apache installation: test that it is serving content, at least via localhost
	# note that this test is not idempotent
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
}

function install_mariadb() {
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

	# strip out the demo, and other insecure default stuff in mysql
	# also, setup the root database user password
	mysql -u root <<-EOF
	UPDATE mysql.user SET Password=PASSWORD('$rootUserPassword') WHERE User='root';
	DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
	DELETE FROM mysql.user WHERE User='';
	DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
	FLUSH PRIVILEGES;
	EOF

	# make mariadb restartable
	systemctl enable mariadb
}

function install_php() {
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

	#yum -y install php-curl
	# i have no idea if this is right, nor if it is actually required to make ezfind work
	yum install php-pear-Net-Curl.noarch
	yum -y install php-gd
	yum -y install php-xml
	yum -y install php-mbstring
	yum -y install ImageMagick
	yum -y install php-pear
	yum -y install php-devel
}

function install_eep() {
	# set up eep
	cd /var
	git clone https://github.com/mugoweb/eep.git eep
	cd /usr/bin
	ln -s -T /var/eep/eep.php eep
	# eep settings:
	sed -i 's#\.\/\.eepdata#\/tmp\/\.eepdata#' /var/eep/eepSetting.php
	sed -i 's#"\.\/"#"\/tmp\/"#' /var/eep/eepSetting.php
}

function configure_security() {
	# config SELinux to allow HTTPd access to the subtree
	semanage fcontext -a -t httpd_sys_rw_content_t '/var/www/html(/.*)?'
	restorecon -R /var/www/html

	# open the http and https ports in the firewall
	sudo firewall-cmd --zone=public --add-service=https --permanent
	sudo firewall-cmd --zone=public --add-service=http --permanent
	sudo firewall-cmd --reload

	# open port for solr/ezfind
	firewall-cmd --zone=public --add-port=8983/tcp --permanent
	firewall-cmd --reload
}

function install_ezcomponents() {
	# install ezcomponents
	pear channel-discover components.ez.no
	pear install -a ezc/eZComponents
}

function install_lovestack() {
	cd /var/www/html
	git clone https://github.com/mugoweb/ezpublish-legacy.git $domainName

	# install ezfind, might as well determine to always install ezfind
	# also because there is a related SQL patch that also has to be installed
	yum -y install java
	cd /var/www/html/$domainName/extension
	git clone https://github.com/mugoweb/ezfind.git ezfind

# --- --- --- --- --- --- --- --- --- 
cat > /etc/systemd/system/solr.service <<SolrSystemD
[Unit]
Description=Apache SOLR
After=syslog.target network.target remote-fs.target nss-lookup.target
 
[Service]
WorkingDirectory=/var/www/html/$domainName/extension/ezfind/java
PIDFile=solr.pid
User=root
ExecStart=/usr/bin/java -Dezfind -jar start.jar
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
PrivateTmp=true
 
[Install]
WantedBy=multi-user.target
SolrSystemD
# --- --- --- --- --- --- --- --- --- 

	# set up permissions; this is copied from the ezp install wizard
	cd /var/www/html/$domainName
	sudo chmod -R ug+rwx design extension settings settings/siteaccess var var/cache var/cache/ini var/log
	sudo chown -R apache:apache design extension settings settings/siteaccess var var/cache var/cache/ini var/log

	cd /var/www/html/$domainName
	sudo chmod -R ug+rwx var/log
	sudo chown -R apache:apache var/log
}

function install_ezdbschema() {
	cd /var/www/html/$domainName

	# set up the ez publish database
	mysql -u root --password=$rootUserPassword -e "use mysql; create database $fileSystemUserName charset utf8"
	mysql -u root --password=$rootUserPassword -e "use mysql; CREATE USER '$fileSystemUserName'@'localhost' IDENTIFIED BY '$databaseUserPassword'"
	mysql -u root --password=$rootUserPassword -e "use mysql; GRANT ALL PRIVILEGES ON $fileSystemUserName.* TO '$fileSystemUserName'@'localhost';"

	cd /var/www/html/$domainName
	# setup basic database schema, and then apply needed patches
	mysql -u root --password=$rootUserPassword $fileSystemUserName < ./kernel/sql/mysql/kernel_schema.sql
	# lovestack patches 
	mysql -u root --password=$rootUserPassword $fileSystemUserName < ./update/database/mysql/lovestack/1.sql
	mysql -u root --password=$rootUserPassword $fileSystemUserName < ./update/database/mysql/lovestack/2.sql
	# push in the ezp default dataset ... is the default admin user admin/publish?
	mysql -u root --password=$rootUserPassword $fileSystemUserName < ./kernel/sql/common/cleandata.sql
	# push in the schema changes for ezfind/solr
	mysql -u root --password=$rootUserPassword $fileSystemUserName < ./extension/ezfind/sql/mysql/mysql.sql

}

function install_virtualhost() {
	# set up virtual host
	cd /var/www/html/$domainName
	eep use ezroot .
	cd /etc/httpd/conf.d
	eep kb vhost > $domainName.conf
	sed -i "s#<<<servername>>>#$domainName#" /etc/httpd/conf.d/$domainName.conf
	sed -i "s#apache_error\.log\.txt#apache_error\.log#" /etc/httpd/conf.d/$domainName.conf
}

# set up the settings files and siteaccesses
function install_settingsfiles() {

cd /var/www/html/$domainName
mkdir -p ./settings/override
mkdir -p ./settings/siteaccess/site
mkdir -p ./settings/siteaccess/manage

# --- --- --- --- --- --- --- --- --- 
cat > ./settings/override/site.ini.append.php <<OverrideSiteIni
<?php /* #?ini charset="utf-8"?

# override site.ini, installed via $0

[DatabaseSettings]
DatabaseImplementation=ezmysqli
Server=localhost
Port=
User=$fileSystemUserName
Password=$databaseUserPassword
Database=$fileSystemUserName
Charset=
Socket=disabled

[SiteAccessSettings]
# turn off the setup wizard
CheckValidity=false
AvailableSiteAccessList[]
AvailableSiteAccessList[]=site
AvailableSiteAccessList[]=manage
MatchOrder=uri
HostMatchMapItems[]

[RegionalSettings]
Locale=eng-US
TextTranslation=disabled

[ExtensionSettings]
ActiveExtensions[]
ActiveExtensions[]=ezfind
ActiveExtensions[]=ezjscore
ActiveExtensions[]=ezoe
ActiveExtensions[]=ezformtoken

[SiteSettings]
DefaultAccess=site
SiteList[]
SiteList[]=site
SiteList[]=manage
RootNodeDepth=1

[Session]
SessionNameHandler=custom

[UserSettings]
LogoutRedirect=/

[DesignSettings]
DesignLocationCache=enabled

[RegionalSettings]
TranslationSA[]
TranslationSA[eng]=Eng

[FileSettings]
VarDir=var/lovestack

[MailSettings]
Transport=sendmail
AdminEmail=hi@mugo.ca
EmailSender=hi@mugo.ca

[EmbedViewModeSettings]
AvailableViewModes[]
AvailableViewModes[]=embed
AvailableViewModes[]=embed-inline
InlineViewModes[]
InlineViewModes[]=embed-inline


[DebugSettings]
## DebugByIP=enabled
## DebugIPList[]
## DebugIPList[]=127.0.0.1
DebugOutput=enabled
DebugRedirection=disabled

[TemplateSettings]
# Use either enabled to see which template files are loaded or disabled to supress debug
Debug=enabled
ShowXHTMLCode=disabled

# If enabled will add a table with templates used to render a page.
# DebugOutput should be enabled too.
ShowUsedTemplates=enabled
# Determines whether the templates should be compiled to PHP code, by enabling this the loading
# and parsing of templates is omitted and template processing is significantly reduced.
# Note: The first time the templates are compiled it will take a long time, use the
#       bin/php/eztc.php script to prepare all your templates.
TemplateCompile=disabled
# Controls all template base caching mechanisms, if disabled they will never be
# used.
# The elements currently controlled by this is:
# - cache-block
TemplateCache=disabled
# Controls if development is enabled or not.
# When enabled the system will perform more checks like modification time on
# compiled vs source file and will reduce need for clearing template compiled
# files.
# Note: Live sites should not have this enabled since it increases file access
#       and can be slower.
# Note: When switching this setting the template compiled files must be cleared.
DevelopmentMode=enabled

[ContentSettings]
# Whether to use view caching or not
ViewCaching=disabled


*/ ?\>
OverrideSiteIni
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
cat > ./settings/override/i18n.ini.append.php <<OverrideI18nIni
<?php /* #?ini charset="utf-8"?
[CharacterSettings]
Charset=utf-8
*/ ?\>
OverrideI18nIni
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
cat > ./settings/override/image.ini.append.php <<OverrideImageIni
<?php /* #?ini charset="utf-8"?
[ImageMagick]
IsEnabled=true
ExecutablePath=/usr/bin
Executable=convert
*/ ?>
OverrideImageIni
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
cat > ./settings/siteaccess/manage/content.ini.append.php <<ManageContentIni
<?php /* #?ini charset="utf-8"?
[VersionView]
AvailableSiteDesignList[]
AvailableSiteDesignList[]=site
AvailableSiteDesignList[]=admin
*/ ?\>
ManageContentIni
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
cat > ./settings/siteaccess/manage/contentstructuremenu.ini.append.php <<ManageContentStructureMenu
<?php /* #?ini charset="utf-8"?

[TreeMenu]
Dynamic=enabled
ShowClasses[]
ShowClasses[]=article
ShowClasses[]=comment
ShowClasses[]common_ini_settings
ShowClasses[]=file
ShowClasses[]=folder
ShowClasses[]=image
ShowClasses[]=link
ShowClasses[]=template_look
ShowClasses[]=user
ShowClasses[]=user_group

*/ ?>
ManageContentStructureMenu
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
cat > ./settings/siteaccess/manage/ezoe.ini.append.php <<ManageEzoeIni
<?php /* #?ini charset="utf-8"?
[VersionView]
AvailableSiteDesignList[]
AvailableSiteDesignList[]=site
AvailableSiteDesignList[]=admin
*/ ?\>
ManageEzoeIni
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
cat > ./settings/siteaccess/manage/icon.ini.append.php <<ManageIconIni
<?php /* #?ini charset="utf-8"?
[IconSettings]
Theme=crystal-admin
Size=normal
*/ ?\>
ManageIconIni
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
cat > ./settings/siteaccess/manage/site.ini.append.php <<ManageSiteIni
<?php /* #?ini charset="utf-8"?

# manage site.ini, installed via $0

[SiteSettings]
SiteName=LoveStack Barebone Site
SiteURL=$domainName
DefaultPage=content/dashboard
LoginPage=custom

[UserSettings]
RegistrationEmail=

[SiteAccessSettings]
RequireUserLogin=true
RelatedSiteAccessList[]=site
RelatedSiteAccessList[]=manage
ShowHiddenNodes=true

[DesignSettings]
SiteDesign=admin
AdditionalSiteDesignList[]
AdditionalSiteDesignList[]=admin

[RegionalSettings]
Locale=eng-US
ContentObjectLocale=eng-US
ShowUntranslatedObjects=enabled
SiteLanguageList[]=eng-US
TextTranslation=disabled

[FileSettings]
VarDir=var/lovestack

[ContentSettings]
CachedViewPreferences[full]=admin_navigation_content=1;admin_children_viewmode=list;admin_list_limit=1
TranslationList=

[MailSettings]
AdminEmail=hi@mugo.ca
EmailSender=hi@mugo.ca

?\>
ManageSiteIni
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
cat > ./settings/siteaccess/manage/viewcache.ini.append.php <<ManageViewcacheIni
<?php /* #?ini charset="utf-8"?
[ViewCacheSettings]
SmartCacheClear=enabled
*/ ?\>
ManageViewcacheIni
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
# this override.ini is sufficient to get us started
mv ./settings/siteaccess/base/override.ini.append ./settings/siteaccess/site/override.ini.append.php
# ... and these others too, I guess
mv ./settings/siteaccess/base/forum.ini ./settings/siteaccess/site/forum.ini.append.php
mv ./settings/siteaccess/base/image.ini.append ./settings/siteaccess/site/image.ini.append.php
mv ./settings/siteaccess/base/toolbar.ini.append ./settings/siteaccess/site/toolbar.ini.append.php
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
# build the site.ini for the public side
cat > ./settings/siteaccess/site/site.ini.append.php <<SiteSiteIni
<?php /* #?ini charset="utf-8"?

# site site.ini, installed via $0

[Session]
SessionNamePerSiteAccess=disabled

[SiteSettings]
LoginPage=embedded
SiteName=$domainName
SiteURL=$domainName
AdditionalLoginFormActionURL=http://$domainName/manage/user/login
DefaultPage=/content/view/full/2
IndexPage=/content/view/full/2
ErrorHandler=displayerror

[SiteAccessSettings]
RequireUserLogin=false
RelatedSiteAccessList[]
RelatedSiteAccessList[]=site
RelatedSiteAccessList[]=manage
ShowHiddenNodes=false

[DesignSettings]
SiteDesign=mysite
AdditionalSiteDesignList[]
#AdditionalSiteDesignList[]=ezflow
AdditionalSiteDesignList[]=base
# this is possibly redundant since "standard" is included in the default setting "StandardDesign"
AdditionalSiteDesignList[]=standard

[RegionalSettings]
Locale=eng-US
ContentObjectLocale=eng-US
ShowUntranslatedObjects=disabled
SiteLanguageList[]
SiteLanguageList[]=eng-US
TextTranslation=disabled

[FileSettings]
VarDir=var/site

[ContentSettings]
TranslationList=

[MailSettings]
AdminEmail=hi@mugo.ca
EmailSender=hi@mugo.ca
*/ ?\>
SiteSiteIni
# --- --- --- --- --- --- --- --- --- 

# --- --- --- --- --- --- --- --- --- 
# delete a bunch of garbage design and settings stuff
rm -rf ./design/plain/
rm -rf ./settings/siteaccess/plain
rm -rf ./settings/siteaccess/base
rm -rf ./settings/siteaccess/mysite
# --- --- --- --- --- --- --- --- --- 

}

# ---------------------------------------------------------------------------------------------

# get the various inputs needed from the user:

# get the name of the filesystem and db user
fileSystemUserName="tester"
read -p "Enter username (for db account and fs ownership) [$fileSystemUserName]: " inputString
if [ "" != "$inputString" ]; then
    fileSystemUserName=$inputString
fi

# get password for the (single) filesystem user, this will be how to SSH into the host
fileSystemUserPassword="pwdfs"
read -p "Enter fs password for this user [$fileSystemUserPassword]: " inputString
if [ "" != "$inputString" ]; then
    fileSystemUserPassword=$inputString
fi
escapeForSQL $fileSystemUserPassword
fileSystemUserPassword=$stringGlobal

# get password for the database use (so as to not use root)
databaseUserPassword="pwddb"
read -p "Enter db password for this user [$databaseUserPassword]: " inputString
if [ "" != "$inputString" ]; then
    databaseUserPassword=$inputString
fi
escapeForSQL $databaseUserPassword
databaseUserPassword=$stringGlobal

# get password for the root database password
rootUserPassword="rootroot"
read -p "Enter db password for the root user [$rootUserPassword]:" inputString
if [ "" != "$inputString" ]; then
    rootUserPassword=$inputString
fi
escapeForSQL $rootUserPassword
rootUserPassword=$stringGlobal

# get intended domain name
domainName="tester.test.com"
read -p "Enter the full domain name for this host [$domainName]:" inputString
if [ "" != "$inputString" ]; then
    domainName=$inputString
fi

# just for debugging purposes, dump the various input values we've captured
echo "file-system-user name:" $fileSystemUserName
echo "file-system-user ssh password:" $fileSystemUserPassword
echo "file-system-user database password:" $databaseUserPassword
echo "root-user database password:" $rootUserPassword
echo "the full domain name:" $domainName

#install_utilities

#install_apache

#install_mariadb

#install_php

configure_security

#install_eep

#install_ezcomponents

install_lovestack

#install_ezdbschema

#install_virtualhost

install_settingsfiles
rm -f ./var/cache/ini/*

cd /var/www/html/$domainName/
php bin/php/ezcache.php --clear-all --allow-root-user
php bin/php/ezpgenerateautoloads.php





