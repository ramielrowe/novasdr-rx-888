# syntax=docker/dockerfile:1
#
# NovaSDR with out-of-the-box RX-888 (mk1/mk2) support via SoapySDR.
#
# Upstream NovaSDR has no RX-888 driver: its README drives the radio with an
# external `rx888_stream | novasdr-server` pipeline, and its Dockerfile ships
# only SoapyRTLSDR. This image instead builds the SDDC SoapySDR module
# (driver key "SDDC") so novasdr-server can open the radio natively through
# its own `soapysdr` input driver -- one process, no FIFO, no sidecar.
#
# Everything is built on ONE Debian release (trixie): SDDC sets CMAKE_CXX_STANDARD 20
# and includes <format>, which bookworm's GCC 12 does not implement (GCC 13+ only),
# and keeping the Rust stage on the same release avoids libstdc++/glibc skew
# between novasdr-server and the Soapy module it dlopens.
#
# SoapySDR is built ONCE from source and shared by both the SDDC module and
# the Rust build. That is deliberate: a Soapy module must match the ABI of the
# libSoapySDR it is loaded into, and mixing a distro libsoapysdr-dev with a
# source build is the classic way to get a module that silently never loads.

ARG DEBIAN_VERSION=trixie
ARG SOAPYSDR_TAG=soapy-sdr-0.8.1
ARG RUST_IMAGE=rustlang/rust:nightly-trixie-slim
ARG NODE_IMAGE=node:20-trixie-slim

# ---------------------------------------------------------------------------
# Stage 1: FX3 firmware
#
# Core/CMakeLists.txt embeds SDDC_FX3.img into the driver via bin2h(). The
# .img is gitignored upstream and built from vendored sources with nothing
# more exotic than an ARM bare-metal GCC, so we build it rather than vendoring
# a binary blob or stubbing it out.
#
# On our Talos nodes the talos-rx-888 system extension already loads FX3
# firmware at boot and on hotplug, so the radio presents as 04b4:00f1 and
# usb_device.cpp marks it need_firmware=0 -- this blob is never uploaded. It
# still has to exist at compile time, and it makes the image work on hosts
# that have NOT pre-loaded firmware (04b4:00f3).
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS fx3-firmware
# libnewlib-arm-none-eabi is REQUIRED and easy to miss. On Debian,
# gcc-arm-none-eabi ships no bare-metal C library, so the Cypress SDK headers
# die with "fatal error: stdlib.h: No such file or directory". SDDC's own CI
# never hits this because it runs on Ubuntu, where newlib arrives as a
# dependency of gcc-arm-none-eabi. talos-rx-888's Dockerfile installs both.
#
# gcc + libc6-dev are the NATIVE toolchain, not a duplicate of the ARM one:
# the makefile's last step builds `elf2img`, a host-side utility that converts
# the linked .elf into the .img the loader uploads.
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-arm-none-eabi libnewlib-arm-none-eabi \
      gcc libc6-dev make ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY vendor/SDDC_Driver/ ./
RUN make -C ./SDDC_FX3 all && test -s ./SDDC_FX3/SDDC_FX3.img

# ---------------------------------------------------------------------------
# Stage 2: SoapySDR core, from source, into /usr/local
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS soapy-builder
ARG SOAPYSDR_TAG
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${SOAPYSDR_TAG}" \
      https://github.com/pothosware/SoapySDR.git /tmp/SoapySDR \
    && cmake -S /tmp/SoapySDR -B /tmp/SoapySDR/build \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /tmp/SoapySDR/build -j"$(nproc)" \
    && cmake --install /tmp/SoapySDR/build \
    && ldconfig \
    && rm -rf /tmp/SoapySDR

# ---------------------------------------------------------------------------
# Stage 3: the SDDC SoapySDR module (RX-888 / RX-666 / BBRF103 / HF103)
#
# SoapySDDC/CMakeLists.txt is guarded by find_package(SoapySDR CONFIG): if
# SoapySDR is not found the module is SKIPPED and the build still succeeds.
# The explicit test at the end turns that silent skip into a hard failure.
# ---------------------------------------------------------------------------
FROM soapy-builder AS sddc-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
      libusb-1.0-0-dev libfftw3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY vendor/SDDC_Driver/ ./
COPY --from=fx3-firmware /src/SDDC_FX3/SDDC_FX3.img ./SDDC_FX3.img

