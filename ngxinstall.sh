#!/bin/sh
## vim: set expandtab sw=4 ts=4 sts=4:
##
## ngxinstall.sh
##   © Copyright 2018 ServerPartners 
##      http://serverpartners.net
##
## Simple shell script to install nginx with Wordpress, user is jailed 
## using chroot setup to improve security. Send bug report to asfik@svrpnr.net.
##

log=/root/ngxinstall.log

red="$(tput setaf 1)"
green="$(tput setaf 2)"
yellow="$(tput setaf 3)"
cyan="$(tput setaf 6)"
normal="$(tput sgr0)"

# check if the script run as root
curruid=$(id -u)
if [ "${curruid}" -ne "0" ]; then
    echo
    printf "${red}⛔ ${cyan}Please switch to root account.${normal}\n\n"
    exit 1
fi

# check CentOS version
if [ -f /etc/centos-release ]; then
    version=$(cut -d" " -f4 /etc/centos-release | cut -d "." -f1)
    if [ "${version}" -ne "7" ]; then
        echo
        printf "${red}⛔ ${cyan}Sorry this script only work on CentOS 7.${normal}\n\n"
        exit 1
    fi
else
    echo
    printf "${red}⛔ ${cyan}Sorry this script only work on CentOS 7.${normal}\n\n"
    exit 1
fi

# print general usage
usage () {
    echo
    printf "Usage: ${cyan}./ngxinstall.sh ${normal}--domainname ${green}<domainname> ${normal} --username ${green}<username> ${normal}--email ${green}<email>${normal}\n"
    echo 
}

# check command line arguments number
if [[ $# -eq 0 || $# -lt 6 ]];then
    usage
    exit 1
fi

# capture the variables from arguments
while [ "$1" != "" ]; do
    case $1 in
        --help)
            usage
            exit 0
            ;;
        --domainname)
            shift
            domainname=$1
            shift
            ;;
        --username)
            shift
            username=$1
            shift
            ;;
        --email)
            shift
            email=$1
            shift
            ;;
        *)
            printf "Unrecognized option: $1\n\n"
            usage
            exit 1
            ;;
    esac
done

# check if the username exist
if [ ! -x /usr/bin/getent ]; then
    yum -y -q install glibc-common
fi

getent passwd ${username} > /dev/null 2&>1
retval=$?

if [ "${retval}" -eq 0 ]; then
    echo
    printf "${red}⛔ ${cyan}username ${username} already exist, please choose other name.${normal}\n\n"
    exit 1
fi

# just another counter
timestart=$(date +%s)

# disable selinux
if [ -x /sbin/setenforce ]; then
    /sbin/setenforce 0
    sed -i 's/^SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
fi

# whitelist port 80 and 443 if firewalld enabled
if [ -x /usr/bin/firewall-cmd ]; then
    status=$(firewall-cmd --state)
    if [ "${status}" == "running" ]; then
        firewall-cmd --zone=public --add-service=http > /dev/null 2>&1
        firewall-cmd --zone=public --add-service=https > /dev/null 2>&1
        firewall-cmd --zone=public --permanent --add-service=http > /dev/null 2>&1
        firewall-cmd --zone=public --permanent --add-service=https > /dev/null 2>&1
    fi
fi

# install necessary packages and additional repositories
echo
printf "▣ ${cyan}installing EPEL repo...${normal}" 
yum -y install epel-release > $log 2>&1
printf "${green}done ✔${normal}\n"
printf "▣ ${cyan}installing Remi repo...${normal}" 
yum -y install http://rpms.remirepo.net/enterprise/remi-release-7.rpm >> $log 2>&1
printf "${green}done ✔${normal}\n"
printf "▣ ${cyan}installing packages...${normal}" 
yum -y install git wget vim-enhanced curl yum-utils gcc make unzip lsof telnet bind-utils shadow-utils sudo >> $log 2>&1
printf "${green}done ✔${normal}\n"

# install Postfix
printf "▣ ${cyan}installing Postfix...${normal}"
rpm -e --nodeps sendmail sendmail-cf >> $log 2>&1
yum -y install postfix >> $log 2>&1
systemctl enable postfix >> $log 2>&1
systemctl start postfix >> $log 2>&1
printf "${green}done ✔${normal}\n"

# download config files from git repository
printf "▣ ${cyan}cloning files from git...${normal}"
cd /tmp 
rm -rf ngxinstall
git clone https://github.com/asfihani/ngxinstall.git >> $log 2>&1
retval=$?
if [ "${retval}" -ne 0 ]; then
    printf "${red}⛔ ${cyan}unable to copy files from git.${normal}\n\n"
    exit 1
