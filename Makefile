IMAGE ?= novasdr-rx-888:dev

.PHONY: help bootstrap build probe bump clean

help:
	@echo "bootstrap  - init/update submodules (recursive)"
	@echo "build      - docker build -> \$$(IMAGE)"
	@echo "probe      - SoapySDRUtil --find/--probe via the built image (needs the radio)"
	@echo "bump       - fast-forward both submodules to their upstream default branch"
	@echo "clean      - remove the local image"

bootstrap:
	./scripts/bootstrap.sh

build:
	./scripts/build.sh $(IMAGE)

probe:
	./scripts/probe-device.sh $(IMAGE)

bump:
	git submodule update --remote --merge vendor/NovaSDR vendor/SDDC_Driver
	git -C vendor/NovaSDR submodule update --init --recursive
	@echo
	@git submodule status
	@echo
	@echo "Review, then: git add vendor && git commit"

clean:
	-docker image rm $(IMAGE)
