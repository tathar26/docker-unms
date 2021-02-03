FROM ubnt/unms:1.3.7 as unms
FROM ubnt/unms-nginx:1.3.7 as unms-nginx
FROM ubnt/unms-netflow:1.3.7 as unms-netflow
FROM ubnt/unms-crm:3.3.7 as unms-crm
FROM ubnt/unms-siridb:1.3.7 as unms-siridb
FROM rabbitmq:3.7.14-alpine as rabbitmq

FROM nico640/s6-alpine-node:12.18.4-3.12

# base deps postgres 9.6, redis, certbot
RUN set -x \
    && apk upgrade --no-cache --update \
    && apk add --root / --arch ${APK_ARCH} --no-cache postgresql=9.6.13-r0 postgresql-client=9.6.13-r0 \
       postgresql-contrib=9.6.13-r0 --repository=http://dl-cdn.alpinelinux.org/alpine/v3.6/main \
    && apk add --no-cache redis certbot gzip bash vim dumb-init openssl libcap sudo \
       pcre pcre2 yajl gettext coreutils make argon2-libs erlang jq vips tar xz \
       libzip gmp icu c-client supervisor libuv su-exec

# start unms #
RUN mkdir -p /home/app/unms \
    && chown -R 1001:1001 /home/app
WORKDIR /home/app/unms

# copy unms app from offical image since the source code is not published at this time
COPY --from=unms --chown=1001:1001 /home/app/unms /home/app/unms

RUN rm -rf node_modules \
    && apk add --no-cache --virtual .build-deps python3 g++ vips-dev glib-dev \
    && sed -i "/postinstall/d" /home/app/unms/package.json \
    && ln -s /usr/bin/python3 /usr/bin/python \
    && CHILD_CONCURRENCY=1 yarn install --frozen-lockfile --production --no-cache --ignore-engines --network-timeout 100000 \
    && yarn cache clean \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* \
    && setcap cap_net_raw=pe /usr/local/bin/node	

COPY --from=unms /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
# end unms #

# start unms-netflow #
RUN mkdir -p /home/app/netflow \
    && chown -R 1001:1001 /home/app/netflow
WORKDIR /home/app/netflow

COPY --from=unms-netflow --chown=1001:1001 /home/app /home/app/netflow

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

COPY --from=unms-crm --chown=1001:1001 /usr/src/ucrm /usr/src/ucrm
COPY --from=unms-crm --chown=1001:1001 /data /data
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
ENV NGINX_UID=1001 \
    NGINX_VERSION=nginx-1.14.2 \
    LUAJIT_VERSION=2.1.0-beta3 \
    LUA_NGINX_VERSION=0.10.14 \
    NGINX_DEVEL_KIT_VERSION=0.3.1 \
    PHP_VERSION=php-7.3.26

WORKDIR /tmp/src

