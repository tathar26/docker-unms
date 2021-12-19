FROM --platform=linux/amd64 ubnt/unms:1.4.0-beta.12 as unms
FROM --platform=linux/amd64 ubnt/unms-nginx:1.4.0-beta.12 as unms-nginx
FROM --platform=linux/amd64 ubnt/unms-netflow:1.4.0-beta.12 as unms-netflow
FROM --platform=linux/amd64 ubnt/unms-crm:3.4.0-beta.12 as unms-crm
FROM --platform=linux/amd64 ubnt/unms-siridb:1.4.0-beta.12 as unms-siridb
FROM --platform=linux/amd64 ubnt/unms-postgres:1.4.0-beta.12 as unms-postgres
FROM rabbitmq:3.7.14-alpine as rabbitmq

FROM nico640/s6-alpine-node:dev

# base deps postgres 13, certbot
RUN set -x \
    && apk upgrade --no-cache \
    && apk add --no-cache certbot gzip bash vim dumb-init openssl libcap sudo \
       pcre pcre2 yajl gettext coreutils make argon2-libs erlang jq vips tar xz \
       libzip gmp icu c-client supervisor libuv su-exec postgresql postgresql-client \
       postgresql-contrib

# temporarily include postgres 9.6 because it is needed for migration from older versions
WORKDIR /postgres/9.6
RUN cp /etc/apk/repositories /etc/apk/repositories_temp \
    && echo "https://dl-cdn.alpinelinux.org/alpine/v3.6/main" > /etc/apk/repositories \
    && apk fetch --root / --arch ${APK_ARCH} --no-cache -U postgresql postgresql-contrib libressl2.5-libcrypto libressl2.5-libssl -o /postgres \
    && mv /etc/apk/repositories_temp /etc/apk/repositories

# start unms #
WORKDIR /home/app/unms

# copy unms app from offical image since the source code is not published at this time
COPY --from=unms /home/app/unms /home/app/unms

ENV LIBVIPS_VERSION=8.11.3

