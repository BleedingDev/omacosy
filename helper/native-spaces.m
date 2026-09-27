// Native macOS Spaces are separate from AeroSpace workspaces.
#import <AppKit/AppKit.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/nlist.h>
// The bridge entry point is local, not exported through dlsym. Resolve its
// exact Mach-O symbol, as upstream yabai does; never guess instruction offsets.
static void *bridgeEntry(void) {
    const char *symbol = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "/SkyLight.framework/")) continue;
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        if (header->magic != MH_MAGIC_64) return NULL;
        const uint8_t *cursor = (const void *)(header + 1);
        const struct segment_command_64 *link = NULL;
        const struct symtab_command *table = NULL;
        for (uint32_t j = 0; j < header->ncmds; j++) {
            const struct load_command *cmd = (const void *)cursor;
            if (cmd->cmd == LC_SYMTAB) table = (const void *)cmd;
            if (cmd->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)cmd)->segname, SEG_LINKEDIT) == 0) link = (const void *)cmd;
            if (cmd->cmdsize < sizeof(*cmd)) return NULL;
            cursor += cmd->cmdsize;
        }
        if (!link || !table) return NULL;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        uintptr_t base = link->vmaddr - link->fileoff + slide;
        const struct nlist_64 *entries = (const void *)(base + table->symoff);
        const char *strings = (const void *)(base + table->stroff);
        for (uint32_t j = 0; j < table->nsyms; j++)
            if (entries[j].n_un.n_strx < table->strsize && strcmp(strings + entries[j].n_un.n_strx, symbol) == 0)
                return (void *)(entries[j].n_value + slide);
    }
    return NULL;
}
extern int SLSMainConnectionID(void);
extern CFArrayRef SLSCopyManagedDisplaySpaces(int);
extern CFArrayRef SLSCopySpacesForWindows(int, int, CFArrayRef);
static NSArray *displays(void) { return CFBridgingRelease(SLSCopyManagedDisplaySpaces(SLSMainConnectionID())); }
static NSArray *spaces(NSNumber *wid) { return CFBridgingRelease(SLSCopySpacesForWindows(SLSMainConnectionID(), 7, (__bridge CFArrayRef)@[wid])); }

