<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# displayrecommitd

A macOS LaunchAgent that recovers an external display after battery sleep.

## Problem

On macOS, when a MacBook sleeps on battery power with a USB-C connected external
display (via HDMI or DisplayPort adapter), the USB-C controller is power-gated
more aggressively than on AC power. This causes the adapter to lose its Alt Mode
negotiation state.

**USB-C Alt Mode** (Alternate Mode) is a USB-C specification feature that allows
the connector to carry non-USB signals — DisplayPort, HDMI — by repurposing some
of its wire pairs. A USB-C→HDMI or USB-C→DP adapter relies on Alt Mode to route
display signals through the USB-C port. The more aggressive battery power-gating
drops this negotiation state during sleep.

On wake, the display re-enumerates cleanly through IOKit, and CoreGraphics reports
it as fully active and healthy. But WindowServer's compositor surface fails to
re-attach to the new display pipeline instance.

The result is a display that wakes to a **black screen with a functioning mouse
cursor**. The cursor works because it is a GPU scanout plane overlay programmed
directly into hardware registers, independent of the compositor surface pipeline.
Window content does not render because WindowServer is not painting to the display,
despite believing it is.

### Manual workaround (without this tool)

Moving the cursor to a display-sleep hot corner recovers the display. This triggers
a display sleep/wake cycle that forces WindowServer to detach and reattach the
compositor surface, which succeeds on the second attempt.

### Fix

A no-op `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration`
transaction forces WindowServer to recommit its display configuration graph,
re-allocating compositor surfaces against current pipeline instances. This
recovers the display with no visible flicker and no display power cycle required.

## Conditions

The recommit fires when battery power is present at both sleep and wake time.

Closing the lid can initiate sleep, or sleep can be initiated by other means
(menu, inactivity timeout, `pmset sleepnow`) with the lid closed during sleep.
There is no way to detect whether the lid was closed mid-sleep: the process is
suspended during sleep and cannot receive notifications or poll IOKit. The trigger
condition is therefore battery at sleep + battery at wake, which is correct and
sufficient for all observed repro paths. The recommit transaction is a no-op on
clean wakes — it costs nothing when the compositor surface is already healthy.

## Trigger Timing

After a qualifying wake, the agent arms a 2-second quiet timer that resets on
every `CGDisplayReconfigurationCallback` event. The recommit fires only after
2 seconds pass with no further display configuration events, ensuring the display
pipeline has fully settled first. Firing mid-churn (during display ID reassignment
cycles) produces no benefit.

Display pipeline churn after wake has been observed to last up to ~14 seconds.
There is no public API that definitively signals pipeline settled; the quiet period
is the correct approach at the public API level.

## Scope

Tested on MacBook Pro with Dell SP2309W via USB-C→HDMI, macOS 26 Tahoe.

Likely affects any Mac with a USB-C connected external display on battery sleep.
The failure has also been observed once on AC power but cannot be consistently
reproduced.

If you can reproduce this on other hardware configurations, please open an issue
with your Mac model, macOS version, display connection type, and a
`displayrecommitd` log.

## Logging

Logs are written via `NSLog` to the system log. Read them with:

```sh
log stream --predicate 'process == "displayrecommitd"'
# or after a sleep/wake:
log show --last 5m --predicate 'process == "displayrecommitd"'
```

Example qualifying wake:

```
[start] displayrecommitd starting
[sleep] battery=yes
[wake]  battery_sleep=yes battery_wake=yes — arming recommit
[recommit] CGCompleteDisplayConfiguration succeeded
```

Example non-qualifying wake (AC power at sleep or wake):

```
[sleep] battery=no
[wake]  battery_sleep=no battery_wake=yes
```

## Requirements

- macOS 10.14 or later
- Xcode command-line tools (`xcode-select --install`)

## Install

```sh
make
make install
```

## Uninstall

```sh
make uninstall
```

## License

GPLv3 or later. See [COPYING](COPYING).
