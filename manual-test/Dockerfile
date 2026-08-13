# Manual-testing image for this fork's redis-sorted-list-renewal feature and
# its migration scripts. Not part of the CI matrix (see the Dockerfile-test-*
# files at the repo root for that) -- this installs the module the same way
# a real deployment would (via the fork's own rockspec, through `luarocks
# make`), against the actively-maintained openresty/openresty base image
# also used by Dockerfile-test-ubuntu.
FROM openresty/openresty:1.31.1.1-jammy

ENV DEBIAN_FRONTEND noninteractive

# Runtime dependencies: bash/curl/diffutils/grep/openssl/sed/mktemp/cut/date
# are this library's own hard runtime requirements (see the Makefile's
# RUNTIME_DEPENDENCIES and the README's documented requirements). make is
# needed both to build sockproc from source and because the rockspec's build
# step shells out to the Makefile. bsdextrautils provides `hexdump`, which
# dehydrated itself checks for at startup and refuses to run at all without
# (see FORKCHANGES.md). redis-tools and jq are not needed by the library
# itself -- they're here so redis-cli/jq are available inside this container
# too, for poking around or running scripts/*.sh without leaving it.
RUN apt-get update && \
  apt-get -y install \
    bash \
    bsdextrautils \
    curl \
    diffutils \
    grep \
    jq \
    make \
    openssl \
    redis-tools \
    vim \
    sed

RUN curl -fsSL -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/download/2026.7.3/cloudflared-linux-amd64 && \
  chmod +x /usr/local/bin/cloudflared

WORKDIR /app
COPY . /app

# Builds (dehydrated, sockproc, the lua-resty-shell vendor file -- the
# Makefile's default `all` target) and installs (lib/ + bin/ -- `make
# install`) exactly as a real `luarocks install lua-resty-auto-ssl` would,
# just from this local checkout instead of a published rock. Also resolves
# and installs this rockspec's own declared dependencies (lua-resty-http,
# shell-games).
RUN luarocks make lua-resty-auto-ssl-git-1.rockspec

# `nobody`'s primary group is named differently across distro families --
# `nogroup` on Debian/Ubuntu (this image's own base), `nobody` on
# RHEL/CentOS -- detected via `getent` rather than hardcoded, so this still
# works if the FROM image above is ever swapped to a RedHat-based one.
RUN mkdir -p /etc/resty-auto-ssl && \
  nobody_group="$(getent group nobody > /dev/null 2>&1 && echo nobody || echo nogroup)" && \
  chown "nobody:${nobody_group}" /etc/resty-auto-ssl

COPY manual-test/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

EXPOSE 9080 9443

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
