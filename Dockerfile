# syntax=docker/dockerfile:1
# https://github.com/moby/buildkit/blob/master/frontend/dockerfile/docs/reference.md

# Stage: compile-frontend
# Purpose: Compiles the frontend
# Notes:
#  - Does NPM stuff with Typescript and such
FROM --platform=$BUILDPLATFORM docker.io/node:18-bookworm-slim AS compile-frontend

COPY ./src-ui /src/src-ui

WORKDIR /src/src-ui
RUN set -eux \
  && npm update npm -g \
  && npm ci --omit=optional
RUN set -eux \
  && ./node_modules/.bin/ng build --configuration production

# Stage: pipenv-base
# Purpose: Generates a requirements.txt file for building
# Comments:
#  - pipenv dependencies are not left in the final image
#  - pipenv can't touch the final image somehow
FROM --platform=$BUILDPLATFORM docker.io/python:3.11-alpine as pipenv-base

WORKDIR /usr/src/pipenv

COPY Pipfile* ./

RUN set -eux \
  && echo "Installing pipenv" \
    && python3 -m pip install --no-cache-dir --upgrade pipenv==2023.9.8 \
  && echo "Generating requirement.txt" \
    && pipenv requirements > requirements.txt

# Stage: s6-overlay-base
# Purpose: Installs s6-overlay and rootfs
# Comments:
#  - Don't leave anything extra in here either
FROM docker.io/python:3.11-slim-bookworm as s6-overlay-base

WORKDIR /usr/src/s6

# https://github.com/just-containers/s6-overlay#customizing-s6-overlay-behaviour
ENV \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_VERBOSITY=1 \
    PATH=/command:$PATH

# Buildx provided, must be defined to use though
ARG TARGETARCH
ARG TARGETVARIANT
# Lock this version
ARG S6_OVERLAY_VERSION=3.1.5.0

# Lock these are well to prevent rebuilds as much as possible
ARG S6_BUILD_TIME_PKGS="curl=7.88.1-10+deb12u1\
                        xz-utils=5.4.1-0.2"

RUN set -eux \
    && echo "Installing build time packages" \
      && apt-get update \
      && apt-get install --yes --quiet --no-install-recommends ${S6_BUILD_TIME_PKGS} \
    && echo "Determining arch" \
      && S6_ARCH="" \
      && if [ "${TARGETARCH}${TARGETVARIANT}" = "amd64" ]; then S6_ARCH="x86_64"; \
      elif [ "${TARGETARCH}${TARGETVARIANT}" = "arm64" ]; then S6_ARCH="aarch64"; fi\
      && if [ -z "${S6_ARCH}" ]; then { echo "Error: Not able to determine arch"; exit 1; }; fi \
    && echo "Installing s6-overlay for ${S6_ARCH}" \
      && curl --fail --silent --show-error -L --output s6-overlay-noarch.tar.xz --location \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
      && curl --fail --silent --show-error -L --output s6-overlay-noarch.tar.xz.sha256 \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz.sha256" \
      && curl --fail --silent --show-error -L --output s6-overlay-${S6_ARCH}.tar.xz --location \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
      && curl --fail --silent --show-error -L --output s6-overlay-${S6_ARCH}.tar.xz.sha256 \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz.sha256" \
      && echo "Validating s6-archive checksums" \
        && sha256sum -c ./*.sha256 \
      && echo "Unpacking archives" \
        && tar -C / -Jxpf s6-overlay-noarch.tar.xz \
        && tar -C / -Jxpf s6-overlay-${S6_ARCH}.tar.xz \
      && echo "Removing downloaded archives" \
        && rm ./*.tar.xz \
        && rm ./*.sha256 \
    && echo "Cleaning up image" \
      && apt-get -y purge ${S6_BUILD_TIME_PKGS} \
      && apt-get -y autoremove --purge \
      && rm -rf /var/lib/apt/lists/* \
      && ls -ahl /

# Copy our service defs and filesystem
COPY ./docker/rootfs /

# Stage: main-app
# Purpose: The final image
# Comments:
#  - Don't leave anything extra in here
FROM s6-overlay-base as main-app

LABEL org.opencontainers.image.authors="paperless-ngx team <hello@paperless-ngx.com>"
LABEL org.opencontainers.image.documentation="https://docs.paperless-ngx.com/"
LABEL org.opencontainers.image.source="https://github.com/paperless-ngx/paperless-ngx"
LABEL org.opencontainers.image.url="https://github.com/paperless-ngx/paperless-ngx"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"

ARG DEBIAN_FRONTEND=noninteractive

# Configure some pip defaults
ENV \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_PREFER_BINARY=1 \
    PIP_DEFAULT_TIMEOUT=1000

#
# Begin installation and configuration
# Order the steps below from least often changed to most
#

# Packages need for running
ARG RUNTIME_PACKAGES="\
  # General utils
  curl \
  # Docker specific
  gosu \
  # Timezones support
  tzdata \
  # fonts for text file thumbnail generation
  fonts-liberation \
  gettext \
  ghostscript \
  gnupg \
  icc-profiles-free \
  imagemagick \
  # Image processing
  liblept5 \
  liblcms2-2 \
  libtiff6 \
  libfreetype6 \
  libwebp7 \
  libopenjp2-7 \
  libimagequant0 \
  libraqm0 \
  libjpeg62-turbo \
  # PostgreSQL
  libpq5 \
  postgresql-client \
  # MySQL / MariaDB
  mariadb-client \
  # For Numpy
  libatlas3-base \
  # OCRmyPDF dependencies
  tesseract-ocr \
  tesseract-ocr-eng \
  tesseract-ocr-deu \
  tesseract-ocr-fra \
  tesseract-ocr-ita \
  tesseract-ocr-spa \
  unpaper \
  pngquant \
  # pikepdf / qpdf
  jbig2dec \
  libxml2 \
  libxslt1.1 \
  libgnutls30 \
  libqpdf29 \
  qpdf \
  # Mime type detection
  file \
  libmagic1 \
  media-types \
  zlib1g \
  # Barcode splitter
  libzbar0 \
  poppler-utils \
  # RapidFuzz on armv7
  libatomic1"

