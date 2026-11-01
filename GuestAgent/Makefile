# RunnerVM guest agent. The agent is cross-built on a macOS host for the
# guest it will run in, so every target is explicit about GOOS/GOARCH.

BINARY  := runnervm-guest-agent
PKG     := ./cmd/guest-agent
# bin/ is already covered by the repository .gitignore.
BUILD   := bin
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X main.version=$(VERSION)

# CGO is off so the agent is a static, dependency-free binary that runs on
# any guest image regardless of its libc.
export CGO_ENABLED := 0

.PHONY: all build build-linux build-darwin build-plugin test vet fmt fmt-check clean

all: fmt-check vet test build build-plugin

build:
	go build -ldflags "$(LDFLAGS)" -o $(BUILD)/$(BINARY) $(PKG)

build-linux:
	GOOS=linux GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o $(BUILD)/linux-arm64/$(BINARY) $(PKG)
	GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o $(BUILD)/linux-amd64/$(BINARY) $(PKG)

build-darwin:
	GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o $(BUILD)/darwin-arm64/$(BINARY) $(PKG)

# GitLab fleeting plugin: runs on the macOS host next to runnerd.
PLUGIN     := fleeting-plugin-runnervm
PLUGIN_PKG := ./cmd/$(PLUGIN)
PLUGIN_OUT := dist/$(PLUGIN)-darwin-arm64

build-plugin:
	GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o $(PLUGIN_OUT) $(PLUGIN_PKG)

test:
	go test ./... -count=1

vet:
	go vet ./...
	GOOS=linux GOARCH=arm64 go vet ./...

fmt:
	gofmt -w .

fmt-check:
	@out="$$(gofmt -l .)"; if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

clean:
	rm -rf $(BUILD) dist
