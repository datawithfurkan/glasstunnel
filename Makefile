.PHONY: help install proto build test lint clean dev-signaling dev-signaling-legacy dev-pwa dev-site dev-stack dev-mac lab-doctor lab-up lab-up-host lab-status lab-reset lab-down lab-mac lab-test lab-e2e lab-e2e-safari mac-build mac-package-local mac-release agent-validate agent-validate-run release-readiness release-readiness-mobile all-check

help:
	@echo "Glasstunnel dev commands"
	@echo ""
	@echo "  make install         Install JS + verify toolchains"
	@echo "  make proto           Regenerate Swift/TS/Go protobuf bindings"
	@echo "  make build           Build every language target"
	@echo "  make test            Run every test suite"
	@echo "  make lint            Lint everything"
	@echo "  make agent-validate  Print validation commands for the current diff"
	@echo "  make agent-validate-run"
	@echo "                        Run validation commands for the current diff"
	@echo "  make release-readiness"
	@echo "                        Run broad local public-release readiness checks"
	@echo "  make release-readiness-mobile"
	@echo "                        Run release readiness plus iOS Simulator smoke"
	@echo ""
	@echo "  make dev-stack       Start the account-first local lab"
	@echo "  make lab-up-host     Start the lab with an isolated Swift host"
	@echo "  make lab-status      Show owned local lab services"
	@echo "  make lab-down        Stop only owned local lab services"
	@echo "  make lab-test        Run fast lab and Worker checks"
	@echo "  make lab-e2e         Run the local account/Terminal browser journey"
	@echo "  make lab-e2e-safari  Run fixture checks in mobile WebKit"
	@echo "  make lab-mac         Launch the signed dev app against the local lab"
	@echo "  make dev-mac         Swift-run the Mac host pointed at localhost signaling"
	@echo "  make dev-signaling-legacy"
	@echo "                        Run the legacy Go signaling server on :18080"
	@echo "  make dev-pwa         Run the mobile PWA on :5173"
	@echo "  make dev-site        Run the marketing site on :5175"
	@echo ""
	@echo "  make mac-build       Swift build of the Mac host"
	@echo "  make mac-package-local"
	@echo "                        Build ad-hoc signed app + DMG for local packaging checks"
	@echo "  make mac-release     Build, sign, and notarize a release .app"
	@echo "  make all-check       Build + test every language target"

install:
	pnpm install
	@echo "Go: $$(go version 2>/dev/null || echo 'not installed')"
	@echo "Swift: $$(swift --version 2>/dev/null | head -1 || echo 'not installed')"

proto:
	bash packages/protocol/scripts/gen.sh

build:
	pnpm -r --filter=@glasstunnel/protocol --filter=@glasstunnel/shared-crypto --filter=@glasstunnel/cloudflare-signal --filter=@glasstunnel/mobile-pwa --filter=@glasstunnel/site build
	cd apps/signaling && go build ./...
	cd apps/host-macos && swift build

test:
	pnpm test
	pnpm lab:test:unit
	cd apps/signaling && go test ./...
	cd apps/host-macos && swift test

lint:
	pnpm -r typecheck
	pnpm -r lint
	cd apps/signaling && go vet ./...

clean:
	pnpm -r clean 2>/dev/null || true
	rm -rf apps/mobile-pwa/dist apps/host-macos/.build apps/host-macos/dist
	rm -rf site/dist
	rm -rf dist

dev-signaling:
	pnpm dev:signaling:legacy

dev-signaling-legacy:
	cd apps/signaling && PORT=18080 go run ./cmd/server

dev-pwa:
	pnpm --filter=@glasstunnel/mobile-pwa dev

dev-site:
	pnpm --filter=@glasstunnel/site dev

dev-stack:
	pnpm lab:up

lab-doctor:
	pnpm lab:doctor

lab-up:
	pnpm lab:up

lab-up-host:
	pnpm lab:up:host

lab-status:
	pnpm lab:status

lab-reset:
	pnpm lab:reset -- --yes

lab-down:
	pnpm lab:down

lab-mac:
	pnpm lab:mac

lab-test:
	pnpm lab:test

lab-e2e:
	pnpm lab:e2e

lab-e2e-safari:
	pnpm lab:e2e:safari

dev-mac:
	bash scripts/dev-app.sh

mac-build:
	cd apps/host-macos && swift build

mac-package-local:
	bash scripts/build-app.sh --ad-hoc

mac-release:
	bash scripts/build-app.sh

agent-validate:
	bash scripts/agent-validate.sh

agent-validate-run:
	bash scripts/agent-validate.sh --run

release-readiness:
	bash scripts/release-readiness.sh

release-readiness-mobile:
	bash scripts/release-readiness.sh --mobile

all-check: build test lint
	@echo "All checks passed."