// Native desktop identity belongs to a physical display, not to whichever
// desktop happens to be active after unplug. Never delete/reorder desktops.
static NSString *ownershipPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".local/state/omacosy/native-display-ownership.json"];
}
static NSDictionary *ownership(void) {
    NSData *data = [NSData dataWithContentsOfFile:ownershipPath()];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static NSDictionary *decision(NSString *reason) { return @{@"ok":@NO, @"reason":reason}; }
// Pure planner also used by the fixture tests; no WindowServer or AX calls.
static NSDictionary *collapsePlan(NSArray *ds, NSDictionary *owners, NSArray *rows) {
    if (ds.count != 1) return decision(@"requires one stable display");
    NSDictionary *d = ds.firstObject, *current = d[@"Current Space"];
    NSString *displayID = d[@"Display Identifier"];
    NSString *uuid = owners[displayID];
    if (![uuid isKindOfClass:NSString.class] || !uuid.length) return decision(@"no saved desktop owner for this display");
    if (!current || !current[@"type"] || [current[@"type"] intValue] != 0) return decision(@"native fullscreen active; defer");
    NSDictionary *target = nil;
    NSMutableSet *normal = [NSMutableSet set], *all = [NSMutableSet set];
    BOOL currentFound = NO;
    for (NSDictionary *s in d[@"Spaces"]) {
        NSNumber *sid = s[@"ManagedSpaceID"];
        if (!sid || !s[@"uuid"] || [all containsObject:sid]) return decision(@"invalid desktop inventory");
        [all addObject:sid];
        if ([sid isEqual:current[@"ManagedSpaceID"]] && [s[@"uuid"] isEqual:current[@"uuid"]]) currentFound = YES;
        if (s[@"type"] && [s[@"type"] intValue] == 0) {
            [normal addObject:sid];
            if ([s[@"uuid"] isEqual:uuid]) {
                if (target) return decision(@"ambiguous desktop identity");
                target = s;
            }
        }
    }
    if (!currentFound) return decision(@"current desktop missing from inventory");
    if (!target) return decision(@"saved display-owned desktop missing; refusing active-desktop fallback");
    NSMutableOrderedSet *windows = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *row in rows) {
        NSArray *membership = row[@"spaces"];
        NSNumber *wid = row[@"id"];
        if (wid.unsignedLongLongValue == 0 || wid.unsignedLongLongValue > UINT32_MAX) continue;
        // Sticky, fullscreen, and vanished windows are left to macOS.
        if (membership.count == 1 && [normal containsObject:membership[0]] && ![membership[0] isEqual:target[@"ManagedSpaceID"]]) [windows addObject:wid];
    }
    return @{@"ok":@YES, @"display":displayID, @"target":target[@"ManagedSpaceID"], @"uuid":uuid,
             @"activate":@(![current[@"ManagedSpaceID"] isEqual:target[@"ManagedSpaceID"]]), @"windows":windows.array};
}
// Capture only consistent multi-display inventories. Keep the known normal
// desktop UUID even while a display is in native fullscreen.
static NSDictionary *ownerSnapshot(NSArray *ds, NSDictionary *previous) {
    if (ds.count < 2) return nil;
    NSMutableDictionary *saved = [previous mutableCopy];
    NSMutableSet *seenSpaces = [NSMutableSet set], *seenDisplays = [NSMutableSet set];
    for (NSDictionary *d in ds) {
        NSString *displayID = d[@"Display Identifier"];
        if (!displayID.length || [seenDisplays containsObject:displayID]) return nil;
        [seenDisplays addObject:displayID];
        NSDictionary *candidate = nil, *current = d[@"Current Space"];
        BOOL currentFound = NO;
        for (NSDictionary *s in d[@"Spaces"]) {
            NSString *uuid = s[@"uuid"];
            if (!uuid.length || !s[@"ManagedSpaceID"] || [seenSpaces containsObject:uuid]) return nil;
            [seenSpaces addObject:uuid];
            if ([uuid isEqual:current[@"uuid"]] && [s[@"ManagedSpaceID"] isEqual:current[@"ManagedSpaceID"]]) currentFound = YES;
            if (s[@"type"] && [s[@"type"] intValue] == 0 && (!candidate || [uuid isEqual:previous[displayID]])) candidate = s;
        }
        if (!candidate || !currentFound) return nil;
        saved[displayID] = candidate[@"uuid"];
    }
    return saved;
}
static NSArray *windowRows(void) {
    NSArray *wins = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    if (!wins) return nil;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *w in wins) {
        if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
        NSNumber *wid = w[(id)kCGWindowNumber];
        if (wid) [rows addObject:@{@"id":wid, @"spaces":spaces(wid) ?: @[]}];
    }
    return rows;
}
static NSArray *topology(NSArray *ds) {
    if (!ds) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *d in ds) {
        NSMutableArray *ss = [NSMutableArray array];
        for (NSDictionary *s in d[@"Spaces"]) [ss addObject:@[s[@"ManagedSpaceID"] ?: @0, s[@"uuid"] ?: @"", s[@"type"] ?: @(-1)]];
        [result addObject:@[d[@"Display Identifier"] ?: @"", d[@"Current Space"][@"ManagedSpaceID"] ?: @0, ss]];
    }
    return result;
}
static BOOL physicalDisplaysMatch(NSArray *ds) {
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count != ds.count || !count) return NO;
    CGDirectDisplayID ids[count];
    if (CGGetActiveDisplayList(count, ids, &count) != kCGErrorSuccess || count != ds.count) return NO;
    NSMutableSet *physical = [NSMutableSet set], *managed = [NSMutableSet set];
    for (uint32_t i = 0; i < count; ++i) {
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(ids[i]);
        if (!uuid) return NO;
        [physical addObject:CFBridgingRelease(CFUUIDCreateString(NULL, uuid))]; CFRelease(uuid);
    }
    for (NSDictionary *d in ds) if (d[@"Display Identifier"]) [managed addObject:d[@"Display Identifier"]];
    return [physical isEqual:managed];
}
static NSArray *stableDisplays(void) {
    NSArray *ds = displays();
    if (!physicalDisplaysMatch(ds)) return nil;
    for (int i = 0; i < 3; ++i) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        NSArray *fresh = displays();
        if (!physicalDisplaysMatch(fresh) || ![topology(ds) isEqual:topology(fresh)]) return nil;
        ds = fresh;
    }
    return ds;
}
extern CGError CoreDockSendNotification(CFStringRef, int);
static id attribute(AXUIElementRef e, CFStringRef key) {
    if (!e) return nil;
    CFTypeRef result = NULL;
    if (AXUIElementCopyAttributeValue(e, key, &result) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(result);
}
static id findIdentifier(AXUIElementRef e, NSString *identifier, int depth) {
    if (!e || depth > 8) return nil;
    if ([attribute(e, CFSTR("AXIdentifier")) isEqual:identifier]) return (__bridge id)e;
    for (id child in attribute(e, kAXChildrenAttribute)) {
        id found = findIdentifier((__bridge AXUIElementRef)child, identifier, depth + 1);
        if (found) return found;
    }
    return nil;
}
// Select the surviving display's own desktop using Dock's normal UI action.
// No Space destruction, private display reassignment, or raw current-Space setter.
static BOOL activateOwnedDesktop(NSDictionary *plan, NSArray *expected) {
    if (!AXIsProcessTrusted()) return NO;
    NSRunningApplication *dock = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"].firstObject;
    if (!dock) return NO;
    AXUIElementRef ax = AXUIElementCreateApplication(dock.processIdentifier);
    AXUIElementSetMessagingTimeout(ax, 0.5);
    if (findIdentifier(ax, @"mc", 0)) { CFRelease(ax); return NO; }
    BOOL ok = NO;
    CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
    @try {
        id list = nil;
        for (int i = 0; i < 30 && !list; ++i) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            list = findIdentifier(ax, @"mc.spaces.list", 0);
        }
        NSArray *fresh = displays();
        if (!list || !physicalDisplaysMatch(fresh) || ![topology(fresh) isEqual:topology(expected)]) return NO;
        NSArray *ordered = fresh.firstObject[@"Spaces"];
        NSArray *children = attribute((__bridge AXUIElementRef)list, kAXChildrenAttribute);
        if (children.count != ordered.count) return NO;
        for (NSUInteger i = 0; i < ordered.count; ++i) {
            if (![ordered[i][@"uuid"] isEqual:plan[@"uuid"]]) continue;
            if (AXUIElementPerformAction((__bridge AXUIElementRef)children[i], kAXPressAction) != kAXErrorSuccess) return NO;
            for (int attempt = 0; attempt < 40; ++attempt) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                fresh = displays();
                if (fresh.count != 1 || !physicalDisplaysMatch(fresh)) return NO;
                if ([fresh.firstObject[@"Current Space"][@"uuid"] isEqual:plan[@"uuid"]]) { ok = YES; break; }
            }
            break;
        }
    } @finally {
        if (findIdentifier(ax, @"mc", 0)) CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
        CFRelease(ax);
    }
    return ok;
}
static void printJSON(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc < 2) return 2;
    NSString *command = @(argv[1]);
    if ([command isEqual:@"plan"]) {
        NSData *data = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
        NSDictionary *input = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![input isKindOfClass:NSDictionary.class] || ![input[@"displays"] isKindOfClass:NSArray.class] || ![input[@"ownership"] isKindOfClass:NSDictionary.class] || ![input[@"windows"] isKindOfClass:NSArray.class]) return 2;
        if ([input[@"operation"] isEqual:@"snapshot"]) {
            NSDictionary *saved = ownerSnapshot(input[@"displays"], input[@"ownership"]);
            printJSON(saved ? @{@"ok":@YES, @"ownership":saved} : decision(@"inconsistent multi-display snapshot"));
        } else printJSON(collapsePlan(input[@"displays"], input[@"ownership"], input[@"windows"]));
        return 0;
    }
    if ([command isEqual:@"status"]) { printJSON(@{@"displays":displays() ?: @[], @"windows":windowRows() ?: @[], @"accessibilityTrusted":@(AXIsProcessTrusted())}); return 0; }
    if (![command isEqual:@"snapshot"] && ![command isEqual:@"collapse"]) return 2;
    // Single-instance native operations; shell callers also serialize their
    // emulated-workspace changes. O_EXCL is not used, so crashes leave no lockout.
    NSString *dir = [ownershipPath() stringByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    int lock = open([[dir stringByAppendingPathComponent:@"native-spaces.lock"] fileSystemRepresentation], O_CREAT | O_RDWR, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) { if (lock >= 0) close(lock); return 75; }
    NSArray *ds = stableDisplays();
    if (!ds) { fputs("native Spaces: display topology is changing; deferred\n", stderr); return 75; }
    NSDictionary *owners = ownership();
    if ([command isEqual:@"snapshot"]) {
        if (ds.count < 2) return 0; // never overwrite pre-unplug ownership
        NSDictionary *saved = ownerSnapshot(ds, owners);
        if (!saved) return 75;
        NSData *data = [NSJSONSerialization dataWithJSONObject:saved options:NSJSONWritingPrettyPrinted error:nil];
        if (![data writeToFile:ownershipPath() options:NSDataWritingAtomic error:nil]) return 1;
        puts("native Spaces: saved stable physical-display ownership"); return 0;
    }
    if (argc != 2) { fputs("collapse accepts no explicit window IDs\n", stderr); return 2; }
    NSArray *rows = windowRows();
    if (!rows) return 75;
    NSDictionary *plan = collapsePlan(ds, owners, rows);
    if (![plan[@"ok"] boolValue]) { fprintf(stderr,"native Spaces deferred: %s\n",[plan[@"reason"] UTF8String]); return 75; }
    if ([plan[@"activate"] boolValue] && !activateOwnedDesktop(plan, ds)) {
        fputs("native Spaces: could not select display-owned desktop; no windows moved\n", stderr); return 75;
    }
    ds = stableDisplays();
    rows = windowRows();
    if (!ds || !rows) return 75;
    NSDictionary *freshPlan = collapsePlan(ds, owners, rows);
    if (![freshPlan[@"ok"] boolValue] || [freshPlan[@"activate"] boolValue] || ![freshPlan[@"uuid"] isEqual:plan[@"uuid"]]) return 75;
    NSArray *windows = freshPlan[@"windows"];
    if (!windows.count) { puts("native Spaces: already consolidated on display-owned desktop"); return 0; }
    Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    void (*perform)(id) = bridgeEntry();
    if (!cls || !perform) return 1;
    // One batch, then re-read. Never act again on Space IDs from before a move:
    // macOS may itself remove a detached display's empty temporary desktop.
    if (!physicalDisplaysMatch(displays()) || ![topology(ds) isEqual:topology(displays())]) return 75;
    id op = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithWindows:spaceID:"), windows, [freshPlan[@"target"] unsignedLongLongValue]);
    perform(op);
    for (int attempt = 0; attempt < 40; ++attempt) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        NSArray *fresh = displays();
        if (fresh.count != 1 || !physicalDisplaysMatch(fresh) || ![fresh.firstObject[@"Current Space"][@"uuid"] isEqual:plan[@"uuid"]]) {
            fputs("native Spaces: topology changed after move; no blind retry\n", stderr); return 1;
        }
        BOOL verified = YES;
        for (NSNumber *wid in windows) {
            NSArray *membership = spaces(wid);
            if (membership.count && !(membership.count == 1 && [membership[0] isEqual:freshPlan[@"target"]])) verified = NO;
        }
        if (verified) { printf("native Spaces: verified %lu windows on owned desktop; no desktop deletion requested\n",(unsigned long)windows.count); return 0; }
    }
    fputs("native Spaces: batch move unverified; no blind retry\n", stderr); return 1;
}}
