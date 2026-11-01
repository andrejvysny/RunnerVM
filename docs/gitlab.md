# GitLab autoscaled runners on RunnerVM

RunnerVM can supply the VMs for GitLab CI jobs. gitlab-runner's autoscaler asks for VMs, a
RunnerVM *fleeting plugin* (`fleeting-plugin-runnervm`) turns each request into a `fleet.*` call
on `runnerd.sock`, the job runs inside a fresh ephemeral guest over SSH, and the VM is destroyed
after that one job. The same host budget (CPU, memory, disk, `host.maxVMs`) is shared with any
GitHub profiles.

Wire contract for the daemon side: [`Proto/fleet.md`](../Proto/fleet.md).

## Why a fleeting plugin

GitHub exposes a per-scale-set queue, so RunnerVM watches demand itself and boots VMs ahead of
jobs. GitLab has no per-tag "pending jobs" API a host can poll. gitlab-runner's taskscaler already
owns demand (it knows which jobs its runner would take), so the split is:

| gitlab-runner (taskscaler) | RunnerVM |
| --- | --- |
| decides how many instances it wants (`policy`, `max_instances`) | decides whether they fit the host budget (`fleet.create` admission) |
| picks a VM, connects over SSH, runs the job | clones the image, boots the VM, installs the per-VM SSH key |
| deletes the instance after `max_use_count` jobs | destroys the VM; reaps it itself if gitlab-runner dies |

## Architecture

```
GitLab  <--HTTPS poll--  gitlab-runner (manager, runs on the Mac host)
                           |  taskscaler: wants N instances
                           |  fleeting plugin protocol (stdio, go-plugin)
                           v
                  fleeting-plugin-runnervm
                           |  fleet.info/list/create/delete/renew/connect
                           v  JSON-RPC over runnerd.sock (0600)
                        runnerd --> vmworker --> Linux/macOS guest
                                                    ^
        gitlab-runner --SSH (per-VM ed25519 key)----+   job runs here as `runner`
```

## Prerequisites

- RunnerVM installed and running ([install.md](install.md)); `runnerctl doctor` is green.
- `gitlab-runner` on the host (`brew install gitlab-runner`), version with the autoscaler and
  fleeting support (17.x or newer; the images ship 19.4.1).
- A GitLab project (or group) you may create runners in.
- Docker is *not* needed on the host. It lives in the Linux guest image.

## 1. Image

Linux: build the recipe once (Docker, git, gitlab-runner helper, key-only sshd):

```sh
runnerctl image build images/recipes/ubuntu-24-gitlab --name ubuntu-24-gitlab --wait
runnerctl image list
```