else
    printf "${green}done ✔${normal}\n"
fi

# setup jailkit and account
printf "▣ ${cyan}installing jailkit...${normal}"
cd /tmp
rm -rf jailkit*
wget http://olivier.sessink.nl/jailkit/jailkit-2.19.tar.gz  >> $log 2>&1

if [ -f "jailkit-2.19.tar.gz" ]; then
    tar -xzvf jailkit-2.19.tar.gz  >> $log 2>&1
    cd jailkit-2.19 >> $log
    ./configure  >> $log 2>&1
    make >> $log 2>&1
    make install >> $log 2>&1
    cp -p /tmp/ngxinstall/config/jk_init.ini /etc/jailkit/jk_init.ini
    printf "${green}done ✔${normal}\n"
else
    printf "${red}⛔ ${cyan}unable to downlog jailkit from https://olivier.sessink.nl/jailkit/.${normal}\n\n"
    exit 1
fi

# setup chroot for account
printf "▣ ${cyan}configuring account...${normal}"
mkdir /chroot >> $log 2>&1
password=$(</dev/urandom tr -dc '12345#%qwertQWERTasdfgASDFGzxcvbZXCVB' | head -c16; echo "")
adduser ${username}
echo "${username}:${password}" | chpasswd
mkdir -p /chroot/${username}

if [ -d "/chroot/${username}" ]; then
    jk_init -j /chroot/${username} basicshell editors extendedshell netutils ssh sftp scp basicid >> $log 2>&1
    jk_jailuser -s /bin/bash -m -j /chroot/${username} ${username} >> $log 2>&1
    mkdir -p /chroot/${username}/home/${username}/{public_html,logs}
    echo '<?php phpinfo(); ?>' | tee -a /chroot/${username}/home/${username}/public_html/info.php 
    chown -R ${username}: /chroot/${username}/home/${username}/{public_html,logs}
    chmod 755  /chroot/${username}/home/${username} /chroot/${username}/home/${username}/{public_html,logs}
    printf "${green}done ✔${normal}\n"
else
    printf "${red}⛔ ${cyan}can't configure jailkit.${normal}\n\n"
    exit 1
fi

# configure nginx
printf "▣ ${cyan}configuring nginx...${normal}"
cp -p /tmp/ngxinstall/config/nginx.repo /etc/yum.repos.d/nginx.repo
yum -y install nginx >> $log 2>&1

mv /etc/nginx/nginx.conf{,.orig}
cp -p /tmp/ngxinstall/config/nginx.conf /etc/nginx/nginx.conf
mkdir -p /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ >> $log 2>&1
cp -p /tmp/ngxinstall/config/vhost.tpl /etc/nginx/sites-enabled/${domainname}.conf

sed -i "s/%%domainname%%/${domainname}/g" /etc/nginx/sites-enabled/${domainname}.conf
sed -i "s/%%username%%/${username}/g" /etc/nginx/sites-enabled/${domainname}.conf

cp -p /tmp/ngxinstall/config/wordpress.tpl /etc/nginx/conf.d/wordpress.conf
cp -p /tmp/ngxinstall/config/wp_super_cache.tpl /etc/nginx/conf.d/wp_super_cache.conf 

openssl dhparam -dsaparam -out /etc/nginx/dhparam.pem 4096 >> $log 2>&1

# remove apache if installed
if rpm -q --quiet httpd; then 
    systemctl stop httpd >> $log 2>&1
    systemctl disable httpd >> $log 2>&1
fi

# start nginx
systemctl enable nginx >> $log 2>&1
systemctl start nginx >> $log 2>&1

ngxstatus=$(systemctl is-active nginx)

if [ "${ngxstatus}" == "active" ]; then
    printf "${green}done ✔${normal}\n"
else
    systemctl status nginx >> $log 2>&1
    printf "${red}⛔ ${cyan}failed to start nginx.${normal}\n\n"
    exit 1
fi

# installing php 7.2
printf "▣ ${cyan}installing PHP 7.2...${normal}"
yum-config-manager --enable remi-php72 >> $log 2>&1

yum -y install php php-mysqlnd php-curl php-simplexml \
php-devel php-gd php-json php-pecl-mcrypt php-mbstring php-opcache php-pear \
php-pecl-apcu php-pecl-geoip php-pecl-json-post php-pecl-memcache php-pecl-xmldiff \
php-pecl-zip php-pspell php-soap php-tidy php-xml php-xmlrpc php-fpm >> $log 2>&1

