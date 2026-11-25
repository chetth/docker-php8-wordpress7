# docker-php8-wordpress7

A single-container PHP-FPM 8.5 + OpenResty (NGINX + LuaJIT) runtime image, packaged with a
Docker Compose stack that provisions a working WordPress site and a MariaDB database in one command.

The image is built for CMS/PHP application workloads: it ships a broad set of compiled PHP
extensions (image processing, caching clients, database drivers, internationalisation) and an
OpenResty build compiled from source with HTTP/2, SSL, real-IP and stub-status modules.

---

## Table of Contents

- [Architecture](#architecture)
- [What Is Inside the Image](#what-is-inside-the-image)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Manual Setup](#manual-setup)
- [Database Credentials](#database-credentials)
- [Configuration Reference](#configuration-reference)
- [Repository Layout](#repository-layout)
- [Operations](#operations)
- [Using the Image as a Base Image](#using-the-image-as-a-base-image)
- [Security Considerations](#security-considerations)
- [Known Limitations](#known-limitations)
- [License](#license)

---

## Architecture

```
                        host :8888
                             │
                  ┌──────────▼───────────────────────────────┐
                  │ container: web  (built from ./Dockerfile)│
                  │                                          │
                  │  OpenResty / NGINX  :80                  │
                  │        │ unix:/run/php-fpm/www.sock      │
                  │        ▼                                 │
                  │  PHP-FPM 8.5                             │
                  │        │                                 │
                  │  /var/www/html  ◄── bind mount ./html    │
                  └──────────┬───────────────────────────────┘
                             │ Docker network (internal only)
                  ┌──────────▼───────────────────────────────┐
                  │ container: db   (mariadb:11.4)           │
                  │  volume wordpress_db → /var/lib/mysql    │
                  └──────────────────────────────────────────┘
```

Both NGINX and PHP-FPM run inside the **same** container. [start.sh](start.sh) starts both in
the foreground and supervises them: if either one exits, the container exits non-zero so the
`restart: always` policy brings it back, and `docker stop` shuts both down gracefully
(SIGQUIT, in-flight requests finish). Compose runs it under `init: true` (tini) as PID 1.

WordPress source files live on the host in `./html` and are bind-mounted into the container,
so plugin/theme installs and uploads survive container rebuilds. Database data lives in the
named Docker volume `wordpress_db`.

---

## What Is Inside the Image

**Base:** `php:8.5.13-fpm-alpine3.24` (exact version pinned via `ARG PHP_VERSION` / `ARG ALPINE_VERSION`)

| Layer | Details |
| --- | --- |
| PHP extensions (bundled) | `pdo_mysql`, `mysqli`, `exif`, `gd` (freetype + jpeg), `sockets`, `calendar`, `intl`, `zip`, `mbstring`; OPcache is part of the PHP core since 8.5 |
| PHP extensions (PECL, pinned) | `redis` 6.3.0, `mongodb` 2.5.8, `memcached` 3.4.0, `imagick` 3.8.1 |
| Web server | OpenResty `1.31.9.1` (nginx 1.31.9), built from source; tarball verified by SHA256 |
| NGINX modules | `http_ssl`, `http_v2`, `http_realip`, `http_flv`, `http_mp4`, `http_sub`, `http_stub_status`, LuaJIT, PCRE JIT, plus the modules bundled with OpenResty (no third-party modules) |
| NGINX modules removed | `http_ssi`, `http_uwsgi`, `http_scgi` |
| Tooling | Composer (global, `/usr/local/bin/composer`), `resty`, `lua`, ImageMagick, Ghostscript, curl |
| Timezone | `Asia/Bangkok` (set by the `TIMEZONE` `ENV` in the Dockerfile) |

Convenience symlinks are created for `nginx`, `openresty`, `resty` and `lua` in `/usr/local/bin`.

---

## Requirements

| Component | Minimum |
| --- | --- |
| Docker Engine | with Compose V2 (`docker compose`, not `docker-compose`) |
| Host OS | Linux recommended — `install.sh` uses `hostname -I`, which is GNU-specific (see [Known Limitations](#known-limitations)) |
| Tools | `wget`, `tar` |
| Build resources | The OpenResty compile step is CPU-intensive; expect several minutes on first build |

---

## Quick Start

```bash
git clone https://github.com/chetth/docker-php8-wordpress7.git
cd docker-php8-wordpress7
./install.sh
```

[install.sh](install.sh) performs the following steps:

1. Verifies Docker and Compose V2 are present.
2. Creates `.env` from [.env.example](.env.example) with two random 32-character database
   passwords, unless `.env` already exists (see [Database Credentials](#database-credentials)).
3. Downloads the latest WordPress tarball and extracts it to `./html`.
4. Runs `docker compose up -d` (builds the `web` image on first run). On first start MariaDB
   creates the `wordpress` database and a `wordpress` user that can access only that database.
5. Fixes ownership: `chown -R www-data:www-data /var/www/html`.
6. Waits until the `db` healthcheck reports healthy.
7. Prints the site URL and the database settings for the WordPress installer.

Then open `http://<host>:8888` and complete the WordPress installer using:

| Field | Value |
| --- | --- |
| Database Name | `wordpress` (`MARIADB_DATABASE`) |
| Username | `wordpress` (`MARIADB_USER`) — not `root` |
| Password | value of `MARIADB_PASSWORD` in `.env` |
| Database Host | `db` |
| Table Prefix | your choice |

---

## Manual Setup

If you prefer not to run the installer script:

```bash
# 1. Create .env and replace both "change-me" passwords
cp .env.example .env && chmod 600 .env
$EDITOR .env

# 2. Provide the application source
curl -fsSL https://wordpress.org/latest.tar.gz | tar zx
mv wordpress html

# 3. Build and start (MariaDB creates the database and WordPress user on first start)
docker compose up -d --build

# 4. Fix file ownership for PHP-FPM (runs as www-data)
docker exec web chown -R www-data:www-data /var/www/html
```

To run an arbitrary PHP application instead of WordPress, place it in `./html` — the document
root is `/var/www/html` and the index order is `index.php index.html`.

---

## Database Credentials

Passwords are never stored in [docker-compose.yml](docker-compose.yml) or in git. Compose reads
them from a `.env` file next to `docker-compose.yml`. `.env` is listed in `.gitignore` and
`.dockerignore`; [.env.example](.env.example) is the committed template.

| Variable | Default | Purpose |
| --- | --- | --- |
| `MARIADB_ROOT_PASSWORD` | *(required)* | MariaDB `root` account. Administration only — never put it in `wp-config.php` |
| `MARIADB_DATABASE` | `wordpress` | Database created on first start |
| `MARIADB_USER` | `wordpress` | Account WordPress connects with; privileges on `MARIADB_DATABASE` only |
| `MARIADB_PASSWORD` | *(required)* | Password for `MARIADB_USER`; the same value goes into `wp-config.php` as `DB_PASSWORD` |

`docker compose` refuses to start when either password is unset or empty.

### Creating `.env`

`install.sh` creates `.env` automatically, with two random 32-character passwords, when the
file does not exist. It also refuses to continue while any value is still `change-me`.

To create it by hand:

```bash
cp .env.example .env
chmod 600 .env
# Generate a password; run once per password and paste into .env
LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; echo
```

Avoid `$`, quotes and spaces in the values: Compose expands `$` inside `.env`.

Store a copy of `.env` in your password manager or secret store. It is not in git, and the
database volume cannot be administered without the root password.

### Passwords take effect only once

MariaDB reads these variables **only when the `wordpress_db` volume is empty**, i.e. on the very
first start. On an existing volume, editing `.env` does not change any password in the
database. It only changes what the container *thinks* the password is, so the backup commands
under [Operations](#operations) start failing.

To change a password, change it in the database first, then in `.env`:

```bash
# Open a root shell; the password is read inside the container, never typed on the host
docker exec -it db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot'
```

```sql
-- WordPress user: also update DB_PASSWORD in html/wp-config.php
ALTER USER 'wordpress'@'%' IDENTIFIED BY '<new-password>';

-- root exists for both hosts; change both
ALTER USER 'root'@'localhost' IDENTIFIED BY '<new-root-password>';
ALTER USER 'root'@'%'         IDENTIFIED BY '<new-root-password>';
```

Then update `MARIADB_PASSWORD` / `MARIADB_ROOT_PASSWORD` in `.env` and run
`docker compose up -d db` so the container picks up the new values. The volume is kept.

### Upgrading an installation that used the old `docker-compose.yml`

Earlier versions of this repository committed the root password in `docker-compose.yml`, and
WordPress connected as `root`. That password is in the git history, so treat it as public and
rotate it:

1. Create `.env`. Set `MARIADB_ROOT_PASSWORD` to the password the existing volume **currently**
   uses, and set a new random `MARIADB_PASSWORD`.
2. Run `docker compose up -d`. If `db` shows `unhealthy` because the volume predates the
   image's healthcheck user, add `MARIADB_AUTO_UPGRADE=1` to the `db` environment for one start.
3. Create the WordPress user. It is created automatically only on an empty volume:

   ```sql
   CREATE USER 'wordpress'@'%' IDENTIFIED BY '<MARIADB_PASSWORD from .env>';
   GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'%';
   ```

4. In `html/wp-config.php`, set `DB_USER` to `wordpress` and `DB_PASSWORD` to the new password.
   Check that the site still loads.
5. Rotate the root password, as shown in [Passwords take effect only once](#passwords-take-effect-only-once).

### Who can read the passwords

Anyone who can run `docker` commands on the host can read them, for example through
`docker inspect db`. Docker access is equivalent to root on the host anyway, so restrict it. For
stricter setups the mariadb image also accepts `MARIADB_ROOT_PASSWORD_FILE` and
`MARIADB_PASSWORD_FILE`, which work with Docker secrets.

---

## Configuration Reference

### Ports

| Service | Container | Host |
| --- | --- | --- |
| `web` | 80 | 8888 |
| `db` | 3306 | *not published* — reachable only on the Compose network as `db` |

Change the host port in [docker-compose.yml](docker-compose.yml) (`ports: - "8888:80"`).

### PHP runtime settings

The image starts from `php.ini-production` and applies [php-production.ini](php-production.ini)
on top (installed as `conf.d/zz-production.ini`):

| Directive | Value |
| --- | --- |
| `upload_max_filesize` / `post_max_size` | 512M (keep in sync with `client_max_body_size`) |
| `memory_limit` | 512M |
| `max_execution_time` / `max_input_time` | 300 |
| `max_input_vars` | 3000 |
| `display_errors` / `expose_php` | Off |
| `cgi.fix_pathinfo` | 0 |
| `session.upload_progress.enabled` | 0 (mitigation advised by php.net for the 2026 session CVEs) |
| OPcache | 256 MB, 20000 files, timestamps validated every 2 s (WordPress updates in place) |
| `date.timezone` | `Asia/Bangkok` |

### NGINX behaviour

| Setting | Value | Note |
| --- | --- | --- |
| Process model | `daemon off`, `user www-data` | supervised by `start.sh` |
| `worker_connections` / `worker_rlimit_nofile` | 16384 / 65535 | Compose sets `ulimits.nofile` to match |
| `client_max_body_size` | `512m` | matches PHP upload limits |
| Header buffers | 4k, large 4 × 32k | the former 1 MB buffers allowed memory-exhaustion DoS |
| Timeouts | client header 15s, body/send 60s, keepalive 65s, FastCGI 300s | |
| Logs | JSON access log → stdout, error log (`warn`) → stderr | read with `docker logs` |
| `gzip` | on | text, JS, CSS, JSON, XML, SVG, fonts |
| Static assets | `expires 30d`, no access log | falls back to WordPress for generated assets |
| Headers | `Server` / `X-Powered-By` removed; `nosniff`, `SAMEORIGIN`, `Referrer-Policy`, `Permissions-Policy` added | HSTS is commented out until the site is HTTPS-only |
| Rate limits | `wp-login.php` 30 r/min (burst 20), `xmlrpc.php` 60 r/min (burst 30), per IP → 429 | |
| Denied | dotfiles, `wp-config.php`, `readme.html`, `license.txt`, backups/dumps/logs, PHP under `wp-content/uploads` | |
| Health | `/fpm-ping`, `/fpm-status`, `/nginx-status` | 127.0.0.1 only; the image `HEALTHCHECK` uses `/fpm-ping` |

Permalinks work out of the box: `try_files $uri $uri/ /index.php$is_args$args;`.

**Behind a load balancer or CDN**, uncomment the `set_real_ip_from` block in
[nginx.conf](nginx.conf) with the proxy's address range. Otherwise logs show the proxy's IP and
all visitors share one login rate-limit bucket.

FastCGI connection reuse (`fastcgi_keep_conn` / upstream `keepalive`) is intentionally left off:
it is the precondition for PHP-FPM request smuggling CVE-2026-129289.

### PHP-FPM pool

[www.conf](www.conf) is copied into the image as `/usr/local/etc/php-fpm.d/www.conf`:

- Listens on the unix socket `/run/php-fpm/www.sock` (mode 0660). The php image default,
  `listen = 9000`, exposed FastCGI to every container on the Compose network.
- `clear_env = yes`: container environment variables are not visible to PHP; whitelist with
  `env[NAME] = $NAME`.
- `request_terminate_timeout = 300s`, `pm.max_requests = 500`, `security.limit_extensions = .php`.
- Process-manager sizes come from environment variables, so each host can be tuned in
  [docker-compose.yml](docker-compose.yml) without a rebuild. Size `PHP_FPM_MAX_CHILDREN` as
  (RAM available to PHP) ÷ (average worker RSS, typically 60–120 MB for WordPress).

### Image build arguments and environment variables

| Name | Kind | Default | Purpose |
| --- | --- | --- | --- |
| `PHP_VERSION` / `ALPINE_VERSION` | `ARG` | `8.5.13` / `3.24` | base image `php:<PHP_VERSION>-fpm-alpine<ALPINE_VERSION>` |
| `OPENRESTY_VERSION` / `OPENRESTY_SHA256` | `ENV` | `1.31.9.1` / pinned | OpenResty release to compile and its checksum |
| `OPENRESTY_PREFIX` | `ENV` | `/opt/openresty` | install prefix |
| `NGINX_CONF` | `ENV` | `/opt/openresty/nginx/conf` | where `nginx.conf` is copied |
| `TIMEZONE` | `ENV` | `Asia/Bangkok` | container timezone |
| `PHP_FPM_PM` | `ENV` | `dynamic` | `pm` mode |
| `PHP_FPM_MAX_CHILDREN` | `ENV` | `20` | `pm.max_children` |
| `PHP_FPM_START_SERVERS` / `PHP_FPM_MIN_SPARE_SERVERS` / `PHP_FPM_MAX_SPARE_SERVERS` | `ENV` | `4` / `2` / `6` | dynamic pool sizing |
| `PHP_FPM_MAX_REQUESTS` | `ENV` | `500` | worker recycling |

`PHP_FPM_*` can be overridden at runtime (`environment:` in Compose); the others need a rebuild.

### Upgrading PHP and OpenResty

Bump the pinned versions in the [Dockerfile](Dockerfile) (for OpenResty, also its SHA256) and
run `docker compose build --pull`. PHP 8.6 is not used yet: the current releases of imagick
(3.8.1), redis (6.3.0) and memcached (3.4.0) fail to compile against it, and the php:8.6 images no
longer include `pecl` (extensions are installed with [PIE](https://github.com/php/pie) there).

---

## Repository Layout

| Path | Purpose |
| --- | --- |
| [Dockerfile](Dockerfile) | Builds the PHP-FPM 8.5 + OpenResty image |
| [docker-compose.yml](docker-compose.yml) | Two-service stack: `web` + `db` (MariaDB) |
| [.env.example](.env.example) | Template for `.env`, which holds the database credentials (git-ignored) |
| [.dockerignore](.dockerignore) | Keeps `.env`, `html/` and `.git` out of the build context |
| [nginx.conf](nginx.conf) | OpenResty configuration, installed into the image |
| [www.conf](www.conf) | PHP-FPM pool configuration, installed into the image |
| [php-production.ini](php-production.ini) | PHP ini overrides, installed as `conf.d/zz-production.ini` |
| [start.sh](start.sh) | Container entrypoint — starts and supervises PHP-FPM and NGINX |
| [install.sh](install.sh) | One-shot WordPress provisioning script |
| `composer-setup.php` | Vendored Composer installer (**not used** — the build downloads a fresh copy) |
| `html/` | Application document root, git-ignored, created by `install.sh` |

---

## Operations

```bash
# Status, health and logs (NGINX access + error, PHP-FPM, PHP errors)
docker compose ps
docker compose logs -f web
docker exec web curl -s 'http://127.0.0.1/fpm-status?full'
docker exec web curl -s http://127.0.0.1/nginx-status

# Reload NGINX after editing nginx.conf inside the container
docker exec web nginx -t && docker exec web nginx -s reload

# Shell access
docker exec -it web sh
docker exec -it db sh

# Composer inside the app root
docker exec -w /var/www/html web composer install

# Database backup / restore (credentials are read inside the container from .env values)
docker exec db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction "$MARIADB_DATABASE"' > backup.sql
docker exec -i db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot "$MARIADB_DATABASE"' < backup.sql

# Rebuild after changing the Dockerfile or nginx.conf
docker compose up -d --build

# Stop / remove (keeps the DB volume)
docker compose down

# Remove including database data — destructive
docker compose down -v
```

Verify the PHP runtime by browsing to `http://<host>:8888/?printinfo` — but only before the
`html/` bind mount replaces the image's default `index.php`. Once WordPress is installed, that
endpoint no longer exists.

---

## Using the Image as a Base Image

The Dockerfile declares `ONBUILD` instructions, so it can serve as a parent image:

```dockerfile
ONBUILD RUN rm -rf conf/* html/*
ONBUILD COPY nginx $NGINX_PREFIX/
```

A downstream `FROM` of this image will have the OpenResty `conf/` and `html/` directories
cleared and will expect a local `nginx/` directory containing the replacement server tree
(`conf/`, `html/`, …). If you do not intend to use it as a base image, these directives are
inert but should be removed to avoid surprising downstream builds.

---

## Security Considerations

These are properties of the stack as shipped. Address them before any internet-facing deployment.

| Issue | Impact | Recommended action |
| --- | --- | --- |
| Old root password remains in git history | Anyone with the repository can read it | Rotate it on existing installations; see [Database Credentials](#upgrading-an-installation-that-used-the-old-docker-composeyml) |
| No TLS | Traffic and wp-admin credentials in cleartext | Terminate TLS on a reverse proxy in front, or enable `http_ssl` (already compiled in) with certificates; then enable HSTS in [nginx.conf](nginx.conf) |
| Default `index.php` exposes `phpinfo()` via `?printinfo` | Leaks paths, extensions, and configuration | Present only when `html/` is empty; ensure the document root is always populated |
| Build toolchain (`$PHPIZE_DEPS`, `-dev` packages) stays in the final image | Larger image and attack surface | Move extension builds to a multi-stage build |
| Two processes in one container | Supervised by `start.sh`, but restarts are whole-container | Acceptable for single-node use; split for orchestrated environments |

---

## Known Limitations

- **`install.sh` is Linux-only.** It calls `hostname -I`, which does not exist on macOS/BSD;
  the script still provisions the stack, but the final URL line will be empty. Browse to
  `http://localhost:8888` instead.
- **First build is slow.** OpenResty is compiled from source; expect several minutes and
  significant CPU load. Subsequent builds reuse the Docker layer cache.
- **Repository name is historical.** It reads `php8-wordpress7`, but the image ships
  **PHP 8.5** and `install.sh` installs the **latest** WordPress release (7.1.x at the time of
  writing).
- **No `wp-config.php` automation.** The WordPress web installer must be completed manually;
  the stack only provides the empty database and its user.
- **`composer-setup.php` is committed but unused.** The build fetches the installer from
  `getcomposer.org` at build time. The vendored copy can be deleted.

---

## License

[GNU General Public License v3.0](LICENSE)
