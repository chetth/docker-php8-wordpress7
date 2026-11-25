#!/bin/sh
# Container entrypoint: runs php-fpm and nginx (OpenResty) side by side.
#
# - Both run in the foreground as children of this script.
# - If either one exits, the other is stopped and the container exits non-zero,
#   so Docker's restart policy restarts the whole container instead of leaving
#   it half-alive.
# - SIGTERM / SIGINT / SIGQUIT (e.g. `docker stop`) shut both down gracefully:
#   SIGQUIT lets nginx and php-fpm finish in-flight requests.
set -u

FPM_SOCKET=/run/php-fpm/www.sock

# Refuse to start on a broken configuration.
php-fpm --test || exit 1
nginx -t -q || exit 1

php-fpm --nodaemonize &
FPM_PID=$!

# Start nginx only once PHP-FPM accepts connections, to avoid early 502s.
i=0
while [ ! -S "$FPM_SOCKET" ]; do
  i=$((i + 1))
  if [ "$i" -gt 50 ] || ! kill -0 "$FPM_PID" 2>/dev/null; then
    echo "start.sh: php-fpm did not create $FPM_SOCKET" >&2
    kill -TERM "$FPM_PID" 2>/dev/null
    exit 1
  fi
  sleep 0.2
done

nginx &
NGINX_PID=$!

shutdown() {
  kill -QUIT "$NGINX_PID" 2>/dev/null
  kill -QUIT "$FPM_PID" 2>/dev/null
  wait "$NGINX_PID" 2>/dev/null
  wait "$FPM_PID" 2>/dev/null
}

trap 'shutdown; exit 0' TERM INT QUIT

while kill -0 "$FPM_PID" 2>/dev/null && kill -0 "$NGINX_PID" 2>/dev/null; do
  # Backgrounded sleep + wait keeps the loop interruptible by signals.
  sleep 2 &
  wait $!
done

echo "start.sh: nginx or php-fpm exited unexpectedly; stopping container" >&2
shutdown
exit 1