sed -i 's/^max_execution_time =.*/max_execution_time = 300/g' /etc/php.ini
sed -i 's/^memory_limit =.*/memory_limit = 256M/g' /etc/php.ini
sed -i 's/^upload_max_filesize =.*/upload_max_filesize = 64M/g' /etc/php.ini
sed -i 's/^post_max_size =.*/post_max_size = 64M/g' /etc/php.ini
#sed -i 's{^;date.timezone =.*{date.timezone = "Asia/Jakarta"{g' /etc/php.ini
sed -i 's/^;opcache.revalidate_freq=2/opcache.revalidate_freq=60/g' /etc/php.d/10-opcache.ini
sed -i 's/^;opcache.fast_shutdown=0/opcache.fast_shutdown=1/g' /etc/php.d/10-opcache.ini
printf "${green}done ✔${normal}\n"

# configure php-fpm
printf "▣ ${cyan}configuring php-fpm...${normal}"
mv /etc/php-fpm.d/www.conf{,.orig}
touch /etc/php-fpm.d/www.conf

cp -p /tmp/ngxinstall/config/php-fpm.tpl /etc/php-fpm.d/${domainname}.conf 

sed -i "s/%%domainname%%/${domainname}/g" /etc/php-fpm.d/${domainname}.conf
sed -i "s/%%username%%/${username}/g" /etc/php-fpm.d/${domainname}.conf

systemctl enable php-fpm >> $log 2>&1
systemctl start php-fpm >> $log 2>&1

fpmtatus=$(systemctl is-active php-fpm)

if [ "${fpmtatus}" == "active" ]; then
    printf "${green}done ✔${normal}\n"
else
    systemctl status php-fpm >> $log 2>&1
    printf "${red}⛔ ${cyan}failed to start php-fpm.${normal}\n\n"
    exit 1
fi

# install MariaDB
printf "▣ ${cyan}installing MariaDB...${normal}"
cp -p /tmp/ngxinstall/config/mariadb.repo /etc/yum.repos.d/mariadb.repo

yum -y install MariaDB-server MariaDB-client MariaDB-compat MariaDB-shared >> $log 2>&1

systemctl enable mariadb >> $log 2>&1
systemctl start mariadb >> $log 2>&1

mariadbstatus=$(systemctl is-active mariadb)

if [ "${mariadbstatus}" == "active" ]; then
    printf "${green}done ✔${normal}\n"
else
    systemctl status mariadb >> $log 2>&1
    printf "${red}⛔ ${cyan}failed to start mariadb.${normal}\n\n"
    exit 1
fi

# configure MariaDB
printf "▣ ${cyan}configuring MariaDB...${normal}"
mysqlpass=$(</dev/urandom tr -dc '12345#%qwertQWERTasdfgASDFGzxcvbZXCVB' | head -c16; echo "")
mysqladmin -u root password "${mysqlpass}"

mysql -u root -p"${mysqlpass}" -e "UPDATE mysql.user SET Password=PASSWORD('${mysqlpass}') WHERE User='root'"
mysql -u root -p"${mysqlpass}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')"
mysql -u root -p"${mysqlpass}" -e "DELETE FROM mysql.user WHERE User=''"
mysql -u root -p"${mysqlpass}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%'"
mysql -u root -p"${mysqlpass}" -e "FLUSH PRIVILEGES"

cat > ~/.my.cnf <<EOF
[client]
password = '${mysqlpass}'
EOF
printf "${green}done ✔${normal}\n"

# create MySQL database for Wordpress
printf "▣ ${cyan}creating Wordpress database...${normal}"
wpdbpass=$(</dev/urandom tr -dc '12345#%qwertQWERTasdfgASDFGzxcvbZXCVB' | head -c16; echo "")

cat > /tmp/create.sql <<EOF
create database ${username}_wp;
grant all privileges on ${username}_wp.* to ${username}_wp@localhost identified by '${wpdbpass}';
flush privileges;
EOF

mysql < /tmp/create.sql 
rm -rf /tmp/create.sql
printf "${green}done ✔${normal}\n"

# installing WPCLI
printf "▣ ${cyan}installing wpcli...${normal}"
wget https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -O /usr/local/bin/wp >> $log 2>&1
chmod 755 /usr/local/bin/wp
printf "${green}done ✔${normal}\n"

