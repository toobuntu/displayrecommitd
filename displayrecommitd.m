/*
 * SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

// displayrecommitd — macOS LaunchAgent to recover an external USB-C display
// that goes black shortly after wake when the built-in display is suppressed.
//
// Background:
//   With a USB-C external display connected via an HDMI or DisplayPort adapter
//   and the built-in display suppressed (e.g. by blackoutd, BetterDisplay, or
//   Lunar), waking from sleep produces a black external display with only a
//   mouse cursor visible. The failure does not happen immediately on wake —
//   the display comes up briefly, then drops approximately 30 seconds later.
//
//   USB-C Alt Mode (Alternate Mode) is a USB-C specification feature that
//   repurposes some of the connector's wire pairs to carry DisplayPort or HDMI
//   signals. On wake, when the built-in display is suppressed and the USB-C
//   adapter is the sole display path, the USB-C controller drops its Alt Mode
//   negotiation state approximately 30 seconds after wake. WindowServer
//   registers this as a hotplug-out event (the display physically disconnects
//   at the protocol level) and does not automatically recover it.
//
//   The result: the display goes black with only a hardware cursor visible.
//   The cursor works because it is a GPU scanout plane overlay programmed
//   directly into hardware registers, independent of the display pipeline.
//
// Fix:
//   A no-op CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration
//   transaction forces WindowServer to re-evaluate the display configuration
//   graph after the pipeline has resettled. By the time the quiet timer fires
//   (2 seconds after the last pipeline event), Alt Mode has re-established and
//   the display has re-enumerated. The CGConfig cycle causes WindowServer to
//   properly absorb the reconnected display. No visible flicker, no display
//   power cycle required.
//
// Trigger:
//   Any user wake. The battery-at-sleep condition previously used here was
//   coincidental — the Alt Mode dropout occurs regardless of power source when
//   the built-in is suppressed. The CGConfig transaction is a no-op when no
//   dropout has occurred, so firing on every wake is safe.
//
//   blackoutd, which knows whether it has suppressed the built-in, is the
//   topology-aware implementation of this fix. displayrecommitd is a
//   standalone fallback for systems running other display suppression tools.
//
// Trigger timing:
//   CGDisplayRegisterReconfigurationCallback fires for every display pipeline
//   event. On wake, a 2-second quiet timer is armed and resets on each event.
//   The recommit fires only after 2 seconds pass with no further events.
//   This ensures the display has re-enumerated after the Alt Mode dropout
//   before the CGConfig cycle fires. Firing during active churn produces no
//   benefit. Pipeline churn has been observed to last up to ~14 seconds.
//
//   There is no public API that definitively signals pipeline settled; the
//   quiet period is the correct approach at the public API level.
//
// Scope:
//   Tested on MacBook Air with Dell SP2309W via USB-C→HDMI, macOS 26 Tahoe,
//   with built-in display suppressed by blackoutd.
//   Likely affects any Mac with a USB-C external display as the sole active
//   display (built-in suppressed by any means).
//   A separate but symptomatically similar failure has been reported with
//   BetterDisplay virtual displays; that failure may have a different cause.
//
// Compile:
//   clang -fobjc-arc -framework Cocoa \
//         -o displayrecommitd displayrecommitd.m
//
// Install:
//   sudo install -m 755 displayrecommitd /usr/local/bin/
//   cp io.github.toobuntu.displayrecommitd.plist ~/Library/LaunchAgents/
//   launchctl bootstrap gui/$(id -u) \
//     ~/Library/LaunchAgents/io.github.toobuntu.displayrecommitd.plist

#import <Cocoa/Cocoa.h>

static const NSTimeInterval kQuietInterval = 2.0;

// MARK: - Recommit

// Forces WindowServer to re-evaluate the display configuration graph after
// the display pipeline has resettled following a USB-C Alt Mode dropout.
// Returns YES on success.
static BOOL recommitDisplayConfiguration(void) {
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess)
        return NO;
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
}

// MARK: - Reconfig Callback

static void reconfigCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags,
                             void *userInfo);

// MARK: - Agent

@interface Agent : NSObject
- (void)displayReconfigured;
@end

@implementation Agent {
    BOOL _recommitPending;
    NSTimer *_quietTimer;
}

- (instancetype)init {
    if (!(self = [super init]))
        return nil;
    CGDisplayRegisterReconfigurationCallback(reconfigCallback, (__bridge void *)self);
    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserver:self
           selector:@selector(systemWillSleep:)
               name:NSWorkspaceWillSleepNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(systemDidWake:)
               name:NSWorkspaceDidWakeNotification
             object:nil];
    return self;
}

- (void)dealloc {
    CGDisplayRemoveReconfigurationCallback(reconfigCallback, (__bridge void *)self);
}

- (void)systemWillSleep:(NSNotification *)note {
    [self cancelRecommit];
    NSLog(@"[sleep]");
}

- (void)systemDidWake:(NSNotification *)note {
    NSLog(@"[wake] arming recommit");
    [self armRecommit];
}

- (void)displayReconfigured {
    if (!_recommitPending)
        return;
    [_quietTimer invalidate];
    _quietTimer = [NSTimer scheduledTimerWithTimeInterval:kQuietInterval
                                                   target:self
                                                 selector:@selector(quietTimerFired)
                                                 userInfo:nil
                                                  repeats:NO];
}

- (void)armRecommit {
    _recommitPending = YES;
    [_quietTimer invalidate];
    _quietTimer = [NSTimer scheduledTimerWithTimeInterval:kQuietInterval
                                                   target:self
                                                 selector:@selector(quietTimerFired)
                                                 userInfo:nil
                                                  repeats:NO];
}

- (void)cancelRecommit {
    _recommitPending = NO;
    [_quietTimer invalidate];
    _quietTimer = nil;
}

- (void)quietTimerFired {
    _quietTimer = nil;
    _recommitPending = NO;
    BOOL ok = recommitDisplayConfiguration();
    NSLog(@"[recommit] CGCompleteDisplayConfiguration %s", ok ? "succeeded" : "failed");
}

@end

static void reconfigCallback(CGDirectDisplayID display __unused, CGDisplayChangeSummaryFlags flags,
                             void *userInfo) {
    if (flags & kCGDisplayBeginConfigurationFlag)
        return;
    [(__bridge Agent *)userInfo displayReconfigured];
}

// MARK: - Entry Point

int main(void) {
    @autoreleasepool {
        NSLog(@"[start] displayrecommitd starting");
        __unused Agent *agent = [[Agent alloc] init];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp run];
    }
    return 0;
}
