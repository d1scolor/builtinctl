# builtinctl

`builtinctl` is a small macOS command-line utility that logically disables the built-in Mac display while an external display is active, then restores it when the last external display disappears. It does not fake this with brightness or screen blanking.

> **Important:** builtinctl uses the undocumented macOS private symbol `CGSConfigureDisplayEnabled`. It may break after a macOS update, has no compatibility guarantee from Apple, and is unsuitable for Mac App Store distribution. Test it after major macOS upgrades.

## Install

The supported binary release currently targets Apple Silicon and macOS 13 or later. It does not require Xcode or the Xcode Command Line Tools:

```sh
brew install d1scolor/tap/builtinctl
```

Then keep an external display attached and follow the safe first-run procedure below before enabling automatic startup.

## Build from source

- macOS 13 or later
- Apple Silicon is the initial target
- Xcode Command Line Tools / Swift 5.9+

```sh
swift build -c release
.build/release/builtinctl status
```

No root access, network service, telemetry, or third-party runtime dependencies are used.

## Commands

```text
builtinctl status   show display, automation, and private API state
builtinctl on       logically enable the built-in display
builtinctl off      disable it (refuses unless an external display is active)
builtinctl auto     run automatic switching in the foreground
builtinctl suspend  activate the kill switch and immediately restore the panel
builtinctl recover  alias for suspend, intended for emergency recovery
builtinctl resume   remove the kill switch and explicitly re-arm a running daemon
builtinctl watch    print CoreGraphics display events without changing displays
builtinctl test-off safely test disable with a 15-second confirmation timeout
builtinctl install-agent   install and start a suspended per-user LaunchAgent
builtinctl restart-agent   safely restart on the current CLI, preserving suspension
builtinctl uninstall-agent restore, suspend, and remove the LaunchAgent
builtinctl purge           restore, remove automation, configuration, and logs
```

Automatic mode first attempts to enable the panel and enforces a 60-second startup recovery window. An explicit `resume` re-arms a running daemon immediately, clearing the remaining startup grace and any reconnect latch. Automatic mode then uses CoreGraphics callbacks with a two-second safety watchdog. All changes are session-only; logout or restart should discard them. `SIGINT`, `SIGTERM`, `SIGHUP`, and `SIGQUIT` restore the built-in display before exit.

Automatic mode keeps its event loop isolated from private display mutations. Each transition runs through a short-lived internal helper with a five-second timeout and a cross-process mutation lock. Disabling requires a freshly confirmed active external display, a durable built-in recovery ID, and an inactive kill switch. These conditions are checked again after beginning the transaction and immediately before the private call. The helper verifies the result and reverses an unsafe post-condition. After automatic restoration, a recovery latch prevents another disable until an absent external and subsequent reconnect have both been observed.

On macOS 26, unplugging the last USB-C/DisplayPort Alt Mode monitor while the built-in is logically disabled creates a synthetic active CoreGraphics display. Its vendor is `756e6b6e` (`unkn`) and model is `76697274` (`virt`); its display ID is not stable. Enumeration excludes only that exact vendor/model identity. This allows the lightweight CoreGraphics watchdog to detect removal without `system_profiler` polling.

The last verified built-in display ID is cached at `~/.config/builtinctl/builtin-display-id`. CoreGraphics removes a logically disabled panel from its online inventory, so this validated ID lets a later `builtinctl on` process find it again. The cached value is used only while `CGDisplayIsBuiltin` still confirms it is a built-in display.

## Crash recovery

Before any disable, builtinctl durably writes:

```text
~/.config/builtinctl/builtin-disabled
```

The marker includes the kernel boot time and macOS audit login-session ID. It is removed only after the built-in is verified active. The LaunchAgent restarts only after an unsuccessful exit.

If a restarted process finds a marker from the same boot and login session, it restores the panel, creates a crash suspension carrying the same session identity, and requires an explicit `builtinctl resume`. This prevents an in-session crash loop. If the marker or crash suspension belongs to an earlier boot or login session, the process restores the panel and automatically resumes after the normal 60-second startup grace. A legacy, corrupt, or unverifiable marker takes the conservative same-session path. An existing user-created suspension always remains in force.

