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

## Database credentials live in .env (git-ignored), never in docker-compose.yml.
if [ ! -f .env ]; then
  echo "Create .env with random database passwords..."
  root_pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
  app_pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
  (umask 077 && sed \
    -e "s/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=$root_pw/" \
    -e "s/^MARIADB_PASSWORD=.*/MARIADB_PASSWORD=$app_pw/" \
    .env.example > .env)
fi
if grep -q '=change-me$' .env; then
  echo ".env still contains 'change-me' placeholders; set real passwords first."
  exit 1
fi
db_name=$(grep '^MARIADB_DATABASE=' .env | cut -d= -f2-)
db_user=$(grep '^MARIADB_USER=' .env | cut -d= -f2-)

echo "Download latest WordPress..."
wget -O - https://wordpress.org/latest.tar.gz | tar zxv
mv wordpress html

echo "Create a WordPress service."
docker compose up -d || exit 1
docker exec web sh -c "chown -R www-data:www-data /var/www/html"

## The mariadb image creates the database and the WordPress user on first start;
## wait until its healthcheck reports the server ready.
tries=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' db 2>/dev/null)" = "healthy" ]; do
  tries=$((tries + 1))
  if [ "$tries" -gt 60 ]; then
    echo "Database did not become healthy; check: docker compose logs db"
    exit 1
  fi
  echo "Initialize DB... (This might take a minute)"
  sleep 5
done
echo "done..."

echo "====================="
echo "WordPress site: $(hostname -I|awk '{print "http://"$1":8888"}')"
echo "[Database info for the WordPress installer]"
echo "db:   ${db_name:-wordpress}"
echo "host: db"
echo "user: ${db_user:-wordpress}"
echo "pass: value of MARIADB_PASSWORD in .env"
echo "====================="

echo "Remove install.sh script."
#rm -f ./install.sh
