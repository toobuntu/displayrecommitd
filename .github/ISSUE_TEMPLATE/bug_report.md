---
# SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
#
# SPDX-License-Identifier: GPL-3.0-or-later

name: Bug report
about: Report a display compositor failure or unexpected behavior
---

**Mac model and macOS version**

<!-- e.g. MacBook Pro 14-inch 2023, macOS 15.3 -->

**Display and connection type**

<!-- e.g. Dell U2722D via USB-C→DisplayPort adapter, or native Thunderbolt -->

**Power source at sleep and wake**

<!-- e.g. battery at sleep, battery at wake -->

**Steps to reproduce**

<!-- What you did before the failure appeared -->

**Log output**

```
log show --last 5m --predicate 'process == "displayrecommitd"'
```

<!-- Paste output here -->
