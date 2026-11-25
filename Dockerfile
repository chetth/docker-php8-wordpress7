# Exact versions are pinned so every image can be checked against CVE advisories.
# A floating tag (e.g. 8.4-fpm-alpine3.22) silently stops receiving patches once
# upstream drops that Alpine release. To upgrade: bump these, then
# `docker compose build --pull`.
#
# 8.5.13 (2026-11-19) carries the same November 2026 security fixes as 8.6.0.
# 8.6 is not used yet: the latest releases of imagick (3.8.1), redis (6.3.0)
# and memcached (3.4.0) do not compile against it, and the php:8.6 images no
# longer ship `pecl` (use PIE: https://github.com/php/pie). Move to 8.6 once
# those extensions publish compatible releases.
ARG PHP_VERSION=8.5.13
ARG ALPINE_VERSION=3.24
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION}

#### PHP extensions ##############################
RUN apk add --update --no-cache --virtual .ext-deps \
        $PHPIZE_DEPS \
        libjpeg-turbo-dev \
        libwebp-dev \
        libpng-dev \
        freetype-dev \
        openssl-dev pcre2-dev pcre2-tools pcre2 \
        libmemcached zlib cyrus-sasl libmemcached-dev zlib-dev cyrus-sasl-dev \
        libzip-dev imagemagick-dev \
        libjpeg-turbo-dev libjpeg libjpeg-turbo \
        icu-dev \
        oniguruma-dev \
        linux-headers

# PHP >= 8.5 compiles OPcache into the core, so it is no longer installed here.
# WordPress needs mbstring for multibyte (e.g. Thai) text. It is built into the
# 8.5 images; the php:8.6 images dropped it, so build it only when missing.
RUN \
    docker-php-ext-configure pdo_mysql && \
    docker-php-ext-configure exif && \
    docker-php-ext-configure zip && \
    docker-php-ext-configure gd --with-freetype --with-jpeg && \
    docker-php-ext-configure sockets && \
    docker-php-ext-configure intl && \
    docker-php-ext-install pdo_mysql exif gd sockets mysqli calendar intl zip && \
    { php -m | grep -qx mbstring || docker-php-ext-install mbstring; }

# Pinned for reproducible builds; bump deliberately.
RUN \
    pecl install redis-6.3.0 && \
    pecl install mongodb-2.5.8 && \
    pecl install memcached-3.4.0 && \
    pecl install imagick-3.8.1 && \
    pecl clear-cache && \
    docker-php-ext-enable redis.so && \
    docker-php-ext-enable mongodb.so && \
    docker-php-ext-enable memcached.so && \
    docker-php-ext-enable imagick.so && \
    docker-php-ext-enable intl && \
    docker-php-source delete

####  Setup OpenResty ###################
# 1.31.9.1 (2026-11-23) bundles nginx 1.31.9, which fixes CVE-2026-123007,
# CVE-2026-123633, CVE-2026-121810 and the other nginx 1.31.9 advisories.
# SHA256 taken from a tarball whose PGP signature was verified against
# OpenResty's release key (A0E98066, Yichun Zhang).
ENV OPENRESTY_VERSION=1.31.9.1
ENV OPENRESTY_SHA256=71d49935bdc186dafc1f4b0a8ba44dba1bf4abc8ca52d4621f2039ec8fdcc95f
ENV OPENRESTY_PREFIX=/opt/openresty
ENV NGINX_PREFIX=/opt/openresty/nginx
ENV NGINX_CONF=/opt/openresty/nginx/conf
ENV VAR_PREFIX=/opt/openresty/nginx/var
ENV VAR_LOG_PREFIX=/opt/openresty/nginx/logs

# NginX prefix is automatically set by OpenResty to $OPENRESTY_PREFIX/nginx
# look for $ngx_prefix in https://github.com/openresty/ngx_openresty/blob/master/util/configure

# Timezone
ENV TIMEZONE=Asia/Bangkok
RUN echo "Install Timezone ===========>>" \
 && apk add --update tzdata \
 && cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime \
 && echo "${TIMEZONE}" > /etc/timezone

