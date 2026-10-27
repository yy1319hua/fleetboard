BINARY := fleetboard
GO     := go

.PHONY: all build test vet fmt lint run clean

all: fmt vet test build

build:
	$(GO) build -trimpath -ldflags "-s -w" -o bin/$(BINARY) ./cmd/server

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

clean:
	rm -rf bin dist