# install Wordpress
printf "▣ ${cyan}installing Wordpress...${normal}"
cd /chroot/${username}/home/${username}/public_html
wpadminpass=$(</dev/urandom tr -dc '12345#%qwertQWERTasdfgASDFGzxcvbZXCVB' | head -c16; echo "")

sudo -u ${username} bash -c "/usr/local/bin/wp core download" >> $log 2>&1
sudo -u ${username} bash -c "/usr/local/bin/wp core config --dbname=${username}_wp --dbuser=${username}_wp --dbpass=${wpdbpass} --dbhost=localhost --dbprefix=wp_" >> $log 2>&1
sudo -u ${username} bash -c "/usr/local/bin/wp core install --url=${domainname} --title='Just another Wordpress site' --admin_user=${username} --admin_password=${wpadminpass} --admin_email=${email}" >> $log 2>&1
sudo -u ${username} bash -c "/usr/local/bin/wp plugin install really-simple-ssl wp-super-cache" >> $log 2>&1
printf "${green}done ✔${normal}\n"

# install letsencrypt certbot
printf "▣ ${cyan}installing letsencrypt certbot...${normal}"
yum -y install certbot >> $log 2>&1
printf "${green}done ✔${normal}\n"

# configuring letsencrypt
printf "▣ ${cyan}configuring letsencrypt...${normal}"

domipaddr=$(dig +short ${domainname})
svripaddr=$(curl -sSL http://cpanel.com/showip.cgi)

if [ "${domipaddr}" == "${svripaddr}" ]; then
    mkdir -p /etc/letsencrypt
    cp -p /tmp/ngxinstall/config/cli.ini /etc/letsencrypt/cli.ini 
    sed -i "s{%%email%%{${email}{g" /etc/letsencrypt/cli.ini
    
    # check if www record exist and add it to the pool
    wwwipaddr=$(dig +short www.${domainname})
    
    # request certificate
    if [ "${wwwipaddr}" == "${svripaddr}" ]; then
        certbot certonly --webroot -w /chroot/${username}/home/${username}/public_html -d ${domainname} -d www.${domainname} >> $log 2>&1
    else
        certbot certonly --webroot -w /chroot/${username}/home/${username}/public_html -d ${domainname} >> $log 2>&1
    fi

    retval=$?
    # check if certbot successfully issue certificate
    if [ "${retval}" -eq 0 ]; then
    
        # activate ssl section in nginx config
        sed -i "s{^#{{g" /etc/nginx/sites-enabled/${domainname}.conf

        # check if new configuration is fine
        /usr/sbin/nginx -t >> $log 2>&1
        retval=$?

        if [ "${retval}" -eq 0 ]; then
            # restart nginx
            /usr/sbin/nginx -s reload >> $log 2>&1
        else
            printf "${red}⛔ warning, nginx config seem broken, consider to check the log.${normal}\n"
        fi

        # install certbot autorenew cron
        echo "0 0,12 * * * /usr/bin/python -c 'import random; import time; time.sleep(random.random() * 3600)' && /usr/bin/certbot renew -q --post-hook 'systemctl restart nginx'" > /tmp/le.cron
        crontab /tmp/le.cron
        rm -rf /tmp/le.cron
        printf "${green}done ✔${normal}\n"
    
    else
        printf "${red}error ⛔, certbot can't issue certificate, check the log.${normal}\n"
    fi

else
    printf "${red}skipped ⛔ (IP address probably not pointed to this server).${normal}\n"
fi

# print all details
echo
echo "==========================================================================="
echo "SFTP"
echo "Domain name   : ${red}${domainname}${normal}"
echo "Username      : ${cyan}${username}${normal}"
echo "Password      : ${green}${password}${normal}"
echo "Document root : ${yellow}/chroot/${username}/home/${username}/{public_html${normal}"
echo
echo "Wordpress"
echo "Username      : ${cyan}${username}${normal}"
echo "Password      : ${green}${wpadminpass}${normal}"
echo "URL           : ${yellow}http://${domainname}/wp-admin/${normal}"
echo
echo "Don't forget to enable Really Simple SSL plugin if letsencrypt available"
echo "and configure WP Super Cache as well. Enjoy!"
echo "==========================================================================="
echo

# clean all temporary files
rm -rf /tmp/ngxinstall /tmp/jailkit*

# exit and print duration
timeend=$(date +%s)
duration=$(echo $((timeend-timestart)) | awk '{print int($1/60)"m "int($1%60)"s"}')
printf "${green}▣▣▣ ${normal}time spent: ${yellow}${duration}${green} ▣▣▣${normal}\n\n"