RUN echo "==> Installing dependencies..." \
 && apk update \
 && apk add --virtual build-deps \
    make gcc musl-dev \
    pcre2-dev openssl-dev zlib-dev ncurses-dev readline-dev \
    curl perl wget \
 && mkdir -p /root/ngx_openresty \
 && cd /root/ngx_openresty \
 && echo "==> Downloading OpenResty..." \
 && curl -fsSL -o openresty.tar.gz https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz \
 && echo "${OPENRESTY_SHA256}  openresty.tar.gz" | sha256sum -c - \
 && tar -xzf openresty.tar.gz \
 && cd openresty-${OPENRESTY_VERSION} \
 && echo "==> Configuring OpenResty..." \
 && NPROC=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1) \
 && echo "using upto $NPROC threads" \
 && ./configure \
    --prefix=$OPENRESTY_PREFIX \
    --http-client-body-temp-path=$VAR_PREFIX/client_body_temp \
    --http-proxy-temp-path=$VAR_PREFIX/proxy_temp \
    --http-log-path=$VAR_LOG_PREFIX/access.log \
    --error-log-path=$VAR_LOG_PREFIX/error.log \
    --pid-path=$VAR_PREFIX/nginx.pid \
    --lock-path=$VAR_PREFIX/nginx.lock \
    --with-luajit \
    --with-pcre-jit \
    --with-ipv6 \
    --with-http_stub_status_module \
    --with-http_realip_module \
    --with-http_ssl_module \
    --with-http_flv_module \
    --with-http_v2_module \
    --with-http_mp4_module \
    --with-http_sub_module \
    --with-http_stub_status_module \
    --without-http_ssi_module \
    --without-http_uwsgi_module \
    --without-http_scgi_module \
    -j${NPROC} \
 && echo "==> Building OpenResty..." \
 && make -j${NPROC} \
 && echo "==> Installing OpenResty..." \
 && make install \
 && echo "==> Finishing..." \
 && ln -sf $NGINX_PREFIX/sbin/nginx /usr/local/bin/nginx \
 && ln -sf $NGINX_PREFIX/sbin/nginx /usr/local/bin/openresty \
 && ln -sf $OPENRESTY_PREFIX/bin/resty /usr/local/bin/resty \
 && ln -sf $OPENRESTY_PREFIX/luajit/bin/luajit-* $OPENRESTY_PREFIX/luajit/bin/lua \
 && ln -sf $OPENRESTY_PREFIX/luajit/bin/luajit-* /usr/local/bin/lua \
 && apk del build-deps tzdata \
 && apk update && apk upgrade \
 && apk add pcre2 openssl libcrypto3 libssl3 libgcc libstdc++ libuuid curl imagemagick ghostscript \
 && rm -rf /var/cache/apk/* \
 && rm -rf /root/ngx_openresty \
 && rm -f $NGINX_PREFIX/conf/*.default \
 && mkdir -p /var/log/nginx \
 && cd /var/tmp && wget -qO composer-setup.php https://getcomposer.org/installer \
 && php composer-setup.php --filename=composer && chmod +x composer \
 && mv -v composer /usr/local/bin/composer && rm -f composer-setup.php

WORKDIR $NGINX_CONF

ONBUILD RUN rm -rf conf/* html/*
ONBUILD COPY nginx $NGINX_PREFIX/

RUN echo '<?php if(isset($_REQUEST["printinfo"])) phpinfo();' > /var/www/html/index.php \
 && echo '?><a href=/?printinfo>see phpinfo()</a>' >> /var/www/html/index.php

#### PHP / PHP-FPM configuration ################
# PHP-FPM pool sizing, read by www.conf. Defaults suit a host with ~2-4 GB RAM
# for PHP; override per host in docker-compose.yml (see www.conf for sizing).
ENV PHP_FPM_PM=dynamic \
    PHP_FPM_MAX_CHILDREN=20 \
    PHP_FPM_START_SERVERS=4 \
    PHP_FPM_MIN_SPARE_SERVERS=2 \
    PHP_FPM_MAX_SPARE_SERVERS=6 \
    PHP_FPM_MAX_REQUESTS=500

RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
 && mkdir -p /run/php-fpm
COPY ./php-production.ini $PHP_INI_DIR/conf.d/zz-production.ini
COPY ./www.conf /usr/local/etc/php-fpm.d/www.conf

ADD  ./start.sh /start.sh
COPY ./nginx.conf ${NGINX_CONF}/nginx.conf
RUN chmod +x /start.sh

EXPOSE 80

# Exercises nginx -> FastCGI -> PHP-FPM end to end.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1/fpm-ping || exit 1

ENTRYPOINT ["/start.sh"]