Build or pull `ubuntu-24` first if your host does not have it; the recipe is `FROM ubuntu-24`.
See [image-build.md](image-build.md). macOS: see [macOS guests](#macos-guests).

## 2. Profile

Add to `config.yaml` and `runnerctl config apply`:

```yaml
profiles:
  - name: ubuntu-24-gitlab
    provider: gitlab        # no `scope`: GitLab profiles have no GitHub scope
    image: ubuntu-24-gitlab
    lifecycle: ephemeral    # the only allowed value
    resources:
      cpu: 4
      memory: 8GiB
      disk: 16GiB
    limits:
      maxInstances: 2       # upper bound for this profile on this host
```

A GitLab profile may not set `scope`, `lifecycle: reusable`, or `warmPool` (see
[Troubleshooting](#troubleshooting)); pooling is gitlab-runner's `idle_count`. Check it:

```sh
runnerctl config validate config.yaml
runnerctl profile show ubuntu-24-gitlab    # provider: gitlab
```

## 3. Install the plugin

gitlab-runner finds `plugin = "runnervm"` by looking for an executable called
`fleeting-plugin-runnervm` on its `PATH` (or you can give an absolute path in `plugin`).

```sh
command -v fleeting-plugin-runnervm || {
  make -C GuestAgent build-plugin
  sudo install -m 0755 GuestAgent/dist/fleeting-plugin-runnervm-darwin-arm64 \
    /usr/local/bin/fleeting-plugin-runnervm
}
```

`runnerctl doctor --config config.yaml` warns (`gitlab_fleeting_plugin`) when a GitLab profile is
configured and the binary is missing from `PATH`, `/usr/local/bin` and `/opt/homebrew/bin`.

## 4. Create a runner token

In the GitLab UI: project **Settings > CI/CD > Runners > New project runner**. Tags: `runnervm`
(your choice), untick "Run untagged jobs" unless you want that. Copy the `glrt-...` token.

Or by API (token needs `create_runner`):

```sh
curl --request POST --header "PRIVATE-TOKEN: $PAT" "https://gitlab.com/api/v4/user/runners" \
  --data runner_type=project_type --data project_id=<id> \
  --data tag_list=runnervm --data run_untagged=false --data description=runnervm
```

Delete a runner you no longer use with `DELETE /api/v4/runners/:id` (needs `manage_runner`).

## 5. `config.toml`

One gitlab-runner manager per profile. Two managers on the same profile would each treat the
other's VMs as their own and fight over them.

### `instance` executor (job runs in the VM over SSH, Linux or macOS)

```toml
concurrent = 4
check_interval = 3

[[runners]]
  name = "runnervm-ubuntu-24-gitlab"
  url = "https://gitlab.com"
  token = "glrt-REPLACE_ME"
  executor = "instance"
  shell = "bash"

  [runners.autoscaler]
    plugin = "runnervm"
    capacity_per_instance = 1       # one job per VM
    max_use_count = 1               # VM is destroyed after one job
    max_instances = 2               # <= fleet.info maxInstances for the profile
    delete_instances_on_shutdown = true

    [runners.autoscaler.plugin_config]
      profile = "ubuntu-24-gitlab"                   # required
      socket = "/var/run/runnervm/runnerd.sock"      # default; dev daemon: /tmp/runnervm-<uid>/runnerd.sock
      lease = "10m"                                  # default; 1m..24h

    [runners.autoscaler.connector_config]
      os = "linux"                  # "darwin" for a macOS profile
      arch = "arm64"
      protocol = "ssh"
      username = "runner"
      timeout = "10m"

    [[runners.autoscaler.policy]]
      idle_count = 0                # scale to zero: a VM boots when a job arrives
      # Warm-pool variant: keep one VM booted. It holds that VM's CPU/memory/disk against the
      # host budget all the time and can starve GitHub profiles.
      # idle_count = 1
      # idle_time = "20m"
```

The `instance` executor needs `git` and `gitlab-runner` on the guest `PATH`; both images do.

### `docker-autoscaler` executor (Linux only; job runs in a container inside the VM)

Identical, except for the executor and a `[runners.docker]` table:

```toml
  executor = "docker-autoscaler"

  [runners.docker]
    image = "alpine:3.20"           # default image for jobs without `image:`
```

Docker runs in the guest, so each job gets a clean daemon and the VM is still destroyed after it.

### Field notes

- `max_instances` is gitlab-runner's own cap. Keep it at or below the profile's `maxInstances`
  and what the host can admit (the plugin reads `fleet.info` `maxInstances` at startup). Above
  that, `fleet.create` is refused by admission and the taskscaler retries; nothing breaks, jobs
  just wait.
- `delete_instances_on_shutdown` (plural "instances") must be `true` so stopping gitlab-runner
  releases its VMs at once instead of waiting for the lease.
- `use_static_credentials` is not supported: the plugin always generates a per-VM key.
- `lease` is renewed by the plugin while gitlab-runner is alive. It is the bound on how long a VM
  can outlive a crashed manager.

## 6. Run gitlab-runner

gitlab-runner must run as the daemon's user, not as an arbitrary account. `runnerd.sock` is 0600
and the daemon refuses any peer uid other than its own and root
(`Sources/runnerd/RunnerD.swift`). For the pkg/LaunchDaemon install that user is `_runnervm`.

Directory and config (`<state-dir>` is `/Library/Application Support/RunnerVM` in a production
layout):

```sh
sudo install -d -o _runnervm -g _runnervm -m 0700 \
  "/Library/Application Support/RunnerVM/gitlab-runner/work"
sudo install -o _runnervm -g _runnervm -m 0600 config.toml \
  "/Library/Application Support/RunnerVM/gitlab-runner/config.toml"
```

LaunchDaemon `/Library/LaunchDaemons/com.runnervm.gitlab-runner.plist` (adjust the
`gitlab-runner` path with `command -v gitlab-runner`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.runnervm.gitlab-runner</string>
    <key>UserName</key>
    <string>_runnervm</string>
    <key>GroupName</key>
    <string>_runnervm</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/gitlab-runner</string>
        <string>run</string>
        <string>--config</string>
        <string>/Library/Application Support/RunnerVM/gitlab-runner/config.toml</string>
        <string>--working-directory</string>
        <string>/Library/Application Support/RunnerVM/gitlab-runner/work</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>/Library/Application Support/RunnerVM/logs/gitlab-runner.log</string>
    <key>StandardErrorPath</key>
    <string>/Library/Application Support/RunnerVM/logs/gitlab-runner.log</string>
</dict>
</plist>
```

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/com.runnervm.gitlab-runner.plist
```

The log directory must already exist and be writable by `_runnervm`; launchd does not create it.
`PATH` must contain the directory holding `fleeting-plugin-runnervm`.

### Dev mode

With a dev daemon (`runnerd --foreground` as your user) the socket is
`/tmp/runnervm-<uid>/runnerd.sock`. Run gitlab-runner as the same user, with that socket in
`plugin_config`:

```sh
gitlab-runner run --config ./config.toml --working-directory ./work
```

## 7. Verify

```sh
runnerctl doctor --config config.yaml     # gitlab_fleeting_plugin: ok
runnerctl profile list                    # PROVIDER column shows gitlab
```

Push a pipeline whose job has `tags: [runnervm]`, then watch:

```sh
runnerctl vm list        # an instance with purpose fleet appears, boots, runs, is deleted
```

With `idle_count = 0` the list is empty again shortly after the job. The automated version of
this is `scripts/live-gitlab-e2e.sh` ([live-integration.md](live-integration.md#live-gitlab-e2e-scriptslive-gitlab-e2esh)).

## macOS guests

- Build the GitLab variant image: `scripts/provision-macos-tart.sh --gitlab-runner <ver>
  --gitlab-runner-sha256 <digest>` ([macos-guests.md](macos-guests.md#gitlab-variant-opt-in-sshd-on-key-only)).
  It turns on sshd (key-only) and records `capabilities.ssh` and `capabilities.gitlab`.
  `fleet.create` refuses a macOS profile whose image lacks ssh with `FLEET_IMAGE_NO_SSH`.
- At most 2 macOS guests run at once on a host (Apple's limit).
- `instance` executor only, `shell = "bash"`, `connector_config` `os = "darwin"`.
  `docker-autoscaler` needs Docker in the guest and is Linux only.

## Security

- Each VM gets its own ed25519 key, written to `~runner/.ssh/authorized_keys` by the daemon after
  boot. No key is baked into an image; sshd is key-only; images carry no `authorized_keys`.
- A VM runs exactly one job and is destroyed afterwards (`max_use_count = 1`). Nothing a job
  leaves behind reaches the next one.
- If gitlab-runner dies, the lease reaper deletes its VMs within `lease` (default 10 minutes),
  logged as `instance.fleetLeaseExpired`.
- Anyone who can open `runnerd.sock` controls the whole daemon, not just fleet VMs. That is why
  gitlab-runner has to run as `_runnervm` and why `config.toml` is 0600 in a directory owned by
  that user.
- Do not run the gitlab-runner manager with the host `shell` executor on this Mac, or any job
  could reach the socket and the host. Use only `instance` or `docker-autoscaler`, which run jobs
  in guests.
- The runner token in `config.toml` can pick up jobs for the project. Treat it as a secret and
  revoke the runner if it leaks.

## Troubleshooting

`runnerctl vm list`, the gitlab-runner log, and `runnerctl doctor` are the first stops.

| Code | Meaning / fix |
| --- | --- |
| `FLEET_PROFILE_NOT_GITLAB` | `plugin_config.profile` names a GitHub profile. Use a `provider: gitlab` profile. |
| `FLEET_LEASE_INVALID` | `lease` outside 1m..24h. |
| `FLEET_INSTANCE_NOT_FOUND` | The instance id is unknown; usually already reaped. |
| `FLEET_INSTANCE_NOT_FLEET` | The id belongs to a runner/maintenance instance. Do not manage those from gitlab-runner. |
| `FLEET_INSTANCE_NOT_READY` | `fleet.connect` before the VM is `idle`; the plugin retries. Persistent: check boot logs. |
| `FLEET_INVALID_PUBLIC_KEY` | Not a single `ssh-ed25519` line. Plugin bug or version mismatch; upgrade both. |
| `FLEET_NO_ADDRESS` | Guest has no usable IPv4 on the vmnet NAT. Check the guest booted and networking is up. |
| `FLEET_KEY_INSTALL_FAILED` | Daemon could not write `authorized_keys` through the guest agent. Check the image has the agent and a `runner` user. |
| `FLEET_IMAGE_NO_SSH` | macOS image without `capabilities.ssh`. Build the GitLab variant. |
| `FLEET_USE_FLEET_API` | Someone called `instance.create` with `purpose: fleet`. Use `fleet.create`. |

Config validation (`runnerctl config validate`):

| Code | Fix |
| --- | --- |
| `PROFILE_GITLAB_SCOPE_UNSUPPORTED` | Remove `scope` from the profile. |
| `PROFILE_GITLAB_EPHEMERAL_ONLY` | Set `lifecycle: ephemeral`. |
| `PROFILE_GITLAB_WARM_POOL_UNSUPPORTED` | Remove `warmPool`; use `idle_count` in `[[runners.autoscaler.policy]]`. |

Other symptoms:

- Job waits forever: `runnerctl status` shows host capacity exhausted, or `max_instances` is 0 in
  effect. Admission refusals (draining, disk pressure, capacity) show in the gitlab-runner log as
  failed instance creates.
- `permission denied` on the socket: gitlab-runner is not running as `_runnervm` (or root).
- `plugin "runnervm" not found`: the binary is not on gitlab-runner's `PATH`; fix the plist
  `PATH` or give an absolute path in `plugin`.
- SSH timeouts to the guest: the `connector_config` `timeout` is shorter than the image's boot, or
  the guest has no address (`FLEET_NO_ADDRESS`).

## Limits

- No Suspend/Resume: instances are created, used once, deleted.
- `use_static_credentials` is not supported.
- Ephemeral only; no reusable VMs, no warm pool in RunnerVM (use `idle_count`).
- GitLab VMs are counted against the host budget but never appear as GitHub demand.
- One gitlab-runner manager per profile.
