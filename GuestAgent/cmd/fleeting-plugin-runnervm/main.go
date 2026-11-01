// Command fleeting-plugin-runnervm is a GitLab fleeting plugin that lets
// gitlab-runner's taskscaler create and delete RunnerVM VMs through the
// daemon's fleet.* methods (Proto/fleet.md). It runs on the macOS host next
// to runnerd and talks to it over runnerd.sock.
package main

import (
	"github.com/andrejvysny/RunnerVM/GuestAgent/internal/fleet"
	"gitlab.com/gitlab-org/fleeting/fleeting/plugin"
)

// version is stamped at build time with -ldflags "-X main.version=<v>".
var version = "dev"

func main() {
	plugin.Main(&fleet.InstanceGroup{}, plugin.VersionInfo{
		Name:    "fleeting-plugin-runnervm",
		Version: version,
	})
}
