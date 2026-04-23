/* iOS file/folder picker bridge.
 *
 * KOReader's Lua frontend calls into the C API below to surface iOS'
 * native UIDocumentPickerViewController. We expose folder picking
 * because that's what makes external providers (iCloud Drive, Dropbox,
 * Drive, OneDrive, etc.) usefully browsable from inside KOReader's
 * existing file browser:
 *
 *   1. User picks a folder once → iOS returns a security-scoped URL.
 *   2. We serialize an NSURL bookmark (base64) for persistence.
 *   3. Each launch we resolve the bookmark and start accessing the
 *      security-scoped resource — that makes the folder appear at a
 *      real filesystem path that KOReader's lfs.dir / fopen can use.
 *
 * The picker UI MUST be presented from the main thread. We don't know
 * whether SDL_main runs on the main thread, so we expose a non-blocking
 * "start + poll" interface that the Lua plugin drives via UIManager
 * timer ticks. This avoids deadlocking the runloop in any thread layout.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    KO_PICK_IDLE = 0,
    KO_PICK_PENDING = 1,
    KO_PICK_DONE_OK = 2,
    KO_PICK_DONE_CANCEL = 3,
    KO_PICK_DONE_ERROR = 4,
} ko_pick_state_t;

/* Shared state between Obj-C delegate and Lua poll calls. Only
 * mutated on the main thread (delegate callbacks) and read on the
 * Lua thread; the state field is the single point of synchronization
 * (Lua only reads result fields once state >= KO_PICK_DONE_OK). */
static volatile ko_pick_state_t g_pick_state = KO_PICK_IDLE;
static NSString *g_picked_path = nil;
static NSString *g_picked_bookmark_b64 = nil;
static NSString *g_picked_error = nil;

@interface KOIOSPickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

@implementation KOIOSPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        g_picked_error = @"no urls returned";
        g_pick_state = KO_PICK_DONE_ERROR;
        return;
    }
    NSURL *url = urls.firstObject;

    /* Activate security scope. We deliberately don't release it here
     * — the scope must stay active for KOReader to keep reading the
     * folder during this app session. The plugin re-activates on
     * subsequent launches via ko_ios_resolve_bookmark. */
    BOOL accessed = [url startAccessingSecurityScopedResource];
    if (!accessed) {
        g_picked_error = @"startAccessingSecurityScopedResource failed";
        g_pick_state = KO_PICK_DONE_ERROR;
        return;
    }

    NSError *err = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&err];
    if (!bookmark) {
        g_picked_error = [NSString stringWithFormat:@"bookmark failed: %@", err];
        g_pick_state = KO_PICK_DONE_ERROR;
        return;
    }

    g_picked_path = [[NSString alloc] initWithUTF8String:url.fileSystemRepresentation];
    g_picked_bookmark_b64 = [bookmark base64EncodedStringWithOptions:0];
    g_picked_error = nil;
    g_pick_state = KO_PICK_DONE_OK;
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    g_picked_path = nil;
    g_picked_bookmark_b64 = nil;
    g_picked_error = nil;
    g_pick_state = KO_PICK_DONE_CANCEL;
}

@end

/* The delegate has to outlive the picker (UIKit holds it weakly), so
 * we keep one global instance pinned. */
static KOIOSPickerDelegate *g_delegate = nil;

static UIViewController *ko_ios_top_view_controller(void) {
    UIWindow *win = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive
            && scene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (!win && ((UIWindowScene *)scene).windows.count > 0) {
            win = ((UIWindowScene *)scene).windows.firstObject;
        }
        if (win) break;
    }
    if (!win) {
        /* Fallback for pre-scene apps (we shouldn't hit this on iOS
         * 13+, but SDL3 might still be using a non-scene path). */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        win = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    }
    if (!win) return nil;
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

bool ko_ios_pick_folder_start(void) {
    if (g_pick_state == KO_PICK_PENDING) return false;
    g_pick_state = KO_PICK_PENDING;
    g_picked_path = nil;
    g_picked_bookmark_b64 = nil;
    g_picked_error = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = ko_ios_top_view_controller();
        if (!top) {
            g_picked_error = @"no top view controller";
            g_pick_state = KO_PICK_DONE_ERROR;
            return;
        }
        if (!g_delegate) g_delegate = [[KOIOSPickerDelegate alloc] init];

        UIDocumentPickerViewController *picker;
        if (@available(iOS 14.0, *)) {
            picker = [[UIDocumentPickerViewController alloc]
                initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
        } else {
            g_picked_error = @"requires iOS 14";
            g_pick_state = KO_PICK_DONE_ERROR;
            return;
        }
        picker.delegate = g_delegate;
        picker.allowsMultipleSelection = NO;
        [top presentViewController:picker animated:YES completion:nil];
    });
    return true;
}

/* Lua poll. Returns the current state. When state is DONE_OK, fills
 * out_path and out_bookmark_b64. After this call returns DONE_*, the
 * state is reset to IDLE so the next call returns IDLE until another
 * pick is started. */
