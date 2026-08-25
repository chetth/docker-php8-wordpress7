#!/bin/sh
## check if docker supports 'docker compose' (Compose V2)?
if ! command -v docker >/dev/null 2>&1; then
  echo "docker not installed,"
  echo "follow this https://docs.docker.com/engine/install/ to install it first."
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "your docker does not support 'docker compose' (Compose V2),"
  echo "please upgrade Docker or follow this https://docs.docker.com/compose/install/ to install the compose plugin."
  exit 1
fi
echo "Download latest WordPress..."
wget -O - https://wordpress.org/latest.tar.gz | tar zxv
mv wordpress html

echo "Create a WordPress service."
docker compose up -d
mypassword=$(grep MYSQL_ROOT_PASSWORD docker-compose.yml|awk -F\= '{print $2}')
docker exec web sh -c "chown -R www-data:www-data /var/www/html"
docker exec db sh -c "mariadb -p$mypassword -e 'create database wordpress;'" >/dev/null 2>&1
while [ $? -ne 0 ]; do
  echo "Initialize DB... (This might take a minute)"
  sleep 20
  docker exec db sh -c "mariadb -p$mypassword -e 'create database if not exists wordpress;'" >/dev/null 2>&1
done
echo "done..."

echo "====================="
echo "WordPress site: $(hostname -I|awk '{print "http://"$1":8888"}')"
echo "[Database info]"
echo "db:   wordpress"
echo "host: db"
echo "user: root"
echo "pass: $mypassword"
echo "====================="

echo "Remove install.sh script."
#rm -f ./install.sh