RUN set -x \
    && apk add --no-cache --virtual .build-deps openssl-dev pcre-dev zlib-dev build-base libffi-dev python3-dev \
       argon2-dev coreutils curl-dev libedit-dev libsodium-dev libxml2-dev openssl-dev sqlite-dev autoconf dpkg-dev \
       dpkg   file   g++   gcc   libc-dev   make   pkgconf   re2c \
    && curl -SL http://nginx.org/download/${NGINX_VERSION}.tar.gz | tar xvz \
    && curl -SL https://github.com/openresty/lua-nginx-module/archive/v${LUA_NGINX_VERSION}.tar.gz | tar xvz \
    && curl -SL https://github.com/simpl/ngx_devel_kit/archive/v${NGINX_DEVEL_KIT_VERSION}.tar.gz | tar xvz \
    && curl -SL http://luajit.org/download/LuaJIT-${LUAJIT_VERSION}.tar.gz | tar xvz \
    && curl -SL https://www.php.net/get/${PHP_VERSION}.tar.xz/from/this/mirror -o php.tar.xz \
    && tar -xvf php.tar.xz \
    && cp php.tar.xz /usr/src \
    && cd /tmp/src/LuaJIT-${LUAJIT_VERSION} && make amalg PREFIX='/usr' -j $(nproc) && make install PREFIX='/usr' \
    && export LUAJIT_LIB=/usr/lib/libluajit-5.1.so && export LUAJIT_INC=/usr/include/luajit-2.1 \
    && cd /tmp/src/${NGINX_VERSION} && ./configure \
        --with-cc-opt='-g -O2 -fPIE -fstack-protector-strong -Wformat -Werror=format-security -fPIC -Wdate-time -D_FORTIFY_SOURCE=2' \
        --with-ld-opt='-Wl,-Bsymbolic-functions -fPIE -pie -Wl,-z,relro -Wl,-z,now -fPIC' \
        --with-pcre-jit \
        --with-threads \
        --add-module=/tmp/src/lua-nginx-module-${LUA_NGINX_VERSION} \
        --add-module=/tmp/src/ngx_devel_kit-${NGINX_DEVEL_KIT_VERSION} \
        --with-http_ssl_module \
        --with-http_realip_module \
        --with-http_gzip_static_module \
        --with-http_secure_link_module \
        --without-mail_pop3_module \
        --without-mail_imap_module \
        --without-http_upstream_ip_hash_module \
        --without-http_memcached_module \
        --without-http_auth_basic_module \
        --without-http_userid_module \
        --without-http_uwsgi_module \
        --without-http_scgi_module \
        --prefix=/var/lib/nginx \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --http-log-path=/dev/stdout \
        --error-log-path=/dev/stderr \
        --lock-path=/tmp/nginx.lock \
        --pid-path=/tmp/nginx.pid \
        --http-client-body-temp-path=/tmp/body \
        --http-proxy-temp-path=/tmp/proxy \
    && make -j $(nproc) \
    && make install \
    && cd /tmp/src/${PHP_VERSION} && ./configure \
        --with-config-file-path="/usr/local/etc/php" \
        --with-config-file-scan-dir="/usr/local/etc/php/conf.d" \
        --enable-option-checking=fatal \
        --with-mhash \
        --enable-ftp \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-password-argon2 \
        --with-sodium=shared \
        --with-curl \
        --with-libedit \
        --with-openssl \
        --with-zlib \
        --enable-fpm \
        --with-fpm-user=www-data \
        --with-fpm-group=www-data \
        --disable-cgi \
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
COPY --from=unms-nginx /templates /templates
COPY --from=unms-nginx /www/public /www/public

RUN chmod +x /entrypoint.sh /refresh-certificate.sh /refresh-configuration.sh /ip-whitelist.sh \
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
    bzip2-dev freetype-dev imap-dev libjpeg-turbo-dev libpng-dev libwebp-dev libzip-dev gmp-dev icu-dev \
    libxml2-dev curl-dev krb5-dev \
    && apk add --root / --arch ${APK_ARCH} --no-cache --virtual .postgres-dev postgresql-dev=9.6.13-r0 \
	   --repository=http://dl-cdn.alpinelinux.org/alpine/v3.6/main \
    && docker-php-source extract \
    && cd /usr/src/php \
    && pecl channel-update pecl.php.net \
    && echo '' | pecl install apcu ds \
    && docker-php-ext-enable apcu ds \
    && docker-php-ext-configure gd \
        --with-gd \
        --with-freetype-dir=/usr/include/ \
        --with-png-dir=/usr/include/ \
        --with-jpeg-dir=/usr/include/ \
    && docker-php-ext-configure curl \
    && docker-php-ext-configure imap \
        --with-imap-ssl \
    && docker-php-ext-install -j2 pdo_pgsql gmp zip bcmath gd bz2 curl \
      exif intl dom xml opcache imap soap sockets sysvmsg sysvshm sysvsem \
    && curl -sS https://getcomposer.org/installer | php -- \
        --install-dir=/usr/bin --filename=composer --1 \
    && cd /usr/src/ucrm \
    && composer install \
        --classmap-authoritative \
        --no-dev --no-interaction \
    && app/console assets:install --symlink web \
    && composer clear-cache \
    && rm /usr/bin/composer \
    && docker-php-source delete \
    && apk del .build-deps \
    && apk del .postgres-dev \
    && rm -rf /var/cache/apk/* \
    && sed -i 's#nginx#unms#g' /usr/local/etc/php-fpm.d/zz-docker.conf
# end php plugins / composer #

# start siridb #
COPY --from=unms-siridb /etc/siridb/siridb.conf /etc/siridb/siridb.conf

ENV LIBCLERI_VERSION=0.12.1 \
    SIRIDB_VERSION=master

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