RUN apk add --no-cache --virtual .build-deps python3 g++ vips-dev glib-dev \
    && ln -s /usr/bin/python3 /usr/bin/python \
    && mkdir -p /tmp/src /home/app/unms/tmp && cd /tmp/src \
    && wget -q https://github.com/libvips/libvips/releases/download/v${LIBVIPS_VERSION}/vips-${LIBVIPS_VERSION}.tar.gz -O libvips.tar.gz \
    && tar -zxvf libvips.tar.gz \
    && cd /tmp/src/vips-${LIBVIPS_VERSION} && ./configure \
    && make && make install \
    && cd /home/app/unms \
    && mv node_modules/@ubnt/* tmp/ \
    && sed -i 's#"@ubnt/images": ".*"#"@ubnt/images": "file:../images"#g' tmp/ui-components/package.json \
    && sed -i 's#"@ubnt/icons": ".*"#"@ubnt/icons": "file:../icons"#g' tmp/link-core/package.json \
    && sed -i 's#"@ubnt/ui-components": ".*"#"@ubnt/ui-components": "file:../ui-components"#g' tmp/link-core/package.json \
    && sed -i 's#"@ubnt/link-core": ".*"#"@ubnt/link-core": "file:./tmp/link-core"#g' package.json \
    && rm -rf node_modules \
    && CHILD_CONCURRENCY=1 yarn install --production --no-cache --ignore-engines --network-timeout 100000 \
    && yarn cache clean \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* tmp /tmp/src \
    && setcap cap_net_raw=pe /usr/local/bin/node	

COPY --from=unms /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
# end unms #

# start unms-netflow #
WORKDIR /home/app/netflow

COPY --from=unms-netflow /home/app /home/app/netflow

RUN rm -rf node_modules \
    && apk add --no-cache --virtual .build-deps python3 g++ \
    && yarn install --frozen-lockfile --production --no-cache --ignore-engines \
    && yarn cache clean \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* \
    && rm -rf .node-gyp
# end unms-netflow #

# start unms-crm #
RUN mkdir -p /usr/src/ucrm \
    && mkdir -p /tmp/crontabs \
    && mkdir -p /usr/local/etc/php/conf.d \
    && mkdir -p /usr/local/etc/php-fpm.d \
    && mkdir -p /tmp/supervisor.d \
    && mkdir -p /tmp/supervisord

COPY --from=unms-crm /usr/src/ucrm /usr/src/ucrm
COPY --from=unms-crm /data /data
COPY --from=unms-crm /usr/local/bin/crm* /usr/local/bin/
COPY --from=unms-crm /usr/local/bin/docker* /usr/local/bin/
COPY --from=unms-crm /tmp/crontabs/server /tmp/crontabs/server
COPY --from=unms-crm /tmp/supervisor.d /tmp/supervisor.d
COPY --from=unms-crm /tmp/supervisord /tmp/supervisord

RUN grep -lr "nginx:nginx" /usr/src/ucrm/ | xargs sed -i 's/nginx:nginx/unms:unms/g' \
    && grep -lr "su-exec nginx" /usr/src/ucrm/ | xargs sed -i 's/su-exec nginx/su-exec unms/g' \
    && grep -lr "su-exec nginx" /tmp/ | xargs sed -i 's/su-exec nginx/su-exec unms/g' \
    && sed -i "s#unixUser='nginx'#unixUser='unms'#g" /usr/src/ucrm/scripts/unms_ready.sh \
    && sed -i 's#chmod -R 775 /data/log/var/log#chmod -R 777 /data/log/var/log#g' /usr/src/ucrm/scripts/dirs.sh \
    && sed -i 's#rm -rf /var/log#mv /var/log /data/log/var#g' /usr/src/ucrm/scripts/dirs.sh \
    && sed -i 's#LC_CTYPE=C tr -dc "a-zA-Z0-9" < /dev/urandom | fold -w 48 | head -n 1 || true#head /dev/urandom | tr -dc A-Za-z0-9 | head -c 48#g' \
       /usr/src/ucrm/scripts/parameters.sh \
    && sed -i '/\[program:nginx]/,+10d' /tmp/supervisor.d/server.ini \
    && sed -i "s#http://localhost/%s#http://localhost:9081/%s#g" /usr/src/ucrm/src/AppBundle/Service/LocalUrlGenerator.php \
    && sed -i "s#'localhost', '127.0.0.1'#'localhost:9081', '127.0.0.1:9081'#g" /usr/src/ucrm/src/AppBundle/Util/Helpers.php \
    && sed -i "s#crm-extra-programs-enabled && run-parts /etc/periodic/daily#run-parts /etc/periodic/daily#g" /tmp/crontabs/server
# end unms-crm #

# start nginx / php #
ENV NGINX_VERSION=nginx-1.14.2 \
    LUAJIT_VERSION=2.1.0-beta3 \
    LUA_NGINX_VERSION=0.10.14 \
    NGINX_DEVEL_KIT_VERSION=0.3.1 \
    PHP_VERSION=php-7.4.26

WORKDIR /tmp/src

RUN set -x \
    && apk add --no-cache --virtual .build-deps openssl-dev pcre-dev zlib-dev build-base libffi-dev python3-dev \
       argon2-dev coreutils curl-dev libsodium-dev libxml2-dev linux-headers oniguruma-dev openssl-dev readline-dev \
       sqlite-dev autoconf dpkg-dev dpkg file g++ gcc libc-dev make pkgconf re2c \
    && curl -SL http://nginx.org/download/${NGINX_VERSION}.tar.gz | tar xvz \
    && curl -SL https://github.com/openresty/lua-nginx-module/archive/v${LUA_NGINX_VERSION}.tar.gz | tar xvz \
    && curl -SL https://github.com/simpl/ngx_devel_kit/archive/v${NGINX_DEVEL_KIT_VERSION}.tar.gz | tar xvz \
    && curl -SL http://luajit.org/download/LuaJIT-${LUAJIT_VERSION}.tar.gz | tar xvz \
    && curl -SL https://www.php.net/get/${PHP_VERSION}.tar.xz/from/this/mirror -o php.tar.xz \
    && tar -xvf php.tar.xz \
    && cp php.tar.xz /usr/src \
    && cd /tmp/src/LuaJIT-${LUAJIT_VERSION} && make amalg PREFIX='/usr' -j $(nproc) && make install PREFIX='/usr' \
    && export LUAJIT_LIB=/usr/lib/libluajit-5.1.so && export LUAJIT_INC=/usr/include/luajit-2.1 \
    && mkdir -p /tmp/nginx \
    && cd /tmp/src/${NGINX_VERSION} && ./configure \
        --with-cc-opt='-g -O2 -fPIE -fstack-protector-strong -Wformat -Werror=format-security -fPIC -Wdate-time -D_FORTIFY_SOURCE=2' \
        --with-ld-opt='-Wl,-Bsymbolic-functions -fPIE -pie -Wl,-z,relro -Wl,-z,now -fPIC' \
        --with-pcre-jit \
        --with-threads \
        --with-file-aio \
        --add-module=/tmp/src/lua-nginx-module-${LUA_NGINX_VERSION} \
        --add-module=/tmp/src/ngx_devel_kit-${NGINX_DEVEL_KIT_VERSION} \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_auth_request_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-http_stub_status_module \
        --with-mail \
        --with-mail_ssl_module \
        --with-stream \
        --with-stream_ssl_module \
        --with-stream_realip_module \
        --prefix=/var/lib/nginx \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --http-log-path=/dev/stdout \
        --error-log-path=/dev/stderr \
        --lock-path=/tmp/nginx.lock \
        --pid-path=/tmp/nginx.pid \
        --http-client-body-temp-path=/tmp/nginx/client \
        --http-proxy-temp-path=/tmp/nginx/proxy \
        --http-fastcgi-temp-path=/tmp/nginx/fastcgi \
        --http-uwsgi-temp-path=/tmp/nginx/uwsgi \
        --http-scgi-temp-path=/tmp/nginx/scgi \
    && make -j $(nproc) \
    && make install \
    && export CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64" \
    && export CPPFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64" \
    && export LDFLAGS="-Wl,-O1 -pie" \
    && cd /tmp/src/${PHP_VERSION} && ./configure \
        --with-config-file-path="/usr/local/etc/php" \
        --with-config-file-scan-dir="/usr/local/etc/php/conf.d" \
        --enable-option-checking=fatal \
        --with-mhash \
        --with-pic \
        --enable-ftp \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-password-argon2 \
        --with-sodium=shared \
        --with-pdo-sqlite=/usr \
        --with-sqlite3=/usr \ 
        --with-curl \
        --with-openssl \
        --with-readline \
        --with-zlib \
        --with-pear \
        --enable-fpm \
        --disable-cgi \
        --with-fpm-user=www-data \
        --with-fpm-group=www-data \
    && make -j $(nproc) \
    && make install \
    && apk del .build-deps \
    && rm "/usr/bin/luajit-${LUAJIT_VERSION}" \
    && rm -rf /tmp/src \
    && rm -rf /var/cache/apk/* \
    && echo "unms ALL=(ALL) NOPASSWD: /usr/sbin/nginx -s *" >> /etc/sudoers \
    && echo "unms ALL=(ALL) NOPASSWD: /bin/cat *" >> /etc/sudoers \
    && echo "unms ALL=(ALL) NOPASSWD:SETENV: /refresh-configuration.sh *" >> /etc/sudoers

COPY --from=unms-crm /etc/nginx/available-servers /etc/nginx/ucrm

COPY --from=unms-nginx /entrypoint.sh /refresh-certificate.sh /refresh-configuration.sh /openssl.cnf /ip-whitelist.sh /
COPY --from=unms-postgres /usr/local/bin/migrate.sh /
COPY --from=unms-nginx /templates /templates
COPY --from=unms-nginx /www/public /www/public

RUN chmod +x /entrypoint.sh /refresh-certificate.sh /refresh-configuration.sh /ip-whitelist.sh /migrate.sh \
    && sed -i 's#NEW_BIN_DIR="/usr/local/bin"#NEW_BIN_DIR="/usr/bin"#g' /migrate.sh \
    && sed -i "s#-c listen_addresses=''#-c listen_addresses='' -p 50432#g" /migrate.sh \
    && sed -i "s#80#9081#g" /etc/nginx/ucrm/ucrm.conf \
    && sed -i "s#81#9082#g" /etc/nginx/ucrm/suspended_service.conf \
    && sed -i '/conf;/a \ \ include /etc/nginx/ucrm/*.conf;' /templates/nginx.conf.template \
    && grep -lr "location /nms/ " /templates | xargs sed -i "s#location /nms/ #location /nms #g" \
    && grep -lr "location /crm/ " /templates | xargs sed -i "s#location /crm/ #location /crm #g"
# end nginx / php #

# start php plugins / composer #
ENV PHP_INI_DIR=/usr/local/etc/php \
    SYMFONY_ENV=prod

COPY --from=unms-crm /usr/local/etc/php/php.ini /usr/local/etc/php/
COPY --from=unms-crm /usr/local/etc/php-fpm.conf /usr/local/etc/
COPY --from=unms-crm /usr/local/etc/php-fpm.d /usr/local/etc/php-fpm.d

RUN apk add --no-cache --virtual .build-deps autoconf dpkg-dev dpkg file g++ gcc libc-dev make pkgconf re2c \
    bzip2-dev freetype-dev libjpeg-turbo-dev libpng-dev libwebp-dev libzip-dev gmp-dev icu-dev \
    libxml2-dev postgresql-dev \
    && docker-php-source extract \
    && cd /usr/src/php \
    && pecl channel-update pecl.php.net \
    && echo '' | pecl install apcu ds \
    && docker-php-ext-enable apcu ds \
    && docker-php-ext-configure gd \
        --enable-gd \
        --with-freetype=/usr/include/ \
        --with-webp=/usr/include/ \
        --with-jpeg=/usr/include/ \
    && docker-php-ext-install -j$(nproc) bcmath bz2 exif gd gmp intl opcache \
       pdo_pgsql soap sockets sysvmsg sysvsem sysvshm zip \
    && curl -sS https://getcomposer.org/installer | php -- \
        --install-dir=/usr/bin --filename=composer \
    && cd /usr/src/ucrm \
    && composer install \
        --classmap-authoritative \
        --no-dev --no-interaction \
    && app/console assets:install --symlink web \
    && composer clear-cache \
    && rm /usr/bin/composer \
    && docker-php-source delete \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* \
    && sed -i 's#nginx#unms#g' /usr/local/etc/php-fpm.d/zz-docker.conf
# end php plugins / composer #

# start siridb #
COPY --from=unms-siridb /etc/siridb/siridb.conf /etc/siridb/siridb.conf

ENV LIBCLERI_VERSION=0.12.1 \
    SIRIDB_VERSION=2.0.44

RUN set -x \
    && apk add --no-cache --virtual .build-deps gcc make libuv-dev musl-dev pcre2-dev yajl-dev util-linux-dev \
    && mkdir -p /tmp/src && cd /tmp/src \
    && curl -SL https://github.com/transceptor-technology/libcleri/archive/${LIBCLERI_VERSION}.tar.gz | tar xvz \
    && curl -SL https://github.com/siridb/siridb-server/archive/${SIRIDB_VERSION}.tar.gz | tar xvz \
    && cd /tmp/src/libcleri-${LIBCLERI_VERSION}/Release \
    && make all -j $(nproc) && make install \
    && cd /tmp/src/siridb-server-${SIRIDB_VERSION}/Release \
    && make clean && make -j $(nproc) && make install \
    && apk del .build-deps \
    && rm -rf /tmp/src \
    && rm -rf /var/cache/apk/*
# end siridb #

# start rabbitmq #
COPY --from=rabbitmq /var/lib/rabbitmq/ /var/lib/rabbitmq/
COPY --from=rabbitmq /etc/rabbitmq/ /etc/rabbitmq/
COPY --from=rabbitmq /opt/rabbitmq/ /opt/rabbitmq/
# end rabbitmq #

WORKDIR /home/app/unms

ENV PATH=/home/app/unms/node_modules/.bin:$PATH:/opt/rabbitmq/sbin \
    PGDATA=/config/postgres \
    POSTGRES_DB=unms \
    QUIET_MODE=0 \
    WS_PORT=443 \
    PUBLIC_HTTPS_PORT=443 \
    PUBLIC_WS_PORT=443 \
    UNMS_NETFLOW_PORT=2055

EXPOSE 80 443 2055/udp

VOLUME ["/config"]

COPY root /