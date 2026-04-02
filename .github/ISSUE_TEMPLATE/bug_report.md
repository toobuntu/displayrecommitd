---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

name: Bug report
about: Report a display compositor failure or unexpected behavior
---

**Run these commands immediately after the issue occurs and paste the output:**

```sh
system_profiler SPHardwareDataType SPDisplaysDataType -detailLevel mini
sw_vers
uname -m
pmset -g log | grep -E "Sleep|Wake|Clamshell" | tail -30
log show --last 5m --predicate 'process == "displayrecommitd"'
```

**Describe what happened**

<!-- What you observed — black screen, cursor visible, how you recovered it -->

**Display connection type**

<!-- e.g. USB-C→HDMI adapter, native Thunderbolt, DisplayPort cable -->

**Was displayrecommitd running at the time?**

<!-- Check: launchctl print gui/$(id -u)/io.github.toobuntu.displayrecommitd -->
