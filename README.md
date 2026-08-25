# docker-php8-wordpress7

A single-container PHP-FPM 8.4 + OpenResty (NGINX + LuaJIT) runtime image, packaged with a
Docker Compose stack that provisions a working WordPress site and a MariaDB database in one command.

The image is built for CMS/PHP application workloads: it ships a broad set of compiled PHP
extensions (image processing, caching clients, database drivers, internationalisation) and an
OpenResty build compiled from source with HTTP/2, SSL, cache-purge and stub-status modules.

---

## Table of Contents

- [Architecture](#architecture)
- [What Is Inside the Image](#what-is-inside-the-image)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Manual Setup](#manual-setup)
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
                  │        │ fastcgi_pass 127.0.0.1:9000     │
                  │        ▼                                 │
                  │  PHP-FPM 8.4                             │
                  │        │                                 │
                  │  /var/www/html  ◄── bind mount ./html    │
                  └──────────┬───────────────────────────────┘
                             │ Docker network (internal only)
                  ┌──────────▼───────────────────────────────┐
                  │ container: db   (mariadb:latest)         │
                  │  volume wordpress_db → /var/lib/mysql    │
                  └──────────────────────────────────────────┘
```

Both NGINX and PHP-FPM run inside the **same** container, started by [start.sh](start.sh).
NGINX is daemonised (`daemon on;` in [nginx.conf](nginx.conf)) and PHP-FPM runs in the
foreground as PID 1.

WordPress source files live on the host in `./html` and are bind-mounted into the container,
so plugin/theme installs and uploads survive container rebuilds. Database data lives in the
named Docker volume `wordpress_db`.

---

## What Is Inside the Image

**Base:** `php:8.4-fpm-alpine3.22`

| Layer | Details |
| --- | --- |
| PHP extensions (bundled) | `pdo_mysql`, `mysqli`, `opcache`, `exif`, `gd` (freetype + jpeg), `sockets`, `calendar`, `intl`, `zip` |
| PHP extensions (PECL) | `redis`, `mongodb`, `memcached`, `imagick` |
| Web server | OpenResty `1.31.1.1`, built from source |
| NGINX modules | `http_ssl`, `http_v2`, `http_flv`, `http_mp4`, `http_sub`, `http_stub_status`, `ngx_cache_purge` 2.3, LuaJIT, PCRE JIT |
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
2. Downloads the latest WordPress tarball and extracts it to `./html`.
3. Runs `docker compose up -d` (builds the `web` image on first run).
4. Fixes ownership: `chown -R www-data:www-data /var/www/html`.
5. Polls MariaDB until it accepts connections, then creates the `wordpress` database.
6. Prints the site URL and database credentials.

Then open `http://<host>:8888` and complete the WordPress installer using:

| Field | Value |
| --- | --- |
| Database Name | `wordpress` |
| Username | `root` |
| Password | value of `MYSQL_ROOT_PASSWORD` in [docker-compose.yml](docker-compose.yml) |
| Database Host | `db` |
| Table Prefix | your choice |

> **Change `MYSQL_ROOT_PASSWORD` in [docker-compose.yml](docker-compose.yml) before running
> `install.sh`.** The committed default (`AnythingYouDLike`) is a placeholder, not a credential.

---

## Manual Setup

If you prefer not to run the installer script:

```bash
# 1. Set a strong DB password
$EDITOR docker-compose.yml

# 2. Provide the application source
curl -fsSL https://wordpress.org/latest.tar.gz | tar zx
mv wordpress html

# 3. Build and start
docker compose up -d --build

# 4. Fix file ownership for PHP-FPM (runs as www-data)
docker exec web chown -R www-data:www-data /var/www/html

# 5. Create the application database
docker exec db mariadb -p'<your-password>' -e 'CREATE DATABASE IF NOT EXISTS wordpress;'
```

To run an arbitrary PHP application instead of WordPress, place it in `./html` — the document
root is `/var/www/html` and the index order is `index.php index.html`.

---

## Configuration Reference

### Ports

| Service | Container | Host |
| --- | --- | --- |
| `web` | 80 | 8888 |
| `db` | 3306 | *not published* — reachable only on the Compose network as `db` |

Change the host port in [docker-compose.yml](docker-compose.yml) (`ports: - "8888:80"`).

### PHP runtime limits

Set per-request via `fastcgi_param PHP_VALUE` in [nginx.conf](nginx.conf#L74):

| Directive | Value |
| --- | --- |
| `upload_max_filesize` | 512M |
| `post_max_size` | 512M |
| `memory_limit` | 512M |
| `date.timezone` | `Asia/Bangkok` |

### NGINX behaviour

| Setting | Value | Note |
| --- | --- | --- |
| `worker_processes` | `auto` | one worker per CPU |
| `worker_connections` | 200000 | requires a matching host/container file-descriptor limit |
| `client_max_body_size` | `0` | uploads are unlimited at the NGINX layer; PHP still caps at 512M |
| `access_log` | `off` | error log only, at `/opt/openresty/nginx/logs/error.log` |
| `gzip` | on | text, JS, CSS, fonts, common image types |
| Timeouts | 360s client/keepalive, 180s FastCGI read/send | tuned for long-running admin requests |
| Headers | `Server` and `X-Powered-By` cleared | via `headers_more` |

Permalinks work out of the box: `try_files $uri $uri/ /index.php$is_args$args;`.

### PHP-FPM pool

The image uses the upstream `php:8.4-fpm` default pool. The [www.conf](www.conf) in this
repository is a **reference file only — it is not copied into the image**. To apply it, add to
the Dockerfile:

```dockerfile
COPY ./www.conf /usr/local/etc/php-fpm.d/www.conf
```

Its non-default settings are: `user/group = www-data`, `listen = 127.0.0.1:9000`,
`pm = dynamic`, `pm.max_children = 50`, `pm.start_servers = 2`,
`pm.min_spare_servers = 1`, `pm.max_spare_servers = 3`.

### Image environment variables

These are `ENV` values in [Dockerfile](Dockerfile); change them there and rebuild.

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENRESTY_VERSION` | `1.31.1.1` | OpenResty release to compile |
| `OPENRESTY_PREFIX` | `/opt/openresty` | install prefix |
| `NGINX_CONF` | `/opt/openresty/nginx/conf` | where `nginx.conf` is copied |
| `TIMEZONE` | `Asia/Bangkok` | container timezone and `date.timezone` default |

---

## Repository Layout

| Path | Purpose |
| --- | --- |
| [Dockerfile](Dockerfile) | Builds the PHP-FPM 8.4 + OpenResty image |
| [docker-compose.yml](docker-compose.yml) | Two-service stack: `web` + `db` (MariaDB) |
| [nginx.conf](nginx.conf) | OpenResty configuration, installed into the image |
| [start.sh](start.sh) | Container entrypoint — starts NGINX then PHP-FPM |
| [install.sh](install.sh) | One-shot WordPress provisioning script |
| [www.conf](www.conf) | Reference PHP-FPM pool config (**not used by the build**) |
| `composer-setup.php` | Vendored Composer installer (**not used** — the build downloads a fresh copy) |
| `html/` | Application document root, git-ignored, created by `install.sh` |

---

## Operations

```bash
# Status and logs
docker compose ps
docker compose logs -f web
docker exec web tail -f /opt/openresty/nginx/logs/error.log

# Reload NGINX after editing nginx.conf inside the container
docker exec web nginx -t && docker exec web nginx -s reload

# Shell access
docker exec -it web sh
docker exec -it db sh

# Composer inside the app root
docker exec -w /var/www/html web composer install

# Database backup / restore
docker exec db mariadb-dump -p'<pw>' wordpress > backup.sql
docker exec -i db mariadb -p'<pw>' wordpress < backup.sql

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
| Hardcoded `MYSQL_ROOT_PASSWORD` in [docker-compose.yml](docker-compose.yml) | Credential is in version control | Move to a `.env` file or Docker secret; generate a strong value |
| WordPress connects to MariaDB as `root` | No privilege separation; a WordPress compromise means full DB control | Create a dedicated user scoped to the `wordpress` database |
| No TLS | Traffic and wp-admin credentials in cleartext | Terminate TLS on a reverse proxy in front, or enable `http_ssl` (already compiled in) with certificates |
| `client_max_body_size 0` | Unbounded request bodies; DoS vector | Set an explicit limit, e.g. `512m` |
| `access_log off` | No request-level audit trail or traffic forensics | Enable access logging and ship to a log collector |
| `mariadb:latest` | Non-reproducible builds; unplanned major-version upgrades | Pin an explicit tag, e.g. `mariadb:11.4` |
| Default `index.php` exposes `phpinfo()` via `?printinfo` | Leaks paths, extensions, and configuration | Present only when `html/` is empty; ensure the document root is always populated |
| Containers run `restart: always` with no healthchecks | Failures may go unnoticed | Add Compose `healthcheck` blocks for both services |
| Two processes in one container | No per-process supervision or restart | Acceptable for single-node use; split for orchestrated environments |

---

## Known Limitations

- **`install.sh` is Linux-only.** It calls `hostname -I`, which does not exist on macOS/BSD;
  the script still provisions the stack, but the final URL line will be empty. Browse to
  `http://localhost:8888` instead.
- **First build is slow.** OpenResty is compiled from source; expect several minutes and
  significant CPU load. Subsequent builds reuse the Docker layer cache.
- **Repository name is historical.** It reads `php8-wordpress7`, but the image ships
  **PHP 8.4** and `install.sh` installs the **latest** WordPress release, not WordPress 7.
- **No `wp-config.php` automation.** The WordPress web installer must be completed manually;
  the script only creates the empty database.
- **PHP-FPM is PID 1, NGINX is not supervised.** If NGINX exits, the container stays up and
  serves nothing until manually restarted.
- **`composer-setup.php` is committed but unused.** The build fetches the installer from
  `getcomposer.org` at build time. The vendored copy can be deleted.

---

## License

[GNU General Public License v3.0](LICENSE)