# Install basic runtime packages.
# These change very infrequently
RUN set -eux \
  echo "Installing system packages" \
    && apt-get update \
    && apt-get install --yes --quiet --no-install-recommends ${RUNTIME_PACKAGES} \
  && echo "Adjusting imagemagick policy" \
    # Install can't handling this existing during install
    mv /etc/ImageMagick-6/paperless-policy.xml  /etc/ImageMagick-6/policy.xml \
  && echo "Cleaning up" \
    && rm -rf /var/lib/apt/lists/*

# Copy gunicorn config
# Changes very infrequently
WORKDIR /usr/src/paperless/

COPY gunicorn.conf.py .

# setup docker-specific things
# These change sometimes, but rarely
WORKDIR /usr/src/paperless/docker/

COPY [ \
  "docker/management_script.sh", \
  "docker/install_management_commands.sh", \
  "/usr/src/paperless/docker/" \
]

RUN set -eux \
  && echo "Installing managment commands" \
    && chmod +x install_management_commands.sh \
    && ./install_management_commands.sh

# Buildx provided, must be defined to use though
ARG TARGETARCH
ARG TARGETVARIANT

# Can be workflow provided, defaults set for manual building
ARG JBIG2ENC_VERSION=0.29

# Install the built packages from the installer library images
# These change sometimes
RUN set -eux \
  && echo "Getting binaries" \
    && mkdir paperless-ngx \
    && curl --fail --silent --show-error --output paperless-ngx.tar.gz --location https://github.com/paperless-ngx/builder/archive/58bb061b9b3b63009852d6d875f9a305d9ae6ac9.tar.gz \
    && tar -xf paperless-ngx.tar.gz --directory paperless-ngx --strip-components=1 \
    && cd paperless-ngx \
    # Setting a specific revision ensures we know what this installed
    # and ensures cache breaking on changes
  && echo "Installing jbig2enc" \
    && cp ./jbig2enc/${JBIG2ENC_VERSION}/${TARGETARCH}${TARGETVARIANT}/jbig2 /usr/local/bin/ \
    && cp ./jbig2enc/${JBIG2ENC_VERSION}/${TARGETARCH}${TARGETVARIANT}/libjbig2enc* /usr/local/lib/ \
    && chmod a+x /usr/local/bin/jbig2 \
  && echo "Cleaning up image layer" \
    && cd ../ \
    && rm -rf paperless-ngx \
    && rm paperless-ngx.tar.gz

WORKDIR /usr/src/paperless/src/

# Python dependencies
# Change pretty frequently
COPY --from=pipenv-base /usr/src/pipenv/requirements.txt ./

# Packages needed only for building a few quick Python
# dependencies
ARG BUILD_PACKAGES="\
  build-essential \
  git \
  # https://www.psycopg.org/docs/install.html#prerequisites
  libpq-dev \
  # https://github.com/PyMySQL/mysqlclient#linux
  default-libmysqlclient-dev \
  pkg-config"

# hadolint ignore=DL3042
RUN --mount=type=cache,target=/root/.cache/pip/,id=pip-cache \
  set -eux \
  && echo "Installing build system packages" \
    && apt-get update \
    && apt-get install --yes --quiet --no-install-recommends ${BUILD_PACKAGES} \
    && python3 -m pip install --upgrade wheel \
  && echo "Installing Python requirements" \
    && python3 -m pip install --default-timeout=1000 --requirement requirements.txt \
  && echo "Installing NLTK data" \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/share/nltk_data" snowball_data \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/share/nltk_data" stopwords \
    && python3 -W ignore::RuntimeWarning -m nltk.downloader -d "/usr/share/nltk_data" punkt \
  && echo "Cleaning up image" \
    && apt-get -y purge ${BUILD_PACKAGES} \
    && apt-get -y autoremove --purge \
    && apt-get clean --yes \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /tmp/* \
    && rm -rf /var/tmp/* \
    && rm -rf /var/cache/apt/archives/* \
    && truncate -s 0 /var/log/*log

# copy backend
COPY ./src ./

# copy frontend
COPY --from=compile-frontend /src/src/documents/static/frontend/ ./documents/static/frontend/

# add users, setup scripts
# Mount the compiled frontend to expected location
RUN set -eux \
  && addgroup --gid 1000 paperless \
  && useradd --uid 1000 --gid paperless --home-dir /usr/src/paperless paperless \
  && chown -R paperless:paperless /usr/src/paperless \
  && gosu paperless python3 manage.py collectstatic --clear --no-input --link \
  && gosu paperless python3 manage.py compilemessages

VOLUME ["/usr/src/paperless/data", \
        "/usr/src/paperless/media", \
        "/usr/src/paperless/consume", \
        "/usr/src/paperless/export"]

ENTRYPOINT ["/init"]

EXPOSE 8000
