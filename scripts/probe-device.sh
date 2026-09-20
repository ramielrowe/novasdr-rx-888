#!/usr/bin/env bash
# Ask the built image what SoapySDR can see. Run this on the host that holds
# the radio. Usage: scripts/probe-device.sh [image]
#
# --find  lists devices (expect: driver=SDDC, with a serial)
# --probe dumps sample rates, gains and settings keys -- this is where you get
#         the legal values for sps and for driver.settings in receivers.json.
set -euo pipefail
IMAGE="${1:-novasdr-rx-888:dev}"

echo "== SoapySDR modules known to the image =="
docker run --rm "$IMAGE" SoapySDRUtil --info

echo
echo "== Devices visible on this host =="
docker run --rm --device /dev/bus/usb "$IMAGE" SoapySDRUtil --find

echo
echo "== Full probe of the first SDDC device =="
docker run --rm --device /dev/bus/usb "$IMAGE" \
  SoapySDRUtil --probe="driver=SDDC,index=0"