# Local fixes to the vendored driver, applied BEFORE the throwaway git init
# below so they are not mistaken for upstream history. `git apply` exits
# non-zero if a patch stops applying after a submodule bump, which is the
# behaviour we want: a silently dropped patch here means a radio that
# enumerates but cannot be opened.
COPY patches/ /patches/
RUN set -e; for p in /patches/*.patch; do \
      echo "applying $p"; git apply --verbose "$p"; \
    done

# CMakeLists.txt:7 calls CheckGitSetup(), which shells out to `git log` and
# `git describe`. A submodule checked out into a build context has no usable
# .git, so GIT_HASH comes back EMPTY and CheckGitWrite() is then invoked with
# zero arguments -- a hard CMake configure error, not a skipped version string.
# Re-establish a throwaway repo so the version probe has something to read.
# SDDC_REV is passed in for provenance so the baked-in version is traceable to
# the real submodule commit rather than to this synthetic one.
ARG SDDC_REV=vendored
RUN git init -q . \
    && git config user.email build@localhost \
    && git config user.name  build \
    && git add -A \
    && git commit -q -m "vendored SDDC_Driver ${SDDC_REV}" \
    && git tag -a "v${SDDC_REV}" -m "vendored"

RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build build -j"$(nproc)" \
    && cmake --install build \
    && ldconfig

# Deliberately a SEPARATE RUN. Chained onto the build with `&& ... ||`, this
# message fires for any failure in the chain and misattributes a plain compile
# or configure error to a missing SoapySDR.
RUN find /usr/local/lib -name 'libSDDCSupport*' -print | grep -q . \
    || { echo 'FATAL: SoapySDDC module missing. find_package(SoapySDR CONFIG) in SoapySDDC/CMakeLists.txt did not find SoapySDR, so the module was silently skipped.' >&2; exit 1; }

# ---------------------------------------------------------------------------
# Stage 4: NovaSDR frontend
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS frontend-builder
WORKDIR /build
COPY vendor/NovaSDR/frontend/package*.json ./
RUN npm ci
COPY vendor/NovaSDR/frontend/ ./
RUN npm run build

# ---------------------------------------------------------------------------
# Stage 5: NovaSDR server (Rust), built against the SAME SoapySDR
# ---------------------------------------------------------------------------
FROM ${RUST_IMAGE} AS backend-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config clang libclang-dev \
      ocl-icd-opencl-dev libclfft-dev libopus-dev libusb-1.0-0-dev \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=soapy-builder /usr/local/lib/ /usr/local/lib/
COPY --from=soapy-builder /usr/local/include/ /usr/local/include/
RUN ldconfig
WORKDIR /build
COPY vendor/NovaSDR/Cargo.toml ./
COPY vendor/NovaSDR/crates/ ./crates/
RUN cargo build --release --features "soapysdr,clfft" -p novasdr-server \
    && cargo build --release -p ws_probe

# ---------------------------------------------------------------------------
# Stage 6: runtime
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      libusb-1.0-0 libfftw3-single3 ocl-icd-libopencl1 libclfft2 libopus0 \
      ca-certificates netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# libSoapySDR + every installed module, including SDDCSupport.
COPY --from=sddc-builder /usr/local/lib/libSoapySDR* /usr/local/lib/
COPY --from=sddc-builder /usr/local/lib/SoapySDR/ /usr/local/lib/SoapySDR/
COPY --from=sddc-builder /usr/local/bin/SoapySDRUtil /usr/local/bin/
RUN ldconfig

WORKDIR /app
COPY --from=backend-builder /build/target/release/novasdr-server /app/
COPY --from=backend-builder /build/target/release/ws_probe /app/
COPY --from=frontend-builder /build/dist /app/frontend/dist
COPY vendor/NovaSDR/crates/novasdr-server/resources/ /app/resources/
COPY config/ /app/config/
RUN mkdir -p /app/logs /app/data

# Fail the build if the module is present but unloadable (ABI mismatch is the
# failure this catches -- it is silent at runtime otherwise).
RUN SoapySDRUtil --info 2>&1 | tee /tmp/soapy-info \
    && grep -q "SDDC" /tmp/soapy-info \
    || (echo 'FATAL: SDDC module did not load into libSoapySDR' >&2; \
        cat /tmp/soapy-info >&2; exit 1)

EXPOSE 9002
ENV RUST_LOG=info
ENV RUST_BACKTRACE=1
CMD ["/app/novasdr-server", "-c", "/app/config/config.json", "-r", "/app/config/receivers.json"]