Only one `auto` process may hold the automation lock. All display mutations also share a separate lock, preventing a late `off` helper from racing crash recovery. The watchdog uses CoreGraphics' public online/asleep state to distinguish a connected sleeping external from a physical unplug. A dispatch-based IOKit power watcher pauses topology mutations as soon as macOS proposes idle sleep, acknowledges sleep immediately, and keeps automation paused until hardware has completed waking. AppKit workspace notifications remain as a secondary display-sleep signal. After a completed wake, automatic mode restores the built-in and starts a fresh 15-second recovery window.

## Safe first run

Keep an external display attached and verify each step:

```sh
builtinctl status
builtinctl test-off
builtinctl auto
```

Confirm that unplugging the external display and pressing Ctrl-C both restore the panel. Automatic mode honors the persistent kill switch at `~/.config/builtinctl/disabled`.

## Install automatic startup

After hardware testing:

```sh
builtinctl install-agent
```

This installs a persistent launcher and fallback executable under `~/Library/Application Support/builtinctl/bin`, installs `~/Library/LaunchAgents/io.github.builtinctl.auto.plist`, and bootstraps it. When installed through Homebrew, the launcher records Homebrew's stable `opt` path and creates a private versioned runtime copy at each daemon start. Installation first restores the built-in and creates the suspension sentinel, so switching is not silently enabled. Explicitly opt in with:

```sh
builtinctl resume
```

Logs are written under `~/Library/Logs/builtinctl`. The agent uses conditional `KeepAlive` with `SuccessfulExit=false`, not unconditional restart.

## Upgrade

The running daemon is not interrupted during a Homebrew upgrade. At its next start—such as the next login or reboot—the persistent launcher automatically snapshots and runs the current Homebrew version. No agent reinstall is required:

```sh
brew upgrade builtinctl
builtinctl status
```

To apply an update immediately, safely restore and restart the agent while preserving whether automation is enabled or suspended:

```sh
builtinctl restart-agent
```

Agents installed before version 0.1.4 require one final `restart-agent` to migrate their executable and LaunchAgent configuration. Subsequent Homebrew upgrades apply automatically at the next daemon start. `status` reports the CLI version, running agent version, and whether an update is pending.

## Recovery

Normally, run either:

```sh
builtinctl suspend
builtinctl recover
```

Both commands create the kill switch and immediately attempt restoration. If an external is available, reconnect it and run either command. If necessary, log out or restart; configuration is committed only for the current session. Remove the managed LaunchAgent with:

```sh
builtinctl uninstall-agent
```

As a last resort from macOS Recovery, remove the user's builtinctl LaunchAgent from the Data volume before logging in again.

## Uninstall

`brew uninstall builtinctl` removes only the Homebrew-managed CLI. It does not unload a separately installed LaunchAgent or remove builtinctl's per-user files.

To remove automation while retaining the suspension sentinel and logs for a possible reinstall:

```sh
builtinctl uninstall-agent
brew uninstall builtinctl
```

For complete removal, including configuration and logs:

```sh
builtinctl purge
brew uninstall builtinctl
```

`purge` permanently deletes builtinctl's per-user state and logs. It first suspends automation and verifies that the built-in display is active, then unloads the LaunchAgent and removes its plist, copied executable, configuration, and logs. If restoration or agent removal fails, purge stops before deleting the remaining safety state.

If Homebrew was uninstalled first, the LaunchAgent's safety copy normally remains available:

```sh
"$HOME/Library/Application Support/builtinctl/bin/builtinctl" purge
```

If that executable is absent or is an older version without `purge`, reinstall the CLI and complete cleanup in the safe order:

```sh
brew install d1scolor/tap/builtinctl
builtinctl purge
brew uninstall builtinctl
```

## Testing

```sh
swift test
```

Display mutation requires real hardware testing; the fail-open policy is covered by unit tests.
