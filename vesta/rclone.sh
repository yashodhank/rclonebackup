#!/bin/bash

# SERVER_NAME="$(ifconfig | grep broadcast | awk {'print $2'} | head -1)" # get IP
# SERVER_NAME="$(ifconfig | grep broadcast | awk {'print $2'} | awk '{if(NR==1) print $0}')"
# SERVER_NAME="$(ifconfig | grep broadcast | awk {'print $2'} | sed -n 1p)"
VESTABIN="/usr/local/vesta/bin"
SERVER_NAME="$($VESTABIN/v-list-sys-info plain | awk {'print $1'})"
BUCKET_NAME="monjin-wp"
TIMESTAMP=$(date +"%F")
BACKUP_DIR="/mnt/backup-vnc/$TIMESTAMP"
#VESTAUSERS="$($VESTABIN/v-list-users | sed 1,2d | awk {'print $1'})" # kind of hacky
VESTAUSERS="$($VESTABIN/v-list-sys-users plain)" # clean approach
MYSQLPATH="$(mysql --help | grep "Default options" -A 1 | sed -n 2p | awk {'print $2'} | sed 's/\~/\/root/')"
MYSQL_USER="$(cat /usr/local/vesta/conf/mysql.conf | awk {'print $2'} | awk -F '=' {'print $NF'} | sed "s/'//g")"
MYSQL_PASSWORD="$(cat /usr/local/vesta/conf/mysql.conf | awk {'print $3'} | awk -F '=' {'print $NF'} | sed "s/'//g")"
MYSQL="$(which mysql)"
MYSQLDUMP="$(which mysqldump)"
SECONDS=0
#CHECKSQL="$(ls /usr/bin/ | grep mysql)"
CHECKSQL="$(type mysql >/dev/null 2>&1 && echo 'mysql' || echo 'null')"
NGINX="$(ls /etc/ | grep nginx)"
NGINX_DIR="$(nginx -V 2>&1 | grep -o '\-\-conf-path=\(.*conf\)' | grep -o '.*/' | awk -F '=' {'print $NF'})"
HTTPD="$(ls /etc/ | grep -w httpd)"
HTTPD_DIR="$(httpd -S 2>&1 | grep ServerRoot | sed 's/\"//g' | awk {'print $2'})"
LOG_DIR=/var/log
VESTA="$(ls /usr/local/ | grep vesta)"
VNC_RCLONE="$(rclone config file | grep rclone.conf | sed 's/rclone.conf//')"
VNC_RCLONE_REMOTE="$(cat $VNC_RCLONE/rclone.conf | grep "\[" | sed 's/\[//' | sed 's/\]//')"
mkdir -p "$BACKUP_DIR"

if [[ $CHECKSQL == "mysql" ]];

then
 	mkdir -p "$BACKUP_DIR/mysql"
        db_access() {
          if [ -r /usr/local/vesta/conf/mysql.conf ] && [ -s /usr/local/vesta/conf/mysql.conf ]
          then
             DBACCESSARG="--defaults-file=/usr/local/vesta/conf/mysql.conf"
          else
             DBACCESSARG="--user=$MYSQL_USER -p$MYSQL_PASSWORD"
          fi
        }
#  		databases=`$MYSQL --user=$MYSQL_USER -p$MYSQL_PASSWORD -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema|mysql)"`
               databases=`$MYSQL $DBACCESSARG -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema|mysql)"`

	echo "Starting Backup Database";

	for db in $databases; do
    	$MYSQLDUMP --force --opt $DBACCESSARG --databases $db | gzip > "$BACKUP_DIR/mysql/$db.sql.gz"
	done
	echo "Finished";
	echo '';
else
	echo "Failed to locate mysql on VPS"
fi

size=$(du -sh $BACKUP_DIR | awk '{ print $1}')

echo "Starting Backup Website";
# Backup vesta user backup using v-backup-user
if [[ "$VESTA" = "vesta" ]]; then

	echo "VPS User vestacp ";
	echo "Backup vestacp Config";
	cp -r /usr/local/vesta $BACKUP_DIR/vesta
        tar -zcf $BACKUP_DIR/usr_local_vesta.tar.gz $BACKUP_DIR/vesta #pack dir
        rm -fr $BACKUP_DIR/vesta/ #remove unpacked dir as we dont want it in s3 uploads
        echo "Backup each vesta users and their sites: config, files, mails and db"
        for user in ${VESTAUSERS}; do
              echo "Backing up Vesta User: ${user}"
              $VESTABIN/v-backup-user $user | tee /dev/stderr | grep "Local:" | awk {'print $4'} >> $BACKUP_DIR/backup_tar_list.txt
              echo "Backup for Vesta User: ${user} is completed!"
        done
        cp $(<$BACKUP_DIR/backup_tar_list.txt) $BACKUP_DIR
else
	echo "NOT User Vestacp"
fi
echo "Finished";
echo '';

size=$(du -sh $BACKUP_DIR | awk '{ print $1}')

echo "Starting Backup Server Configuration";
mkdir -p $BACKUP_DIR/log
if [ "$NGINX" = "nginx" ] && [ "$HTTPD" = "httpd" ]
then
	echo "Starting Backup nginx proxy, apache backend Configuration";
	cp -r $NGINX_DIR $BACKUP_DIR/nginx
	cp -r $HTTPD_DIR $BACKUP_DIR/httpd
	cp -r $LOG_DIR/{nginx,apache2,mysql} $BACKUP_DIR/log
        tar -zcf $BACKUP_DIR/nginx_httpd_rproxy_mysql_conf_logs.tar.gz $BACKUP_DIR/nginx $BACKUP_DIR/httpd $BACKUP_DIR/log
        rm -rf $BACKUP_DIR/nginx/
        rm -rf $BACKUP_DIR/httpd/
        rm -rf $BACKUP_DIR/log/
	echo "Finished";
	echo '';
elif [ "$NGINX" = "nginx" ];
then
	echo "Starting Backup NGINX Configuration";
	cp -r $NGINX_DIR $BACKUP_DIR/nginx
	cp -r $LOG_DIR/{nginx,mysql} $BACKUP_DIR/log
        tar -zcf $BACKUP_DIR/nginx_mysql_conf_logs.tar.gz $BACKUP_DIR/nginx $BACKUP_DIR/log
        rm -rf $BACKUP_DIR/nginx/
        rm -rf $BACKUP_DIR/log/
	echo "Finished";
	echo '';

elif [ "$HTTPD" = "httpd" ];
then
	echo "Starting Backup HTTPD (apache) Configuration";
	cp -r $HTTPD_DIR $BACKUP_DIR/httpd
	cp -r $LOG_DIR/{apache2,mysql} $BACKUP_DIR/log
        tar -zcf $BACKUP_DIR/httpd_mysql_conf_logs.tar.gz $BACKUP_DIR/httpd $BACKUP_DIR/log
        rm -rf $BACKUP_DIR/httpd/
        rm -rf $BACKUP_DIR/log/
	echo "Finished";
	echo '';
else
	echo "VPS directory http, nginx not found";
fi


size=$(du -sh $BACKUP_DIR | awk '{ print $1}')

echo "Starting Uploading Backup";

for i in $VNC_RCLONE_REMOTE
	do
		rclone copy --s3-force-path-style=false --s3-no-check-bucket $BACKUP_DIR "$i:$BUCKET_NAME/$SERVER_NAME/$TIMESTAMP" >> /var/log/rclone.log 2>&1
	echo "done upload $i"
done

# Clean up



for i in $VNC_RCLONE_REMOTE
	do
		rclone -q --min-age 90d delete --s3-force-path-style=false "$i:$BUCKET_NAME/$SERVER_NAME"
	echo "done remote $i"
done

rm -rf $BACKUP_DIR
echo "Finished";
echo '';

duration=$SECONDS
echo "Total $size, $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."
