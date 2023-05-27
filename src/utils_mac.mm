/*
 * MIT License
 *
 * Copyright (C) 2021-2023 by wangwenx190 (Yuhang Zhao)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include "utils.h"
#include "framelessmanager.h"
#include "framelessmanager_p.h"
#include "framelessconfig_p.h"
#include "framelesshelpercore_global_p.h"
#include <QtCore/qhash.h>
#include <QtCore/qcoreapplication.h>
#include <QtCore/qloggingcategory.h>
#if (QT_VERSION >= QT_VERSION_CHECK(5, 9, 0))
#  include <QtCore/qoperatingsystemversion.h>
#else
#  include <QtCore/qsysinfo.h>
#endif
#include <QtGui/qwindow.h>
#include <objc/runtime.h>
#include <AppKit/AppKit.h>

QT_BEGIN_NAMESPACE
[[nodiscard]] Q_CORE_EXPORT bool qt_mac_applicationIsInDarkMode(); // Since 5.12
[[nodiscard]] Q_GUI_EXPORT QColor qt_mac_toQColor(const NSColor *color); // Since 5.8
QT_END_NAMESPACE

FRAMELESSHELPER_BEGIN_NAMESPACE
using Callback = std::function<void()>;
FRAMELESSHELPER_END_NAMESPACE

@interface MyKeyValueObserver : NSObject
@end

@implementation MyKeyValueObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
        change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context
{
    Q_UNUSED(keyPath);
    Q_UNUSED(object);
    Q_UNUSED(change);

    (*reinterpret_cast<FRAMELESSHELPER_PREPEND_NAMESPACE(Callback) *>(context))();
}
@end

FRAMELESSHELPER_BEGIN_NAMESPACE

[[maybe_unused]] static Q_LOGGING_CATEGORY(lcUtilsMac, "wangwenx190.framelesshelper.core.utils.mac")

#ifdef FRAMELESSHELPER_CORE_NO_DEBUG_OUTPUT
#  define INFO QT_NO_QDEBUG_MACRO()
#  define DEBUG QT_NO_QDEBUG_MACRO()
#  define WARNING QT_NO_QDEBUG_MACRO()
#  define CRITICAL QT_NO_QDEBUG_MACRO()
#else
#  define INFO qCInfo(lcUtilsMac)
#  define DEBUG qCDebug(lcUtilsMac)
#  define WARNING qCWarning(lcUtilsMac)
#  define CRITICAL qCCritical(lcUtilsMac)
#endif

using namespace Global;

class MacOSNotificationObserver
{
    Q_DISABLE_COPY_MOVE(MacOSNotificationObserver)

public:
    explicit MacOSNotificationObserver(NSObject *object, NSNotificationName name, const Callback &callback) {
        Q_ASSERT(name);
        Q_ASSERT(callback);
        if (!name || !callback) {
            return;
        }
        observer = [[NSNotificationCenter defaultCenter] addObserverForName:name
            object:object queue:nil usingBlock:^(NSNotification *) {
                callback();
            }
        ];
    }

    explicit MacOSNotificationObserver() = default;

    ~MacOSNotificationObserver()
    {
        remove();
    }

    void remove()
    {
        if (!observer) {
            return;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        observer = nil;
    }

private:
    NSObject *observer = nil;
};

class MacOSKeyValueObserver
{
    Q_DISABLE_COPY_MOVE(MacOSKeyValueObserver)

public:
    // Note: MacOSKeyValueObserver must not outlive the object observed!
    explicit MacOSKeyValueObserver(NSObject *obj, NSString *key, const Callback &cb,
        const NSKeyValueObservingOptions options = NSKeyValueObservingOptionNew)
    {
        Q_ASSERT(obj);
        Q_ASSERT(key);
        Q_ASSERT(cb);
        if (!obj || !key || !cb) {
            return;
        }
        object = obj;
        keyPath = key;
        callback = std::make_unique<Callback>(cb);
        addObserver(options);
    }

    explicit MacOSKeyValueObserver() = default;

    ~MacOSKeyValueObserver()
    {
        removeObserver();
    }

    void removeObserver()
    {
        if (!object) {
            return;
        }
        [object removeObserver:observer forKeyPath:keyPath context:callback.get()];
        object = nil;
    }

private:
    void addObserver(const NSKeyValueObservingOptions options)
    {
        [object addObserver:observer forKeyPath:keyPath options:options context:callback.get()];
    }

private:
    NSObject *object = nil;
    NSString *keyPath = nil;
    std::unique_ptr<Callback> callback = nil;

    static inline MyKeyValueObserver *observer = [[MyKeyValueObserver alloc] init];
};

class MacOSThemeObserver
{
    Q_DISABLE_COPY_MOVE(MacOSThemeObserver)

public:
    explicit MacOSThemeObserver()
    {
#if (QT_VERSION >= QT_VERSION_CHECK(5, 11, 2))
        static const bool isMojave = (QOperatingSystemVersion::current() >= QOperatingSystemVersion::MacOSMojave);
#elif (QT_VERSION >= QT_VERSION_CHECK(5, 9, 1))
        static const bool isMojave = (QOperatingSystemVersion::current() > QOperatingSystemVersion::MacOSHighSierra);
#elif (QT_VERSION >= QT_VERSION_CHECK(5, 9, 0))
        static const bool isMojave = (QOperatingSystemVersion::current() > QOperatingSystemVersion::MacOSSierra);
#else
        static const bool isMojave = (QSysInfo::macVersion() > QSysInfo::MV_SIERRA);
#endif
        if (isMojave) {
            m_appearanceObserver = std::make_unique<MacOSKeyValueObserver>(NSApp, @"effectiveAppearance", [](){
                QT_WARNING_PUSH
                QT_WARNING_DISABLE_DEPRECATED
                NSAppearance.currentAppearance = NSApp.effectiveAppearance; // FIXME: use latest API.
                QT_WARNING_POP
                MacOSThemeObserver::notifySystemThemeChange();
            });
        }
        m_systemColorObserver = std::make_unique<MacOSNotificationObserver>(nil, NSSystemColorsDidChangeNotification,
            [](){ MacOSThemeObserver::notifySystemThemeChange(); });
    }

    ~MacOSThemeObserver() = default;

    static void notifySystemThemeChange()
    {
        // Sometimes the FramelessManager instance may be destroyed already.
        if (FramelessManager * const manager = FramelessManager::instance()) {
            if (FramelessManagerPrivate * const managerPriv = FramelessManagerPrivate::get(manager)) {
                managerPriv->notifySystemThemeHasChangedOrNot();
            }
        }
    }

private:
    std::unique_ptr<MacOSNotificationObserver> m_systemColorObserver = nil;
    std::unique_ptr<MacOSKeyValueObserver> m_appearanceObserver = nil;
};

[[nodiscard]] static inline NSWindow *mac_getNSWindow(const WId windowId)
{
    Q_ASSERT(windowId);
    if (!windowId) {
        return nil;
    }
    const auto nsview = reinterpret_cast<NSView *>(windowId);
    Q_ASSERT(nsview);
    if (!nsview) {
        return nil;
    }
    return [nsview window];
}

class NSWindowProxy;
struct MacUtilsData
{
    QHash<QWindow *, NSWindowProxy *> hash = {};
};

Q_GLOBAL_STATIC(MacUtilsData, g_macUtilsData);

class NSWindowProxy : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(NSWindowProxy)

public:
    // due to NSWindow may change at run-time, so use QWindow as key.
    // set window as parent for auto destroy on QWindow destroyed.
    explicit NSWindowProxy(QWindow *qtWindow) : QObject(qtWindow)
    {
        Q_ASSERT(qtWindow);
        Q_ASSERT(!instances.contains(qtWindow));
        if (!qtWindow || instances.contains(qtWindow)) {
            return; // need to delete later?
        }

        NSWindow *macWindow = mac_getNSWindow(qtWindow->winId());
        Q_ASSERT(macWindow);
        if (!macWindow) {
            return; // need to delete later?
        }

        qwindow = qtWindow;
        instances.insert(qtWindow, this);
        qwindowNSWindowMap.insert(qtWindow, macWindow);

        saveState();
        if (!windowClass) {
            windowClass = [macWindow class];
            Q_ASSERT(windowClass);
            replaceImplementations();
        }

        observeNSWindowChange();
    }

    ~NSWindowProxy() override
    {
        nswindowObserver.reset();

        instances.remove(qwindow);
        qwindowNSWindowMap.remove(qwindow);
        g_macUtilsData()->hash.remove(qwindow);
        if (instances.count() <= 0) {
            restoreImplementations();
            windowClass = nil;
        }
        restoreState();
    }

public Q_SLOTS:
    void saveState()
    {
        if(!qwindow || !qwindowNSWindowMap.contains(qwindow)) {
            return;
        }

        auto nswindow = qwindowNSWindowMap.value(qwindow);
        oldStyleMask = nswindow.styleMask;
        oldTitlebarAppearsTransparent = nswindow.titlebarAppearsTransparent;
        oldTitleVisibility = nswindow.titleVisibility;
        oldHasShadow = nswindow.hasShadow;
        oldShowsToolbarButton = nswindow.showsToolbarButton;
        oldMovableByWindowBackground = nswindow.movableByWindowBackground;
        oldMovable = nswindow.movable;

        NSButton *button = nil;
        do {
            button = [nswindow standardWindowButton:NSWindowCloseButton];
            break;

            button = [nswindow standardWindowButton:NSWindowMiniaturizeButton];
            break;

            button = [nswindow standardWindowButton:NSWindowZoomButton];
            break;
        } while (false);

        if(button) {
            oldTitlebarViewVisible = !button.superview.hidden;
        }
    }

    void restoreState()
    {
        if(!qwindow || !qwindowNSWindowMap.contains(qwindow)) {
            return;
        }

        auto nswindow = qwindowNSWindowMap.value(qwindow);
        nswindow.styleMask = oldStyleMask;
        nswindow.titlebarAppearsTransparent = oldTitlebarAppearsTransparent;
        nswindow.titleVisibility = oldTitleVisibility;
        nswindow.hasShadow = oldHasShadow;
        nswindow.showsToolbarButton = oldShowsToolbarButton;
        nswindow.movableByWindowBackground = oldMovableByWindowBackground;
        nswindow.movable = oldMovable;

        NSButton *button = nil;
        do {
            button = [nswindow standardWindowButton:NSWindowCloseButton];
            break;

            button = [nswindow standardWindowButton:NSWindowMiniaturizeButton];
            break;

            button = [nswindow standardWindowButton:NSWindowZoomButton];
            break;
        } while (false);

        if(button) {
            button.superview.hidden = !oldTitlebarViewVisible;
        }
    }

    void replaceImplementations()
    {
        Method method = class_getInstanceMethod(windowClass, @selector(setStyleMask:));
        Q_ASSERT(method);
        oldSetStyleMask = reinterpret_cast<setStyleMaskPtr>(method_setImplementation(method, reinterpret_cast<IMP>(setStyleMask)));
        Q_ASSERT(oldSetStyleMask);

        method = class_getInstanceMethod(windowClass, @selector(setTitlebarAppearsTransparent:));
        Q_ASSERT(method);
        oldSetTitlebarAppearsTransparent = reinterpret_cast<setTitlebarAppearsTransparentPtr>(method_setImplementation(method, reinterpret_cast<IMP>(setTitlebarAppearsTransparent)));
        Q_ASSERT(oldSetTitlebarAppearsTransparent);

#if 0
        method = class_getInstanceMethod(windowClass, @selector(canBecomeKeyWindow));
        Q_ASSERT(method);
        oldCanBecomeKeyWindow = reinterpret_cast<canBecomeKeyWindowPtr>(method_setImplementation(method, reinterpret_cast<IMP>(canBecomeKeyWindow)));
        Q_ASSERT(oldCanBecomeKeyWindow);

        method = class_getInstanceMethod(windowClass, @selector(canBecomeMainWindow));
        Q_ASSERT(method);
        oldCanBecomeMainWindow = reinterpret_cast<canBecomeMainWindowPtr>(method_setImplementation(method, reinterpret_cast<IMP>(canBecomeMainWindow)));
        Q_ASSERT(oldCanBecomeMainWindow);
#endif

        method = class_getInstanceMethod(windowClass, @selector(sendEvent:));
        Q_ASSERT(method);
        oldSendEvent = reinterpret_cast<sendEventPtr>(method_setImplementation(method, reinterpret_cast<IMP>(sendEvent)));
        Q_ASSERT(oldSendEvent);
    }

    void restoreImplementations()
    {
        Method method = class_getInstanceMethod(windowClass, @selector(setStyleMask:));
        Q_ASSERT(method);
        method_setImplementation(method, reinterpret_cast<IMP>(oldSetStyleMask));
        oldSetStyleMask = nil;

        method = class_getInstanceMethod(windowClass, @selector(setTitlebarAppearsTransparent:));
        Q_ASSERT(method);
        method_setImplementation(method, reinterpret_cast<IMP>(oldSetTitlebarAppearsTransparent));
        oldSetTitlebarAppearsTransparent = nil;

#if 0
        method = class_getInstanceMethod(windowClass, @selector(canBecomeKeyWindow));
        Q_ASSERT(method);
        method_setImplementation(method, reinterpret_cast<IMP>(oldCanBecomeKeyWindow));
        oldCanBecomeKeyWindow = nil;

        method = class_getInstanceMethod(windowClass, @selector(canBecomeMainWindow));
        Q_ASSERT(method);
        method_setImplementation(method, reinterpret_cast<IMP>(oldCanBecomeMainWindow));
        oldCanBecomeMainWindow = nil;
#endif

        method = class_getInstanceMethod(windowClass, @selector(sendEvent:));
        Q_ASSERT(method);
        method_setImplementation(method, reinterpret_cast<IMP>(oldSendEvent));
        oldSendEvent = nil;
    }

    void setSystemTitleBarVisible(const bool visible)
    {
        NSWindow *nswindow = mac_getNSWindow(qwindow->winId());
        Q_ASSERT(nswindow);
        if (!nswindow) {
            return;
        }

        const NSView * const nsview = [nswindow contentView];
        Q_ASSERT(nsview);
        if (!nsview) {
            return;
        }

        if(instances.contains(qwindow)) {
            qwindowNSWindowMap.insert(qwindow, nswindow);
        }

        if(visible) {
            qwindow->removeEventFilter(this);
            nswindowObserver.reset();
        } else {
            qwindow->installEventFilter(this);
        }

        nsview.wantsLayer = YES;
        setSystemResizable(isResizable);
        //nswindow.styleMask |= NSWindowStyleMaskResizable;
        if (visible) {
            nswindow.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
        } else {
            nswindow.styleMask |= NSWindowStyleMaskFullSizeContentView;
        }
        nswindow.titlebarAppearsTransparent = (visible ? NO : YES);
        nswindow.titleVisibility = (visible ? NSWindowTitleVisible : NSWindowTitleHidden);
        nswindow.hasShadow = YES;
        nswindow.showsToolbarButton = NO;
        nswindow.movableByWindowBackground = NO;
        nswindow.movable = NO;

        NSButton *button = nil;
        do {
            button = [nswindow standardWindowButton:NSWindowCloseButton];
            break;

            button = [nswindow standardWindowButton:NSWindowMiniaturizeButton];
            break;

            button = [nswindow standardWindowButton:NSWindowZoomButton];
            break;
        } while (false);

        if(button) {
            button.superview.hidden = (visible ? NO : YES);;
        }

        if(!visible && !nswindowObserver) {
            observeNSWindowChange();
        }
    }

    void setSystemResizable(const bool resizable)
    {
        isResizable = resizable;
        if (!qwindowNSWindowMap.contains(qwindow)) return;

        NSWindow *nswindow = qwindowNSWindowMap.value(qwindow);

        BOOL isResizableOld = (nswindow.styleMask & NSWindowStyleMaskResizable) == NSWindowStyleMaskResizable;
        if (isResizable == isResizableOld) return;

        if (isResizable) {
            nswindow.styleMask |= NSWindowStyleMaskResizable;
        } else {
            nswindow.styleMask &= ~NSWindowStyleMaskResizable;
        }
    }

    void setBlurBehindWindowEnabled(const bool enable)
    {
        if (enable) {
            if (blurEffect) {
                return;
            }
            NSWindow *nswindow = mac_getNSWindow(qwindow->winId());
            NSView * const view = [nswindow contentView];
#if 1
            const Class visualEffectViewClass = NSClassFromString(@"NSVisualEffectView");
            if (!visualEffectViewClass) {
                return;
            }
            NSVisualEffectView * const blurView = [[visualEffectViewClass alloc] initWithFrame:view.bounds];
#else
            NSVisualEffectView * const blurView = [[NSVisualEffectView alloc] initWithFrame:view.bounds];
#endif
            if (@available(macOS 10.14, *)) {
                blurView.material = NSVisualEffectMaterialUnderWindowBackground;
            } else {
                // from chatgpt: not verified, only to depress compile warning
                // 'NSVisualEffectMaterialUnderWindowBackground' has been marked as being introduced in macOS 10.14 here, but the deployment target is macOS 10.12.0
                blurView.wantsLayer = YES;
                blurView.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.8] CGColor]; // Adjust alpha value as needed
            }
            blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            blurView.state = NSVisualEffectStateFollowsWindowActiveState;
            const NSView * const parent = [view superview];
            [parent addSubview:blurView positioned:NSWindowBelow relativeTo:view];
            blurEffect = blurView;
            updateBlurTheme();
            updateBlurSize();
            connect(FramelessManager::instance(),
                &FramelessManager::systemThemeChanged, this, &NSWindowProxy::updateBlurTheme);
            connect(qwindow, &QWindow::widthChanged, this, &NSWindowProxy::updateBlurSize);
            connect(qwindow, &QWindow::heightChanged, this, &NSWindowProxy::updateBlurSize);
        } else {
            if (!blurEffect) {
                return;
            }
            if (widthChangeConnection) {
                disconnect(widthChangeConnection);
                widthChangeConnection = {};
            }
            if (heightChangeConnection) {
                disconnect(heightChangeConnection);
                heightChangeConnection = {};
            }
            if (themeChangeConnection) {
                disconnect(themeChangeConnection);
                themeChangeConnection = {};
            }
            [blurEffect removeFromSuperview];
            blurEffect = nil;
        }
    }

    void updateBlurSize()
    {
        if (!blurEffect) {
            return;
        }
        NSWindow *nswindow = mac_getNSWindow(qwindow->winId());
        const NSView * const view = [nswindow contentView];
        blurEffect.frame = view.frame;
    }

    void updateBlurTheme()
    {
        if (!blurEffect) {
            return;
        }
        const auto view = static_cast<NSVisualEffectView *>(blurEffect);
        if (FramelessManager::instance()->systemTheme() == SystemTheme::Dark) {
            view.appearance = [NSAppearance appearanceNamed:@"NSAppearanceNameVibrantDark"];
        } else {
            view.appearance = [NSAppearance appearanceNamed:@"NSAppearanceNameVibrantLight"];
        }
    }

private:
    static BOOL canBecomeKeyWindow(id obj, SEL sel)
    {
        for (auto &&nswindow : std::as_const(qwindowNSWindowMap)) {
            if(nswindow != reinterpret_cast<NSWindow *>(obj)) {
                continue;
            }
            return YES;
        }

        if (oldCanBecomeKeyWindow) {
            return oldCanBecomeKeyWindow(obj, sel);
        }

        return YES;
    }

    static BOOL canBecomeMainWindow(id obj, SEL sel)
    {
        for (auto &&nswindow : std::as_const(qwindowNSWindowMap)) {
            if(nswindow != reinterpret_cast<NSWindow *>(obj)) {
                continue;
            }
            return YES;
        }

        if (oldCanBecomeMainWindow) {
            return oldCanBecomeMainWindow(obj, sel);
        }

        return YES;
    }

    static void setStyleMask(id obj, SEL sel, NSWindowStyleMask styleMask)
    {
        for (auto &&nswindow : std::as_const(qwindowNSWindowMap)) {
            if(nswindow != reinterpret_cast<NSWindow *>(obj)) {
                continue;
            }
            styleMask |= NSWindowStyleMaskFullSizeContentView;
        }

        if (oldSetStyleMask) {
            oldSetStyleMask(obj, sel, styleMask);
        }
    }

    static void setTitlebarAppearsTransparent(id obj, SEL sel, BOOL transparent)
    {
        for (auto &&nswindow : std::as_const(qwindowNSWindowMap)) {
            if(nswindow != reinterpret_cast<NSWindow *>(obj)) {
                continue;
            }
            transparent = YES;
            break;
        }

        if (oldSetTitlebarAppearsTransparent) {
            oldSetTitlebarAppearsTransparent(obj, sel, transparent);
        }
    }

    static void sendEvent(id obj, SEL sel, NSEvent *event)
    {
        if (oldSendEvent) {
            oldSendEvent(obj, sel, event);
        }

#if 0
        const auto nswindow = reinterpret_cast<NSWindow *>(obj);
        if (!instances.contains(nswindow)) {
            return;
        }

        NSWindowProxy * const proxy = instances[nswindow];
        if (event.type == NSEventTypeLeftMouseDown) {
            proxy->lastMouseDownEvent = event;
            QCoreApplication::processEvents();
            proxy->lastMouseDownEvent = nil;
        }
#endif
    }

    // Only QWidget has QEvent::WinIdChange, while QWindow does not.
    // And it seems that it doesn't always occur as expected.
    // so observe NSWindow instead of WinIdChange
    void observeNSWindowChange()
    {
        if(!qwindow || !qwindowNSWindowMap.contains(qwindow)) {
            return;
        }

        NSWindow *nswindow = qwindowNSWindowMap.value(qwindow);
        NSView * const nsview = [nswindow contentView];
        Q_ASSERT(nsview);
        if (!nsview) {
            return;
        }

        nswindowObserver = std::make_unique<MacOSKeyValueObserver>(nsview, @"window", [this](){
            qwindowNSWindowMap.remove(qwindow); // do nothing until this window is shown again
            nswindowObserver.reset();
        });
    }

protected:
    bool eventFilter(QObject *obj, QEvent *event) override
    {
        if(qwindow && qwindow == obj && event->type() == QEvent::Show
            && instances.contains(qwindow) && !qwindowNSWindowMap.contains(qwindow)) {
            setSystemTitleBarVisible(false); // if nswindow changed, set title bar hidden again
        }
        return QObject::eventFilter(obj, event);
    }

private:
    QWindow *qwindow = nil;
    //NSEvent *lastMouseDownEvent = nil;
    NSView *blurEffect = nil;

    NSWindowStyleMask oldStyleMask = 0;
    BOOL oldTitlebarAppearsTransparent = NO;
    BOOL oldHasShadow = NO;
    BOOL oldShowsToolbarButton = NO;
    BOOL oldMovableByWindowBackground = NO;
    BOOL oldMovable = NO;
    BOOL oldTitlebarViewVisible = NO;
    NSWindowTitleVisibility oldTitleVisibility = NSWindowTitleVisible;

    QMetaObject::Connection widthChangeConnection = {};
    QMetaObject::Connection heightChangeConnection = {};
    QMetaObject::Connection themeChangeConnection = {};

    static inline QHash<QWindow *, NSWindowProxy *> instances = {};
    static inline QHash<QWindow *, NSWindow *> qwindowNSWindowMap = {};

    static inline Class windowClass = nil;

    using setStyleMaskPtr = void(*)(id, SEL, NSWindowStyleMask);
    static inline setStyleMaskPtr oldSetStyleMask = nil;

    using setTitlebarAppearsTransparentPtr = void(*)(id, SEL, BOOL);
    static inline setTitlebarAppearsTransparentPtr oldSetTitlebarAppearsTransparent = nil;

    using canBecomeKeyWindowPtr = BOOL(*)(id, SEL);
    static inline canBecomeKeyWindowPtr oldCanBecomeKeyWindow = nil;

    using canBecomeMainWindowPtr = BOOL(*)(id, SEL);
    static inline canBecomeMainWindowPtr oldCanBecomeMainWindow = nil;

    using sendEventPtr = void(*)(id, SEL, NSEvent *);
    static inline sendEventPtr oldSendEvent = nil;

    std::unique_ptr<MacOSKeyValueObserver> nswindowObserver = nil;

    BOOL isResizable = true;
};

static inline void cleanupProxy()
{
    if (g_macUtilsData()->hash.isEmpty()) {
        return;
    }
    for (auto &&proxy : std::as_const(g_macUtilsData()->hash)) {
        Q_ASSERT(proxy);
        if (!proxy) {
            continue;
        }
        delete proxy;
    }
    g_macUtilsData()->hash.clear();
}

[[nodiscard]] static inline NSWindowProxy *ensureWindowProxy(QWindow *window)
{
    Q_ASSERT(window);
    if (!window) {
        return nil;
    }
    if (!g_macUtilsData()->hash.contains(window)) {
        const auto proxy = new NSWindowProxy(window);
        g_macUtilsData()->hash.insert(window, proxy);
    }
    static bool cleanerInstalled = false;
    if (!cleanerInstalled) {
        cleanerInstalled = true;
        qAddPostRoutine(cleanupProxy);
    }
    return g_macUtilsData()->hash.value(window);
}

SystemTheme Utils::getSystemTheme()
{
    // ### TODO: how to detect high contrast mode on macOS?
    return (shouldAppsUseDarkMode() ? SystemTheme::Dark : SystemTheme::Light);
}

void Utils::setSystemTitleBarVisible(QWindow *window, const bool visible)
{
    Q_ASSERT(window);
    if (!window) {
        return;
    }
    NSWindowProxy * const proxy = ensureWindowProxy(window);
    proxy->setSystemTitleBarVisible(visible);
}

void Utils::setSystemResizable(QWindow *window, const bool resizable)
{
    Q_ASSERT(window);
    if (!window) {
        return;
    }
    if (!g_macUtilsData()->hash.contains(window)) {
        return;
    }

    NSWindowProxy * const proxy = g_macUtilsData()->hash.value(window);
    proxy->setSystemResizable(resizable);
}

void Utils::startSystemMove(QWindow *window, const QPoint &globalPos)
{
    Q_ASSERT(window);
    if (!window) {
        return;
    }
#if (QT_VERSION >= QT_VERSION_CHECK(5, 15, 0))
    Q_UNUSED(globalPos);
    window->startSystemMove();
#else
    const NSWindow * const nswindow = mac_getNSWindow(window->winId());
    Q_ASSERT(nswindow);
    if (!nswindow) {
        return;
    }
    const CGEventRef clickDown = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown,
                         CGPointMake(globalPos.x(), globalPos.y()), kCGMouseButtonLeft);
    NSEvent * const nsevent = [NSEvent eventWithCGEvent:clickDown];
    Q_ASSERT(nsevent);
    if (!nsevent) {
        CFRelease(clickDown);
        return;
    }
    [nswindow performWindowDragWithEvent:nsevent];
    CFRelease(clickDown);
#endif
}

void Utils::startSystemResize(QWindow *window, const Qt::Edges edges, const QPoint &globalPos)
{
    Q_ASSERT(window);
    if (!window) {
        return;
    }
    if (edges == Qt::Edges{}) {
        return;
    }
#if (QT_VERSION >= QT_VERSION_CHECK(5, 15, 0))
    Q_UNUSED(globalPos);
    // Actually Qt doesn't implement this function, it will do nothing and always returns false.
    window->startSystemResize(edges);
#else
    // ### TODO
    Q_UNUSED(globalPos);
#endif
}

QColor Utils::getControlsAccentColor()
{
    if (@available(macOS 10.14, *)) {
        return qt_mac_toQColor([NSColor controlAccentColor]);
    } else {
        // from chatgpt: not verified, only to depress compile warning
        // 'controlAccentColor' has been marked as being introduced in macOS 10.14 here, but the deployment target is macOS 10.12.0
        return qt_mac_toQColor([NSColor highlightColor]);
    }
}

bool Utils::isTitleBarColorized()
{
    return false;
}

bool Utils::shouldAppsUseDarkMode_macos()
{
#if (QT_VERSION >= QT_VERSION_CHECK(5, 12, 0))
    return qt_mac_applicationIsInDarkMode();
#else
    const auto appearance = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:
                            @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [appearance isEqualToString:NSAppearanceNameDarkAqua];
#endif
}

bool Utils::setBlurBehindWindowEnabled(QWindow *window, const BlurMode mode, const QColor &color)
{
    Q_UNUSED(color);
    Q_ASSERT(window);
    if (!window) {
        return false;
    }
    const auto blurMode = [mode]() -> BlurMode {
        if ((mode == BlurMode::Disable) || (mode == BlurMode::Default)) {
            return mode;
        }
        WARNING << "The BlurMode::Windows_* enum values are not supported on macOS.";
        return BlurMode::Default;
    }();
    NSWindowProxy * const proxy = ensureWindowProxy(window);
    proxy->setBlurBehindWindowEnabled(blurMode == BlurMode::Default);
    return true;
}

QString Utils::getWallpaperFilePath()
{
#if 0
    const NSWorkspace * const sharedWorkspace = [NSWorkspace sharedWorkspace];
    if (!sharedWorkspace) {
        WARNING << "Failed to retrieve the shared workspace.";
        return {};
    }
    NSScreen * const mainScreen = [NSScreen mainScreen];
    if (!mainScreen) {
        WARNING << "Failed to retrieve the main screen.";
        return {};
    }
    const NSURL * const url = [sharedWorkspace desktopImageURLForScreen:mainScreen];
    if (!url) {
        WARNING << "Failed to retrieve the desktop image URL.";
        return {};
    }
    const QUrl path = QUrl::fromNSURL(url);
    if (!path.isValid()) {
        WARNING << "The converted QUrl is not valid.";
        return {};
    }
    return path.toLocalFile();
#else
    // ### TODO
    return {};
#endif
}

WallpaperAspectStyle Utils::getWallpaperAspectStyle()
{
    return WallpaperAspectStyle::Stretch;
}

bool Utils::isBlurBehindWindowSupported()
{
    static const auto result = []() -> bool {
        if (FramelessConfig::instance()->isSet(Option::ForceNonNativeBackgroundBlur)) {
            return false;
        }
#if (QT_VERSION >= QT_VERSION_CHECK(5, 9, 0))
        return (QOperatingSystemVersion::current() >= QOperatingSystemVersion::OSXYosemite);
#else
        return (QSysInfo::macVersion() >= QSysInfo::MV_YOSEMITE);
#endif
    }();
    return result;
}

void Utils::registerThemeChangeNotification()
{
    volatile static MacOSThemeObserver observer;
    Q_UNUSED(observer);
}

void Utils::removeWindowProxy(QWindow *window)
{
    Q_ASSERT(window);
    if (!window) {
        return;
    }
    if (!g_macUtilsData()->hash.contains(window)) {
        return;
    }
    if (const auto proxy = g_macUtilsData()->hash.value(window)) {
        // We'll restore everything to default in the destructor,
        // so no need to do it manually here.
        delete proxy;
    }
    g_macUtilsData()->hash.remove(window);
}

QColor Utils::getFrameBorderColor(const bool active)
{
    return (active ? getControlsAccentColor() : kDefaultDarkGrayColor);
}

FRAMELESSHELPER_END_NAMESPACE

#include "utils_mac.moc"