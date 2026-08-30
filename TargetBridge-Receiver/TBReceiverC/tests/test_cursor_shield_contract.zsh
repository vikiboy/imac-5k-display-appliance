#!/bin/zsh
set -euo pipefail

receiver_source="${1:-benchmarks/benchmark_targetbridge_raw_receiver.m}"
shield_source="${2:-src/tb_cursor_shield_view.m}"
shield_header="${3:-src/tb_cursor_shield_view.h}"
[[ -f "$receiver_source" && -f "$shield_source" && -f "$shield_header" ]] || {
  print -u2 "cursor shield contract failed: source file missing"
  exit 1
}

rg -q '@interface TBCursorShieldView : NSView' "$shield_header"
rg -q -- '- \(void\)resetCursorRects' "$shield_source"
rg -q 'addCursorRect:self\.bounds cursor:_transparentCursor' "$shield_source"
rg -q '\[NSCursor hide\]' "$shield_source"
rg -q '\[NSCursor unhide\]' "$shield_source"
rg -q 'NSTrackingCursorUpdate' "$shield_source"
rg -q 'NSTrackingActiveAlways' "$shield_source"
if rg -q 'NSTrackingActiveInKeyWindow' "$shield_source"; then
  print -u2 'cursor shield contract failed: cursor tracking still depends on key-window focus'
  exit 1
fi
rg -q 'if \(_suppressLocalCursor\)' "$shield_source"
rg -q 'NSApp\.isActive && self\.window\.isKeyWindow' "$shield_source"
rg -q -- '- \(void\)cursorUpdate:' "$shield_source"
rg -q 'NSWorkspaceSessionDidBecomeActiveNotification' "$receiver_source"
rg -q 'NSWorkspaceSessionDidResignActiveNotification' "$receiver_source"
rg -q -- '- \(void\)applicationWillResignActive:' "$receiver_source"
rg -q 'NSWindowDidBecomeKeyNotification' "$receiver_source"
rg -q 'NSWindowDidResignKeyNotification' "$receiver_source"
rg -q 'activateIgnoringOtherApps:YES' "$receiver_source"
rg -q 'NSApp\.isActive' "$receiver_source"
rg -q 'cursorActivationHandler' "$receiver_source"
rg -q 'cursorDeactivationHandler' "$receiver_source"
rg -q 'privacyBlankHandler' "$receiver_source"
rg -q 'privacyResumeHandler' "$receiver_source"
rg -q 'ensure_global_cursor_hidden' "$receiver_source"
rg -q 'restore_global_cursor' "$receiver_source"

# An ordinary focus transition must not revoke an unlocked display surface.
# Keep this as both a positive exact-dependency assertion and a negative guard
# against app/key conditions being reintroduced into the declaration.
rg -U -q 'const BOOL publicSurfaceAvailable\s*=\s*_guiSessionActive\s*;' "$receiver_source"
if rg -U -q 'const BOOL publicSurfaceAvailable\s*=\s*[^;]*(_appForeground|_window\.isKeyWindow)' "$receiver_source"; then
  print -u2 'cursor shield contract failed: receiver surface still depends on app/key focus'
  exit 1
fi

rg -q -- '- \(void\)requestCursorActivation' "$receiver_source"
rg -q 'makeKeyAndOrderFront:nil' "$receiver_source"
rg -q 'NSEC_PER_SEC' "$receiver_source"
rg -q 'foreground-activation-timeout' "$receiver_source"
rg -q '\[self reapplyCursorShield\]' "$receiver_source"
rg -q 'surfaceView\.suppressLocalCursor = YES' "$receiver_source"
rg -q 'surfaceView\.suppressLocalCursor = NO' "$receiver_source"
rg -q 'gui-session=inactive' "$receiver_source"
rg -q 'surface=blank' "$receiver_source"
rg -q 'window=non-key.*cursor=released.*surface=blank' "$receiver_source"
rg -q 'window=non-key action=reclaim-deferred' "$receiver_source"
rg -q 'privacyOverlay\.layer\.backgroundColor = NSColor\.blackColor\.CGColor' "$receiver_source"

# The appliance may react to secure-session notifications, but it must never
# synthesize credentials or invoke private lock/unlock mechanisms.
if rg -q 'CGSession -suspend|screensaverExit|unlockWith|ScreenSaverEngine|forceTerminate|loginwindow.*(kill|terminate)' "$receiver_source"; then
  print -u2 'cursor shield contract failed: prohibited secure-session bypass found'
  exit 1
fi

suppress_line="$(rg -n 'surfaceView\.suppressLocalCursor = YES' "$receiver_source" | head -1 | cut -d: -f1)"
activate_line="$(rg -n 'presentationController\.streamActive = YES' "$receiver_source" | head -1 | cut -d: -f1)"
show_line="$(rg -n '"session=ended"\);' "$receiver_source" | head -1 | cut -d: -f1)"
release_line="$(rg -n 'surfaceView\.suppressLocalCursor = NO' "$receiver_source" | tail -1 | cut -d: -f1)"

[[ -n "$suppress_line" && -n "$activate_line" && -n "$show_line" && -n "$release_line" ]] || {
  print -u2 "cursor shield contract failed: lifecycle marker missing"
  exit 1
}
(( suppress_line < activate_line && show_line < release_line )) || {
  print -u2 "cursor shield contract failed: expected shield-before-activation and show-before-release"
  exit 1
}

print "cursor shield contract passed (lock-aware window policy plus balanced hide/show)"
