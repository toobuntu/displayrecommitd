<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# displayrecommitd — project memory

## What this is

Single-file Objective-C LaunchAgent.
No Xcode project.
Builds with clang directly.

## Problem being solved

With a USB-C external display connected via an HDMI or DisplayPort adapter and the
built-in display suppressed, waking from sleep produces a black external display with
only a mouse cursor visible. The display comes up briefly on wake, then drops ~30 seconds
later due to a USB-C Alt Mode negotiation dropout. WindowServer registers this as a
hotplug-out event and does not automatically recover it.

## Fix

A no-op CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration transaction forces
WindowServer to re-evaluate the display configuration graph after the pipeline resettles.
By the time the quiet timer fires, Alt Mode has re-established and the display has
re-enumerated. The CGConfig cycle causes WindowServer to properly absorb the reconnected
display. No visible flicker, no display power cycle required.

## Trigger

Every user wake. The battery-at-sleep condition previously used was coincidental —
the Alt Mode dropout occurs regardless of power source when the built-in is suppressed.
The CGConfig transaction is a no-op when no dropout has occurred, so firing
unconditionally on every wake is safe.

blackoutd is the topology-aware implementation: it knows whether the built-in was
suppressed at sleep time. displayrecommitd is the standalone fallback for systems
using other display suppression tools (BetterDisplay, Lunar, etc.).

## Trigger timing

On wake, arm a 2s quiet timer reset by every CGDisplayReconfigurationCallback event
(excluding kCGDisplayBeginConfigurationFlag).
Fire recommit only after 2s of no events — by this point Alt Mode has re-established
and the display has re-enumerated.
Pipeline churn can last up to ~14s; firing mid-churn produces no benefit.
No public API definitively signals pipeline settled; quiet period is correct.

## Key files

- displayrecommitd.m — entire implementation
- io.github.toobuntu.displayrecommitd.plist — LaunchAgent plist
- Makefile — build, install, uninstall targets
- .githooks/pre-commit — local dev hook (see Setup below)

## Logging

Via NSLog → system log (no log file).

```sh
log show --last 5m --predicate 'process == "displayrecommitd"'
log stream --predicate 'process == "displayrecommitd"'
```

## Research notes

- displayprobe.m (in blackoutd repo) was the diagnostic tool used to characterise
  the problem; it is not part of this project
- Physical unplug/replug of USB-C cable also recovers the display (confirms Alt Mode dropout)
- pmset displaysleepnow also recovers the display but causes visible flicker
- Reproduced: MacBook Air + Dell SP2309W via USB-C→HDMI, macOS 26 Tahoe,
  built-in suppressed by blackoutd, battery and AC power
- WindowServer log confirms: Display 2 (Dell) hotplug-out fires ~34 seconds after wake,
  followed by virtual display churn as blackoutd responds; CGConfig cycle after churn
  settles recovers the display
- Third-party report with similar symptoms: BetterDisplay virtual display active
  (see https://github.com/waydabber/BetterDisplay/discussions/5161);
  cause may differ — unconfirmed whether displayrecommitd addresses it
- Battery condition was coincidental: usage pattern of sleeping on battery with
  external connected and built-in suppressed happened to correlate with battery power

---

## Setup

### First-time repo setup

```sh
gh repo create toobuntu/displayrecommitd \
  --public \
  --description "Recommits external display compositor after battery sleep on macOS" \
  --clone
cd displayrecommitd
```

Configure git to use the tracked hooks directory:

```sh
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

Install build and lint tools:

```sh
xcode-select --install          # clang, xcrun clang-format, plutil
brew install reuse actionlint
```

### License file

`COPYING` is a hard link to `LICENSES/GPL-3.0-or-later.txt`:

```sh
ln LICENSES/GPL-3.0-or-later.txt COPYING
```

A hard link is used rather than a symlink because GitHub's license detection reads file
content directly and does not follow symlinks — the symlink target path string is not
a valid license text.
Both paths refer to the same inode, so there is no drift.
Git does not preserve hard links; on clone both files are independent copies with
identical content, which is acceptable for a license file that never changes.

### REUSE annotation

When adding new files, annotate before committing.
The pre-commit hook will catch unannotated files and print the correct command.

To annotate all non-compliant files (two passes: Objective-C requires `--style=c`,
other files use auto-detection with `--fallback-dot-license` for unknown extensions):

```sh
files=$(reuse lint --json \
  | jq -r '.non_compliant
    | add(.missing_copyright_info, .missing_licensing_info)
    | unique[]')

[ -z "$files" ] && exit 0

annotate() {
    xargs -r reuse annotate \
        --copyright="2026 toobuntu" \
        --merge-copyrights \
        --license=GPL-3.0-or-later \
        --copyright-prefix=spdx-string \
        "$@"
}

printf '%s\n' "$files" | grep -E '\.(m|h)$'  | annotate --style=c
printf '%s\n' "$files" | grep -vE '\.(m|h)$' | annotate --fallback-dot-license
```

To download or refresh the license text:

```sh
reuse download --all
```

---

## Maintenance

### Updating the binary

```sh
make clean
make
make reinstall   # boots out running agent, installs, re-bootstraps
```

### Checking REUSE compliance

```sh
reuse lint
```

### Verifying the installed agent

```sh
launchctl print gui/$(id -u)/io.github.toobuntu.displayrecommitd
```

### Removing everything

```sh
make zap   # unloads agent, removes binary, plist, and any log file
```
