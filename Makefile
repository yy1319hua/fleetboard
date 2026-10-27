BINARY := fleetboard
GO     := go
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: all build test vet fmt lint run release web clean

all: fmt vet test build

build:
	$(GO) build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(BINARY) ./cmd/server

test:
	$(GO) test ./...

vet:
	$(GO) vet ./...

fmt:
	gofmt -w .

lint:
	@out=$$(gofmt -l .); if [ -n "$$out" ]; then echo "需要 gofmt:"; echo "$$out"; exit 1; fi

run:
	$(GO) run ./cmd/server

web:
	cd web && npm ci && npm run build

# release: 双架构静态二进制 + 前端产物 + 安装/卸载脚本 → deploy/release/
# 产物即发即用包，scp 到目标机解压跑 ./install.sh
release: test vet web
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(BINARY)-linux-amd64 ./cmd/server
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o bin/$(BINARY)-linux-arm64 ./cmd/server
	rm -rf deploy/release && mkdir -p deploy/release/$(BINARY)-$(VERSION)/web-dist
	cp bin/$(BINARY)-linux-$(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') deploy/release/$(BINARY)-$(VERSION)/$(BINARY)
	cp -r web/dist/. deploy/release/$(BINARY)-$(VERSION)/web-dist/
	cp deploy/fleetboard.service deploy/install.sh deploy/uninstall.sh deploy/.env.example deploy/release/$(BINARY)-$(VERSION)/
	tar czf deploy/release/$(BINARY)-$(VERSION)-linux-$(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/').tar.gz -C deploy/release $(BINARY)-$(VERSION)
	@echo "==> deploy/release/$(BINARY)-$(VERSION)-linux-*.tar.gz"

clean:
	rm -rf bin deploy/release
