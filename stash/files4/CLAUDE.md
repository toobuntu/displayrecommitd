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

macOS fails to re-attach the WindowServer compositor surface to a USB-C external
display after battery sleep.
CoreGraphics and IOKit report the display as fully healthy, but window content does not render.
The hardware cursor works because it is a GPU scanout plane overlay independent of the compositor surface.

## Fix

A no-op CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration transaction
forces WindowServer to recommit its display configuration graph,
re-allocating compositor surfaces against the current pipeline.
No display sleep required, no visible flicker.

## Trigger conditions

Both must be true:
1. isOnBattery() returns YES at NSWorkspaceWillSleepNotification
2. isOnBattery() returns YES at NSWorkspaceDidWakeNotification

Clamshell state is NOT checked.
The process is suspended during sleep and cannot detect whether the lid was closed mid-sleep.
Battery at both endpoints covers all observed repro paths and is harmless on clean wakes.
The trigger conditions are not fully characterized — the failure is not consistently
reproducible even under the suspected conditions (battery sleep, clamshell closed during sleep).

## Trigger timing

After qualifying wake, arm a 2s quiet timer reset by every
CGDisplayReconfigurationCallback event (excluding kCGDisplayBeginConfigurationFlag).
Fire recommit only after 2s of no events.
Display ID churn can last up to ~14s; firing mid-churn is ineffective.
No public API definitively signals pipeline settled; quiet period is correct at the public API level.

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
- pmset displaysleepnow also recovers the display but causes visible flicker;
  CGConfig no-op is preferable and sufficient
- Reproduced: MacBook Pro + Dell SP2309W via USB-C→HDMI, macOS 26 Tahoe, battery
- Not consistently reproduced on AC power
- Root cause hypothesis: USB-C Alt Mode renegotiation on battery wake leaves a
  stale compositor surface binding that CGConfig recommit clears; AC power-gating
  is less aggressive so the pipeline instance survives sleep

---

## Setup

### First-time repo setup

```sh
git clone git@github.com:toobuntu/displayrecommitd.git
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

For Objective-C files (requires explicit `--style=c`):

```sh
git ls-files -- '*.m' '*.h' | \
  xargs reuse annotate --style=c \
    --copyright="2026 toobuntu" \
    --license=GPL-3.0-or-later \
    --copyright-prefix=spdx-string \
    --merge-copyrights
```

For all other file types (comment style auto-detected):

```sh
git ls-files -- <pattern> | \
  xargs reuse annotate \
    --copyright="2026 toobuntu" \
    --license=GPL-3.0-or-later \
    --copyright-prefix=spdx-string \
    --merge-copyrights \
    --fallback-dot-license
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
