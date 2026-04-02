/*
 * SPDX-FileCopyrightText: Copyright 2026 Todd Schulman
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

// displayrecommitd — macOS LaunchAgent to recover external display rendering
// after battery sleep.
//
// Background:
//   On macOS, when a MacBook sleeps on battery power with a USB-C connected
//   external display (via HDMI or DisplayPort adapter), the USB-C controller
//   is power-gated more aggressively than on AC power. This causes the
//   adapter to lose its Alt Mode negotiation state.
//
//   USB-C Alt Mode (Alternate Mode) is a USB-C specification feature that
//   allows the connector to carry non-USB signals — DisplayPort, HDMI — by
//   repurposing some of its wire pairs. A USB-C→HDMI adapter uses Alt Mode
//   to route display signals through the USB-C port. The battery-vs-AC
//   difference in power-gating causes this negotiation to be dropped more
//   aggressively on battery sleep.
//
//   On wake, the display re-enumerates cleanly — CoreGraphics and IOKit
//   report it as fully active and healthy — but WindowServer's compositor
//   surface fails to re-attach to the new display pipeline instance.
//
//   The result: the display wakes to a black screen with a fully functional
//   hardware cursor. The cursor works because it is a GPU scanout plane
//   overlay programmed directly into hardware registers, independent of
//   the compositor surface. Window content does not render because
//   WindowServer is not painting to the display, despite believing it is.
//
// Fix:
//   A no-op CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration
//   transaction forces WindowServer to recommit its display configuration
//   graph, re-allocating the compositor surface against the current pipeline
//   instance. This recovers the display with no visible flicker and no
//   display power cycle required.
//
// Trigger conditions:
//   Battery power at sleep time and battery power at wake time.
//
//   Closing the lid can initiate sleep, or sleep can be initiated by other
//   means (menu, pmset, inactivity timeout) with the lid closed afterward.
//   There is no way to detect mid-sleep lid state: the process is suspended
//   during sleep and cannot receive notifications or poll IOKit. The
//   clamshell condition is therefore not checked — triggering on battery
//   at both endpoints is sufficient and covers all lid-closure variants.
//   The recommit transaction is cheap and silent on clean wakes.
//
// Trigger timing:
//   CGDisplayRegisterReconfigurationCallback fires for every display pipeline
//   event. After a qualifying wake, a 2-second quiet timer is armed and
//   resets on each event. The recommit fires only after 2 seconds pass with
//   no further events, ensuring the display pipeline has fully settled.
//   Firing mid-churn (during display ID reassignment) produces no benefit.
//   Display pipeline churn has been observed to last up to ~14 seconds.
//
//   There is no public API that definitively signals pipeline settled; the
//   quiet period is the correct approach at the public API level. A deeper
//   signal would require private IOKit display service APIs.
//
// Scope:
//   Tested on MacBook Pro with Dell SP2309W via USB-C→HDMI, macOS 26 Tahoe.
//   Likely affects any Mac with a USB-C connected external display on battery
//   sleep. The AC power case has been observed once but cannot be consistently
//   reproduced; the battery condition may not catch it.
//
// Compile:
//   clang -fobjc-arc -framework Cocoa -framework IOKit \
//         -o displayrecommitd displayrecommitd.m
//
// Install:
//   sudo install -m 755 displayrecommitd /usr/local/bin/
//   cp io.github.toobuntu.displayrecommitd.plist ~/Library/LaunchAgents/
//   launchctl bootstrap gui/$(id -u) \
//     ~/Library/LaunchAgents/io.github.toobuntu.displayrecommitd.plist

#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/ps/IOPowerSources.h>

static const NSTimeInterval kQuietInterval = 2.0;

// MARK: - System State

static BOOL isOnBattery(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info)
        return NO;
    CFStringRef source = IOPSGetProvidingPowerSourceType(info);
    BOOL result = source && [(__bridge NSString *)source isEqualToString:@kIOPSBatteryPowerValue];
    CFRelease(info);
    return result;
}

// MARK: - Recommit

// Forces WindowServer to recommit the display configuration graph,
// re-allocating compositor surfaces against current pipeline instances.
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
    BOOL _sleepOnBattery;
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
    _sleepOnBattery = isOnBattery();
    [self cancelRecommit];
    NSLog(@"[sleep] battery=%s", _sleepOnBattery ? "yes" : "no");
}

- (void)systemDidWake:(NSNotification *)note {
    BOOL batteryAtWake = isOnBattery();
    BOOL qualifying = _sleepOnBattery && batteryAtWake;
    NSLog(@"[wake] battery_sleep=%s battery_wake=%s%s", _sleepOnBattery ? "yes" : "no",
          batteryAtWake ? "yes" : "no", qualifying ? " — arming recommit" : "");
    if (qualifying) {
        [self armRecommit];
    }
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
