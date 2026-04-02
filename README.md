<!--
SPDX-FileCopyrightText: Copyright 2026 Todd Schulman

SPDX-License-Identifier: GPL-3.0-or-later
-->

# displayrecommitd

[![standard-readme compliant](https://img.shields.io/badge/readme%20style-standard-brightgreen.svg?style=flat-square)](https://github.com/RichardLitt/standard-readme)

Recovers an external USB-C display that goes black after wake when the built-in display is suppressed.

A no-op `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` transaction
forces WindowServer to re-evaluate the display configuration graph after the pipeline resettles,
recovering the display without visible flicker or a display power cycle.

## Table of Contents

- [Background](#background)
- [Install](#install)
- [Usage](#usage)
- [When it fires](#when-it-fires)
- [Timing](#timing)
- [Scope and known limitations](#scope-and-known-limitations)
- [License](#license)

## Background

With a USB-C external display connected via an HDMI or DisplayPort adapter,
and the built-in display suppressed by a tool such as blackoutd, BetterDisplay, or Lunar,
waking from sleep produces a black external display with only a mouse cursor visible.

The failure does not happen immediately on wake.
The display comes up briefly, then drops approximately 30 seconds later.
The cursor remains functional because it is a hardware overlay driven directly by the GPU
scanout engine, independent of the display pipeline.

The cause is a USB-C Alt Mode negotiation dropout.
Alt Mode is a USB-C specification feature that repurposes some of the connector's wire pairs
to carry DisplayPort or HDMI signals.
When the built-in display is suppressed and the USB-C adapter is the sole display path,
the USB-C controller drops its Alt Mode negotiation state approximately 30 seconds after wake.
WindowServer registers this as a hotplug-out event and does not automatically recover it.

By the time the quiet timer fires (2 seconds after the last pipeline event),
Alt Mode has re-established and the display has re-enumerated.
The CGConfig cycle causes WindowServer to properly absorb the reconnected display.

### Manual workaround

Physically unplugging and replugging the USB-C cable recovers the display.
Moving the cursor to a display-sleep hot corner usually also recovers it —
the resulting display sleep/wake cycle appears to cause the same pipeline re-evaluation.

## Install

Requires Xcode Command Line Tools to build; no build tools are required at runtime.

```sh
xcode-select --install   # if not already installed
make
make install
```

## Usage

displayrecommitd runs as a LaunchAgent and requires no interaction after installation.
Logs go to the system log via `NSLog`.

```sh
# Live stream
log stream --predicate 'process == "displayrecommitd"'

# After a sleep/wake
log show --last 5m --predicate 'process == "displayrecommitd"'
```

On every wake:

```
[sleep]
[wake]     arming recommit
[recommit] CGCompleteDisplayConfiguration succeeded
```

To uninstall:

```sh
make uninstall
```

To also remove any log file if you configured one:

```sh
make zap
```

## When it fires

The recommit arms on every user wake, regardless of power source.
The CGConfig transaction is a no-op when no Alt Mode dropout has occurred,
so firing unconditionally is safe.

If you use blackoutd to suppress the built-in display,
blackoutd provides a topology-aware implementation of the same fix —
it knows whether the built-in was suppressed at sleep time and fires accordingly.
displayrecommitd is a standalone fallback for systems using other display suppression tools.

## Timing

On wake, a 2-second quiet timer arms and resets on every `CGDisplayReconfigurationCallback` event.
The recommit fires only once the display pipeline has been quiet for 2 seconds.
This ensures the Alt Mode dropout and re-establishment have completed before the CGConfig cycle fires.
Firing during active pipeline churn produces no benefit.
Pipeline churn has been observed to last up to ~14 seconds after wake.

There is no public API that definitively signals pipeline settled;
the quiet period is the correct approach at the public API level.

## Scope and known limitations

Tested on MacBook Air with Dell SP2309W via USB-C→HDMI, macOS 26 Tahoe,
with built-in display suppressed by blackoutd.

Likely affects any Mac with a USB-C external display as the sole active display,
with the built-in suppressed by any means.
Power source does not appear to affect whether the failure occurs.

A symptomatically similar failure has been reported with BetterDisplay virtual displays
on an iMac; that failure may have a different cause and is not confirmed to be addressed
by this tool.

If you reproduce this on other hardware or connection types,
please open an issue with your Mac model, macOS version, display connection type, and a log.

## License

[GPL-3.0-or-later](LICENSES/GPL-3.0-or-later.txt) © 2026 toobuntu
