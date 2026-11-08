.PHONY: build verify e2e-oras e2e-ghcr update-oras-state clean

build:
	./scripts/build.sh

verify:
	bash ./scripts/verify.sh

e2e-oras: build
	bash ./scripts/e2e-oras.sh

e2e-ghcr:
	bash ./scripts/e2e-ghcr.sh

update-oras-state:
	@test -n "$(VERSION)" || (echo "Usage: make update-oras-state VERSION=vX.Y.Z" >&2; exit 2)
	bash ./scripts/update-oras-state.sh "$(VERSION)"

clean:
	rm -rf dist