ko_pick_state_t ko_ios_pick_folder_poll(char *out_path, size_t path_cap,
                                        char *out_bookmark_b64, size_t bookmark_cap,
                                        char *out_error, size_t error_cap) {
    ko_pick_state_t state = g_pick_state;
    if (state < KO_PICK_DONE_OK) return state;

    if (state == KO_PICK_DONE_OK) {
        if (out_path && path_cap > 0) {
            const char *p = g_picked_path.UTF8String ?: "";
            strncpy(out_path, p, path_cap - 1);
            out_path[path_cap - 1] = '\0';
        }
        if (out_bookmark_b64 && bookmark_cap > 0) {
            const char *b = g_picked_bookmark_b64.UTF8String ?: "";
            strncpy(out_bookmark_b64, b, bookmark_cap - 1);
            out_bookmark_b64[bookmark_cap - 1] = '\0';
        }
    } else if (state == KO_PICK_DONE_ERROR) {
        if (out_error && error_cap > 0) {
            const char *e = g_picked_error.UTF8String ?: "unknown";
            strncpy(out_error, e, error_cap - 1);
            out_error[error_cap - 1] = '\0';
        }
    }

    g_pick_state = KO_PICK_IDLE;
    g_picked_path = nil;
    g_picked_bookmark_b64 = nil;
    g_picked_error = nil;
    return state;
}

/* Read iOS' safeAreaInsets directly off the key window, in physical
 * pixels (UIKit reports points; KOReader's framebuffer is in pixels).
 * Called from framebuffer_SDL3.lua to letterbox the UI inside the
 * notch/home-indicator bezel. We read straight from UIKit rather than
 * via SDL_GetWindowSafeArea because SDL only observes safeAreaInsets
 * via the safeAreaInsetsDidChange callback, which may not have fired
 * yet by the time we want to size the framebuffer. */
void ko_ios_get_safe_area_pixels(int *out_top, int *out_right,
                                 int *out_bottom, int *out_left) {
    if (out_top) *out_top = 0;
    if (out_right) *out_right = 0;
    if (out_bottom) *out_bottom = 0;
    if (out_left) *out_left = 0;

    __block UIWindow *win = nil;
    void (^lookup)(void) = ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (!win && ((UIWindowScene *)scene).windows.count > 0) {
                win = ((UIWindowScene *)scene).windows.firstObject;
            }
            if (win) break;
        }
    };
    if ([NSThread isMainThread]) {
        lookup();
    } else {
        dispatch_sync(dispatch_get_main_queue(), lookup);
    }
    if (!win) return;

    /* Force a layout pass so safeAreaInsets is populated. Early in
     * launch the window may not have been laid out yet. */
    if ([NSThread isMainThread]) {
        [win layoutIfNeeded];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{ [win layoutIfNeeded]; });
    }

    UIEdgeInsets insets = win.safeAreaInsets;
    CGFloat scale = win.screen ? win.screen.nativeScale
                               : UIScreen.mainScreen.nativeScale;
    if (out_top) *out_top = (int)ceilf(insets.top * scale);
    if (out_right) *out_right = (int)ceilf(insets.right * scale);
    if (out_bottom) *out_bottom = (int)ceilf(insets.bottom * scale);
    if (out_left) *out_left = (int)ceilf(insets.left * scale);
}

/* Resolve a stored bookmark, activate security scope, return path.
 * Called once per saved cloud folder at app launch. The returned path
 * may differ from the path saved at pick time — providers can rename
 * containers across launches. The activated scope is intentionally
 * not released; it stays alive for the app session. */
bool ko_ios_resolve_bookmark(const char *bookmark_b64,
                             char *out_path, size_t path_cap,
                             char *out_error, size_t error_cap) {
    if (!bookmark_b64 || !out_path || path_cap == 0) return false;

    NSString *b64 = [NSString stringWithUTF8String:bookmark_b64];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!data) {
        if (out_error && error_cap) strncpy(out_error, "invalid base64", error_cap - 1);
        return false;
    }

    BOOL stale = NO;
    NSError *err = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:data
                                           options:0
                                     relativeToURL:nil
                               bookmarkDataIsStale:&stale
                                             error:&err];
    if (!url) {
        if (out_error && error_cap) {
            const char *m = err.localizedDescription.UTF8String ?: "resolve failed";
            strncpy(out_error, m, error_cap - 1);
            out_error[error_cap - 1] = '\0';
        }
        return false;
    }

    if (![url startAccessingSecurityScopedResource]) {
        if (out_error && error_cap) {
            strncpy(out_error, "startAccessingSecurityScopedResource failed", error_cap - 1);
            out_error[error_cap - 1] = '\0';
        }
        return false;
    }

    const char *p = url.fileSystemRepresentation;
    strncpy(out_path, p, path_cap - 1);
    out_path[path_cap - 1] = '\0';
    return true;
}
