# novasdr-rx-888

Builds a [NovaSDR](https://github.com/ramielrowe/NovaSDR) image that supports the
**RX-888 / RX-888 mk2 out of the box via SoapySDR**, and publishes it to GHCR.

## Why this repo exists

Upstream NovaSDR has no RX-888 driver. Its README drives the radio with an
external pipeline:

```sh
rx888_stream -s 6000000 | novasdr-server -c config.json -r receivers.json
```

and its Dockerfile installs only SoapySDR core plus SoapyRTLSDR — the runtime
image contains `novasdr-server` and `ws_probe` and nothing that can talk to an
RX-888. Running it in Kubernetes therefore meant a producer sidecar writing
into a FIFO, which is three containers and a named pipe to do one thing.

NovaSDR *is* compiled with the `soapysdr` feature and has a full Soapy config
surface (`device`, `channel`, `format`, `gain`, `settings`, `stream_args`). The
only missing piece is a Soapy module for the radio. This repo adds one:
[`renardspark/SDDC_Driver`](https://github.com/renardspark/SDDC_Driver), the
maintained continuation of the ExtIO_sddc lineage, which registers the Soapy
driver key **`SDDC`** and covers BBRF103, HF103, RX-666 and RX-888/mk2.

Result: one container, one process, no FIFO.

## Layout

```
Dockerfile                     six-stage build (see below)
config/                        config.json + receivers.json baked into the image
deploy/kubernetes.yaml         Deployment/Service/ConfigMap for a Talos cluster
scripts/bootstrap.sh           init/update submodules
scripts/build.sh               local docker build with submodule preflight
scripts/probe-device.sh        SoapySDRUtil --find/--probe against the real radio
vendor/NovaSDR                 submodule (pinned)
vendor/SDDC_Driver             submodule (pinned)
.github/workflows/             build + publish to ghcr.io/<owner>/<repo>
```

## Quick start

```sh
make bootstrap     # submodules, recursively
make build         # -> novasdr-rx-888:dev
make probe         # on the host with the radio attached
```

## How the build works

| Stage | Does |
|---|---|
| `fx3-firmware` | `make -C SDDC_FX3` with `gcc-arm-none-eabi` → `SDDC_FX3.img` |
| `soapy-builder` | SoapySDR from source at a pinned tag → `/usr/local` |
| `sddc-builder` | SDDC driver + the `SDDC` Soapy module, installed alongside |
| `frontend-builder` | NovaSDR's React frontend (`npm ci && npm run build`) |
| `backend-builder` | `cargo build --release --features "soapysdr,clfft"` |
| `runtime` | Debian slim + libs + module + binaries + frontend |

Three things in there are deliberate and worth not "simplifying" later:

**SoapySDR is built once from source and shared.** A Soapy module must match
the ABI of the `libSoapySDR` it loads into. Building the module against a
distro `libsoapysdr-dev` and then running against a source-built library gives
you a module that is present on disk and silently never loads.

**The firmware is built, not vendored or stubbed.** `Core/CMakeLists.txt`
embeds `SDDC_FX3.img` via `bin2h()`, and upstream gitignores that file. It
needs only a bare-metal ARM GCC, so the build produces it. On a Talos node the
`talos-rx-888` extension has already loaded FX3 firmware, so the radio presents
as `04b4:00f1`, `usb_device.cpp` marks it `need_firmware=0`, and this blob is
never uploaded — but it must exist at compile time, and it makes the image work
on hosts that have *not* pre-loaded firmware (`04b4:00f3`).

**Two build-time assertions.** `SoapySDDC/CMakeLists.txt` is wrapped in
`if (SoapySDR_FOUND)`, so a missing SoapySDR *skips* the module and still
exits 0. The build fails explicitly if `libSDDCSupport*` is absent, and again
in the runtime stage if `SoapySDRUtil --info` does not list `SDDC` — which is
how an ABI mismatch surfaces at build time instead of as an empty device list
in production.

## Configuration

`config/receivers.json` ships a working RX-888 receiver:

```json
"driver": {
  "kind": "soapysdr",
  "device": "driver=SDDC,index=0",
  "format": "cf32"
}
```

Two values are not free choices:

- **`index=0` is required.** `SoapySDDC/Registration.cpp:31` returns `nullptr`
  when the `index` kwarg is absent, so a bare `device: "driver=SDDC"` fails to
  open. Use `index` to pick between multiple radios; `findSDDC` also reports
  `label` and `serial`.
- **`format` must be `cf32`.** `Streaming.cpp:51-57` accepts `SOAPY_SDR_CF32`
  and throws on everything else. Because the SDDC core converts real ADC
  samples to complex, `signal` is `"iq"`, not `"real"`.

`sps` and `frequency` *are* free choices, and the shipped `4000000` / `4000000`
is a conservative default, not a recommendation. Get the legal sample rates for
your hardware from `make probe` (`SoapySDRUtil --probe`) and set `sps` to one of
them. Since `signal: "iq"`, the visible spectrum is `frequency ± sps/2`.

Per-device gain and the SDDC ADC-frequency knob go in `driver.gains` and
`driver.settings`; `--probe` lists the exact key names.

## Publishing

`.github/workflows/docker-publish.yml` pushes to
`ghcr.io/<owner>/<repo>` on every push to `main` and on `v*` tags. Tags:
`latest` (default branch), `git-<short-sha>` (matching the upstream NovaSDR
image convention), branch/PR refs, and semver on tags. Pull requests build but
never push, and never log in. No secret setup is needed beyond the automatic
`GITHUB_TOKEN`; the job requests `packages: write`.

A GHCR package is private on first publish. This one has been made public —
`ghcr.io/ramielrowe/novasdr-rx-888:git-a634872` pulls anonymously — so
`deploy/kubernetes.yaml` needs no `imagePullSecret`. If you republish under a
different owner, either make the package public in the repo's *Packages*
settings or add a pull secret to the Deployment.

Checkout uses `submodules: recursive` because NovaSDR has its own `frontend`
submodule; without it the frontend stage fails on a missing `package.json`.

## Deploying

`deploy/kubernetes.yaml` expects `generic-device-plugin` to advertise the radio
as an extended resource. The request on the container is both the scheduling
constraint and the trigger for kubelet to inject `/dev/bus/usb/BBB/DDD`:

```yaml
resources:
  limits:
    devic.es/rx-888-mk2-0009090703430c21: "1"
```

so there is no `nodeSelector` and no affinity — the count is 0 on nodes without
the radio. Update the resource name to match your device plugin's config, and
the image to match your GHCR package.

`strategy: Recreate` is load-bearing: with a device count of 1 a RollingUpdate
deadlocks, because the new pod cannot schedule until the old one releases the
radio and the old one is not torn down until the new one is Ready.

No privileged container and no hostPath: the `talos-rx-888` udev rule sets the
usbfs node to `0666`, so an unprivileged process can open it after injection.

## Bumping

```sh
make bump          # fast-forward both submodules, then review and commit
```

Submodules are pinned by commit. `vendor/NovaSDR` starts at `45b2951`, matching
the `ghcr.io/ramielrowe/novasdr:git-45b2951` image this work started from.

## Status / caveats

- **Builds on both architectures.** CI publishes `linux/amd64` (first green
  build: `ghcr.io/ramielrowe/novasdr-rx-888:git-a634872`, 42 MB compressed),
  and the same tree builds locally on `linux/arm64`. That matters because SDDC
  takes its AVX paths on a GitHub runner and its Neon paths on arm64.
- **Smoke-tested, on arm64.** The local image is 188 MB; `SoapySDRUtil --info`
  reports `Module found: .../libSDDCSupport.so (1.0.1-6ad4e9b)` and
  `Available factories... SDDC`; `novasdr-server` starts, loads the shipped
  config, derives `is_real=false basefreq=2000000 total_bandwidth=4000000`,
  and listens on 9002. The published amd64 image passed the same in-build
  assertion but has not been run by hand.
- **Not yet run against the radio.** The smoke test had no RX-888 attached, so
  device open, streaming and the `index=0`/`cf32` pairing are still unverified
  against hardware. `make probe` on the node holding the radio is the next step.
- **The SDDC Soapy module is third-party and of varying maturity.** Upstream
  SoapySDR has no RX-888 driver ([pothosware/SoapySDR#386](https://github.com/pothosware/SoapySDR/issues/386)).
  `makeSDDC` carries the comment *"I don't know how it works, but here I need
  to choose the right device"*. Alternatives if it misbehaves:
  [cozycactus/SoapyRX888](https://github.com/cozycactus/SoapyRX888) and
  [ON5HB/RX888MK2-Soapy](https://github.com/ON5HB/RX888MK2-Soapy).
- **`sps`/`frequency` defaults are unvalidated against real hardware.** Run
  `make probe` first.
- SIMD is dispatched per-file (`-mavx`, `-mavx2`, `-mavx512f` on separate
  translation units), not `-march=native`, so CI-built images stay portable
  across x86-64 hosts.
