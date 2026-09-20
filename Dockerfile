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
# SoapySDR is built ONCE from source and shared by both the SDDC module and
# the Rust build. That is deliberate: a Soapy module must match the ABI of the
# libSoapySDR it is loaded into, and mixing a distro libsoapysdr-dev with a
# source build is the classic way to get a module that silently never loads.

ARG DEBIAN_VERSION=bookworm
ARG SOAPYSDR_TAG=soapy-sdr-0.8.1
ARG RUST_IMAGE=rustlang/rust:nightly-bookworm-slim
ARG NODE_IMAGE=node:20-slim

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
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-arm-none-eabi make ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY vendor/SDDC_Driver/ ./
RUN make -C ./SDDC_FX3 && test -s ./SDDC_FX3/SDDC_FX3.img

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
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build build -j"$(nproc)" \
    && cmake --install build \
    && ldconfig \
    && find /usr/local/lib -name 'libSDDCSupport*' -print | grep -q . \
       || (echo 'FATAL: SDDC Soapy module was not built -- find_package(SoapySDR) missed' >&2; exit 1)

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
