# Dockerfile
# Builds GCC from source on an old-glibc base (Ubuntu 18.04),
# builds (optional) glibc, stages everything under /opt and produces a .deb
# Resulting .deb will be placed at /build/gcc-package_${GCC_VERSION}_amd64.deb

ARG BASE=ubuntu:18.04
FROM ${BASE} AS builder
ARG GCC_VERSION=14.2.0
ARG GLIBC_VERSION=2.35
ARG JOBS=$(nproc)

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /build

# Install build deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates wget curl \
    libgmp-dev libmpfr-dev libmpc-dev flex bison texinfo \
    python3 gawk unzip autoconf automake patch \
    dpkg-dev debhelper dh-make zlib1g-dev \
    sudo locales \
  && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /build/sources /build/out /opt /package

# Download GCC sources (user may override GCC_VERSION at build time)
WORKDIR /build/sources
RUN echo "GCC_VERSION=${GCC_VERSION}" > /build/GCC_VERS && \
    if [ -z "${GCC_VERSION}" ] || [ "${GCC_VERSION}" = "latest" ]; then \
      echo "Please set GCC_VERSION build arg to a concrete version (e.g. 14.2.0)"; exit 1; \
    fi

# Download tarball (expect the version to exist on ftp.gnu.org)
RUN wget -q https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz -O gcc-${GCC_VERSION}.tar.xz && \
    tar -xf gcc-${GCC_VERSION}.tar.xz && mv gcc-${GCC_VERSION} gcc-src

# Optional: download glibc (user may override GLIBC_VERSION)
RUN if [ -n "${GLIBC_VERSION}" ]; then \
      wget -q https://ftp.gnu.org/gnu/libc/glibc-${GLIBC_VERSION}.tar.xz -O glibc-${GLIBC_VERSION}.tar.xz && \
      tar -xf glibc-${GLIBC_VERSION}.tar.xz && mv glibc-${GLIBC_VERSION} glibc-src; \
    else \
      echo "No GLIBC_VERSION provided, skipping glibc build"; \
    fi

# Build GCC
WORKDIR /build/gcc-build
RUN ../sources/gcc-src/contrib/download_prerequisites || true

# Configure, build, install into /opt/gcc-<version>
RUN mkdir -p /build/gcc-build && cd /build/gcc-build && \
    ../sources/gcc-src/configure \
      --prefix=/opt/gcc-${GCC_VERSION} \
      --enable-languages=c,c++ \
      --disable-multilib \
      --enable-threads=posix \
      --with-system-zlib || (cat config.log && false) && \
    make -j${JOBS} bootstrap && \
    make install

# Build glibc and stage into /opt/glibc-<version> (optional)
# NOTE: building glibc is delicate. We install it under /opt to avoid
# contaminating the system. Use at your own risk.
RUN if [ -d /build/sources/glibc-src ]; then \
      mkdir -p /build/glibc-build && cd /build/glibc-build && \
      /build/sources/glibc-src/configure --prefix=/opt/glibc-${GLIBC_VERSION} \
        --enable-obsolete-rpc --with-__thread --disable-werror || (cat config.log && false) && \
      make -j${JOBS} && make install; \
    else echo "Skipping glibc build"; fi

# Create packaging layout under /package (this will become the .deb)
# We install GCC into /opt/gcc-<version> and glibc (if built) into /opt/glibc-<version>.
RUN mkdir -p /package/DEBIAN && \
    mkdir -p /package/opt && \
    cp -a /opt/gcc-${GCC_VERSION} /package/opt/ || true && \
    if [ -d /opt/glibc-${GLIBC_VERSION} ]; then cp -a /opt/glibc-${GLIBC_VERSION} /package/opt/; fi

# Add small wrapper scripts to make installation painless:
# - postinst: update ldconfig when package is installed (note: ldconfig root permissions)
# - prerm: placeholder
RUN cat > /package/DEBIAN/postinst <<'EOF'
#!/bin/sh
set -e
# Update ld cache so newly installed libs are discoverable
if command -v ldconfig >/dev/null 2>&1; then
  ldconfig || true
fi
# Optionally add /opt/gcc-<version>/bin to /etc/profile.d/ for interactive shells
if [ -d "/opt/gcc-${GCC_VERSION}" ]; then
  cat > /etc/profile.d/gcc-custom-path.sh <<'EOS'
# Added by gcc-custom package
export PATH=/opt/gcc-${GCC_VERSION}/bin:$PATH
export LD_LIBRARY_PATH=/opt/gcc-${GCC_VERSION}/lib64:/opt/gcc-${GCC_VERSION}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
EOS
  chmod 644 /etc/profile.d/gcc-custom-path.sh || true
fi
exit 0
EOF
RUN chmod 755 /package/DEBIAN/postinst

RUN cat > /package/DEBIAN/prerm <<'EOF'
#!/bin/sh
set -e
# cleanup profile.d entry if present
if [ -f /etc/profile.d/gcc-custom-path.sh ]; then
  rm -f /etc/profile.d/gcc-custom-path.sh || true
fi
exit 0
EOF
RUN chmod 755 /package/DEBIAN/prerm

# Control file
RUN cat > /package/DEBIAN/control <<EOF
Package: gcc-custom
Version: ${GCC_VERSION}+glibc${GLIBC_VERSION}
Architecture: amd64
Maintainer: Your Name <you@example.com>
Installed-Size: 102400
Depends: 
Section: devel
Priority: optional
Description: Custom-built GCC ${GCC_VERSION} plus libstdc++ and staged glibc ${GLIBC_VERSION}
 This package installs a locally-built GCC into /opt/gcc-${GCC_VERSION} and (if built)
 glibc into /opt/glibc-${GLIBC_VERSION}. Use with care.
EOF

# Set permissions
RUN chmod -R u=rwX,go=rX /package

# Build the .deb artifact
WORKDIR /build
RUN rm -f /build/gcc-package_${GCC_VERSION}_amd64.deb && dpkg-deb --build /package /build/gcc-package_${GCC_VERSION}_amd64.deb

# Final tiny runtime image that contains the .deb as an artifact layer
FROM scratch AS artifact
COPY --from=builder /build/gcc-package_${GCC_VERSION}_amd64.deb /gcc-package_${GCC_VERSION}_amd64.deb

# A helpful image to extract artifact (this image simply contains the .deb)
# When you run this image (or use docker create+cp) you can extract the deb.
FROM ubuntu:18.04 AS final
COPY --from=artifact /gcc-package_${GCC_VERSION}_amd64.deb /build/gcc-package_${GCC_VERSION}_amd64.deb
# Provide an easy-to-run extraction helper (if container is run with -v hostdir:/out)
CMD ["/bin/sh", "-c", "if [ -d /out ]; then cp /build/gcc-package_${GCC_VERSION}_amd64.deb /out/; echo 'Copied to /out'; else echo '/out not mounted — file is inside image at /build/gcc-package_${GCC_VERSION}_amd64.deb'; fi; sleep 1"]
