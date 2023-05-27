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

#include "framelessmanager.h"
#include "framelessmanager_p.h"
#include "framelesshelper_qt.h"
#include "framelessconfig_p.h"
#include "framelesshelpercore_global_p.h"
#include "utils.h"
#ifdef Q_OS_WINDOWS
#  include "framelesshelper_win.h"
#  include "winverhelper_p.h"
#endif
#include <QtCore/qvariant.h>
#include <QtCore/qcoreapplication.h>
#include <QtCore/qloggingcategory.h>
#include <QtGui/qfontdatabase.h>
#include <QWidget>
#include <QWindow>
#if (QT_VERSION >= QT_VERSION_CHECK(6, 5, 0))
#  include <QtGui/qguiapplication.h>
#  include <QtGui/qstylehints.h>
#endif // (QT_VERSION >= QT_VERSION_CHECK(6, 5, 0))

FRAMELESSHELPER_BEGIN_NAMESPACE

[[maybe_unused]] static Q_LOGGING_CATEGORY(lcFramelessManager, "wangwenx190.framelesshelper.core.framelessmanager")

#ifdef FRAMELESSHELPER_CORE_NO_DEBUG_OUTPUT
#  define INFO QT_NO_QDEBUG_MACRO()
#  define DEBUG QT_NO_QDEBUG_MACRO()
#  define WARNING QT_NO_QDEBUG_MACRO()
#  define CRITICAL QT_NO_QDEBUG_MACRO()
#else
#  define INFO qCInfo(lcFramelessManager)
#  define DEBUG qCDebug(lcFramelessManager)
#  define WARNING qCWarning(lcFramelessManager)
#  define CRITICAL qCCritical(lcFramelessManager)
#endif

using namespace Global;

struct FramelessManagerHelper
{
    QList<WId> windowIds = {};
};

Q_GLOBAL_STATIC(FramelessManagerHelper, g_helper)

Q_GLOBAL_STATIC(FramelessManager, g_manager)

[[maybe_unused]] static constexpr const char kGlobalFlagVarName[] = "__FRAMELESSHELPER__";

#ifndef FRAMELESSHELPER_CORE_NO_BUNDLE_RESOURCE
FRAMELESSHELPER_STRING_CONSTANT2(IconFontFilePath, ":/org.wangwenx190.FramelessHelper/resources/fonts/iconfont.ttf")
FRAMELESSHELPER_STRING_CONSTANT2(IconFontFamilyName_win11, "Segoe Fluent Icons")
FRAMELESSHELPER_STRING_CONSTANT2(IconFontFamilyName_win10, "Segoe MDL2 Assets")
FRAMELESSHELPER_STRING_CONSTANT2(IconFontFamilyName_fallback, "iconfont")
#  ifdef Q_OS_MACOS
[[maybe_unused]] static constexpr const int kIconFontPointSize = 10;
#  else // !Q_OS_MACOS
[[maybe_unused]] static constexpr const int kIconFontPointSize = 8;
#  endif // Q_OS_MACOS
#endif // FRAMELESSHELPER_CORE_NO_BUNDLE_RESOURCE

#ifndef FRAMELESSHELPER_CORE_NO_BUNDLE_RESOURCE
[[nodiscard]] static inline QString iconFontFamilyName()
{
    static const auto result = []() -> QString {
#ifdef Q_OS_WINDOWS
        if (WindowsVersionHelper::isWin11OrGreater()) {
            return kIconFontFamilyName_win11;
        }
        if (WindowsVersionHelper::isWin10OrGreater()) {
            return kIconFontFamilyName_win10;
        }
#endif // Q_OS_WINDOWS
        return kIconFontFamilyName_fallback;
    }();
    return result;
}
#endif // FRAMELESSHELPER_CORE_NO_BUNDLE_RESOURCE

FramelessManagerPrivate::FramelessManagerPrivate(FramelessManager *q) : QObject(q)
{
    Q_ASSERT(q);
    if (!q) {
        return;
    }
    q_ptr = q;
    initialize();
}

FramelessManagerPrivate::~FramelessManagerPrivate() = default;

FramelessManagerPrivate *FramelessManagerPrivate::get(FramelessManager *pub)
{
    Q_ASSERT(pub);
    if (!pub) {
        return nullptr;
    }
    return pub->d_func();
}

const FramelessManagerPrivate *FramelessManagerPrivate::get(const FramelessManager *pub)
{
    Q_ASSERT(pub);
    if (!pub) {
        return nullptr;
    }
    return pub->d_func();
}

void FramelessManagerPrivate::initializeIconFont()
{
#ifndef FRAMELESSHELPER_CORE_NO_BUNDLE_RESOURCE
    static bool inited = false;
    if (inited) {
        return;
    }
    inited = true;
    framelesshelpercore_initResource();
    // We always register this font because it's our only fallback.
    const int id = QFontDatabase::addApplicationFont(kIconFontFilePath);
    if (id < 0) {
        WARNING << "Failed to load icon font:" << kIconFontFilePath;
    } else {
        DEBUG << "Successfully registered icon font:" << QFontDatabase::applicationFontFamilies(id);
    }
#endif // FRAMELESSHELPER_CORE_NO_BUNDLE_RESOURCE
}

QFont FramelessManagerPrivate::getIconFont()
{
#ifdef FRAMELESSHELPER_CORE_NO_BUNDLE_RESOURCE
    return {};
#else // !FRAMELESSHELPER_CORE_NO_BUNDLE_RESOURCE
    static const auto font = []() -> QFont {
        QFont f = {};
        f.setFamily(iconFontFamilyName());
        f.setPointSize(kIconFontPointSize);
        return f;
    }();
    return font;
#endif // FRAMELESSHELPER_CORE_NO_BUNDLE_RESOURCE
}

SystemTheme FramelessManagerPrivate::systemTheme() const
{
    // The user's choice has top priority.
    if (isThemeOverrided()) {
#if defined(Q_OS_MACX) && (__MAC_OS_X_VERSION_MIN_REQUIRED < 101300)
        return *m_overrideTheme;
#else
        return m_overrideTheme.value();
#endif
    }
    return m_systemTheme;
}

QColor FramelessManagerPrivate::systemAccentColor() const
{
    return m_accentColor;
}

QString FramelessManagerPrivate::wallpaper() const
{
    return m_wallpaper;
}

WallpaperAspectStyle FramelessManagerPrivate::wallpaperAspectStyle() const
{
    return m_wallpaperAspectStyle;
}

void FramelessManagerPrivate::addWindow(FramelessParamsConst params)
{
    Q_ASSERT(params);
    if (!params) {
        return;
    }
    const WId windowId = params->getWindowId();
    if (g_helper()->windowIds.contains(windowId)) {
        return;
    }
    g_helper()->windowIds.append(windowId);
    static const bool pureQt = usePureQtImplementation();
    if (pureQt) {
        FramelessHelperQt::addWindow(params);
    }
#ifdef Q_OS_WINDOWS
    if (!pureQt) {
        FramelessHelperWin::addWindow(params);
    }
    Utils::installSystemMenuHook(windowId, params);
#endif
}

void FramelessManagerPrivate::removeWindow(QWindow *window)
{
    Q_ASSERT(window);
    if (!window) {
        return;
    }
    WId windowId = window->winId();
    if (!g_helper()->windowIds.contains(windowId)) {
        windowId = FramelessHelperQt::appliedWinId(window);
        if (!windowId) return;
    }
    g_helper()->windowIds.removeAll(windowId);
    static const bool pureQt = usePureQtImplementation();
    if (pureQt) {
        FramelessHelperQt::removeWindow(window);
    }
#ifdef Q_OS_WINDOWS
    if (!pureQt) {
        FramelessHelperWin::removeWindow(windowId);
    }
    Utils::uninstallSystemMenuHook(windowId);
#endif
}

void FramelessManagerPrivate::notifySystemThemeHasChangedOrNot()
{
    const SystemTheme currentSystemTheme = Utils::getSystemTheme();
#ifdef Q_OS_WINDOWS
    const DwmColorizationArea currentColorizationArea = Utils::getDwmColorizationArea();
    const QColor currentAccentColor = Utils::getDwmAccentColor();
#endif
#ifdef Q_OS_LINUX
    const QColor currentAccentColor = Utils::getWmThemeColor();
#endif
#ifdef Q_OS_MACOS
    const QColor currentAccentColor = Utils::getControlsAccentColor();
#endif
    bool notify = false;
    if (m_systemTheme != currentSystemTheme) {
        m_systemTheme = currentSystemTheme;
        notify = true;
    }
    if (m_accentColor != currentAccentColor) {
        m_accentColor = currentAccentColor;
        notify = true;
    }
#ifdef Q_OS_WINDOWS
    if (m_colorizationArea != currentColorizationArea) {
        m_colorizationArea = currentColorizationArea;
        notify = true;
    }
#endif
    // Don't emit the signal if the user has overrided the global theme.
    if (notify && !isThemeOverrided()) {
        Q_Q(FramelessManager);
        Q_EMIT q->systemThemeChanged();
        DEBUG.nospace() << "System theme changed. Current theme: " << m_systemTheme
                        << ", accent color: " << m_accentColor.name(QColor::HexArgb).toUpper()
#ifdef Q_OS_WINDOWS
                        << ", colorization area: " << m_colorizationArea
#endif
                        << '.';
    }
}

void FramelessManagerPrivate::notifyWallpaperHasChangedOrNot()
{
    const QString currentWallpaper = Utils::getWallpaperFilePath();
    const WallpaperAspectStyle currentWallpaperAspectStyle = Utils::getWallpaperAspectStyle();
    bool notify = false;
    if (m_wallpaper != currentWallpaper) {
        m_wallpaper = currentWallpaper;
        notify = true;
    }
    if (m_wallpaperAspectStyle != currentWallpaperAspectStyle) {
        m_wallpaperAspectStyle = currentWallpaperAspectStyle;
        notify = true;
    }
    if (notify) {
        Q_Q(FramelessManager);
        Q_EMIT q->wallpaperChanged();
        DEBUG.nospace() << "Wallpaper changed. Current wallpaper: " << m_wallpaper
                        << ", aspect style: " << m_wallpaperAspectStyle << '.';
    }
}

bool FramelessManagerPrivate::usePureQtImplementation()
{
    static const auto result = []() -> bool {
#ifdef Q_OS_WINDOWS
        return FramelessConfig::instance()->isSet(Option::UseCrossPlatformQtImplementation);
#else
        return true;
#endif
    }();
    return result;
}

void FramelessManagerPrivate::setOverrideTheme(const SystemTheme theme)
{
    if (systemTheme() == theme) {
        return;
    }
    if (theme == SystemTheme::Unknown) {
        m_overrideTheme = std::nullopt;
    } else {
        m_overrideTheme = theme;
    }
    Q_Q(FramelessManager);
    Q_EMIT q->systemThemeChanged();
}

bool FramelessManagerPrivate::isThemeOverrided() const
{
    return (m_overrideTheme.value_or(SystemTheme::Unknown) != SystemTheme::Unknown);
}

void FramelessManagerPrivate::initialize()
{
    m_systemTheme = Utils::getSystemTheme();
#ifdef Q_OS_WINDOWS
    m_colorizationArea = Utils::getDwmColorizationArea();
    m_accentColor = Utils::getDwmAccentColor();
#endif
#ifdef Q_OS_LINUX
    m_accentColor = Utils::getWmThemeColor();
#endif
#ifdef Q_OS_MACOS
    m_accentColor = Utils::getControlsAccentColor();
#endif
    m_wallpaper = Utils::getWallpaperFilePath();
    m_wallpaperAspectStyle = Utils::getWallpaperAspectStyle();
    DEBUG.nospace() << "Current system theme: " << m_systemTheme
                    << ", accent color: " << m_accentColor.name(QColor::HexArgb).toUpper()
#ifdef Q_OS_WINDOWS
                    << ", colorization area: " << m_colorizationArea
#endif
                    << ", wallpaper: " << m_wallpaper
                    << ", aspect style: " << m_wallpaperAspectStyle
                    << '.';
#if (QT_VERSION >= QT_VERSION_CHECK(6, 5, 0))
    QStyleHints * const styleHints = QGuiApplication::styleHints();
    Q_ASSERT(styleHints);
    if (styleHints) {
        connect(styleHints, &QStyleHints::colorSchemeChanged, this, [this](const Qt::ColorScheme colorScheme){
            Q_UNUSED(colorScheme);
            notifySystemThemeHasChangedOrNot();
        });
    }
#endif // (QT_VERSION >= QT_VERSION_CHECK(6, 5, 0))
    static bool flagSet = false;
    if (!flagSet) {
        flagSet = true;
        // Set a global flag so that people can check whether FramelessHelper is being
        // used without actually accessing the FramelessHelper interface.
        const int ver = FramelessHelper::Core::version().version;
        qputenv(kGlobalFlagVarName, QByteArray::number(ver));
        qApp->setProperty(kGlobalFlagVarName, ver);
    }
}

FramelessManager::FramelessManager(QObject *parent) :
    QObject(parent), d_ptr(new FramelessManagerPrivate(this))
{
}

FramelessManager::~FramelessManager() = default;

FramelessManager *FramelessManager::instance()
{
    return g_manager();
}

SystemTheme FramelessManager::systemTheme() const
{
    Q_D(const FramelessManager);
    return d->systemTheme();
}

QColor FramelessManager::systemAccentColor() const
{
    Q_D(const FramelessManager);
    return d->systemAccentColor();
}

QString FramelessManager::wallpaper() const
{
    Q_D(const FramelessManager);
    return d->wallpaper();
}

WallpaperAspectStyle FramelessManager::wallpaperAspectStyle() const
{
    Q_D(const FramelessManager);
    return d->wallpaperAspectStyle();
}

void FramelessManager::fillSystemParameters(QWidget *widget, SystemParameters &params)
{
    if(!widget) return;

    auto window = widget->window();
    if(!params.getWindowId) {
        params.getWindowId = [window]() -> WId { return window->winId(); };
    }
    if(!params.getWindowFlags) {
        params.getWindowFlags = [window]() -> Qt::WindowFlags { return window->windowFlags(); };
    }
    if(!params.setWindowFlags) {
        params.setWindowFlags = [window](const Qt::WindowFlags flags) -> void { window->setWindowFlags(flags); };
    }
    if(!params.getWindowSize) {
        params.getWindowSize = [window]() -> QSize { return window->size(); };
    }
    if(!params.setWindowSize) {
        params.setWindowSize = [window](const QSize &size) -> void { window->resize(size); };
    }
    if(!params.getWindowPosition) {
        params.getWindowPosition = [window]() -> QPoint { return window->pos(); };
    }
    if(!params.setWindowPosition) {
        params.setWindowPosition = [window](const QPoint &pos) -> void { window->move(pos); };
    }
    if(!params.setProperty) {
        params.setProperty = [window](const QByteArray &name, const QVariant &value) -> void { window->setProperty(name.data(), value); };
    }
    if(!params.getProperty) {
        params.getProperty = [window](const QByteArray &name, const QVariant &defaultValue) -> QVariant {
            auto v = window->property(name.data());
            return v.isValid() ? v : defaultValue;
        };
    }
    if(!params.setCursor) {
        params.setCursor = [window](const QCursor &cursor) -> void { window->setCursor(cursor); };
    }
    if(!params.unsetCursor) {
        params.unsetCursor = [window]() -> void { window->unsetCursor(); };
    }
    if(!params.getWidgetHandle) {
        params.getWidgetHandle = [window]() -> QObject * { return window; };
    }
    if(!params.getWindowScreen) {
        params.getWindowScreen = [window]() -> QScreen * {
#if (QT_VERSION >= QT_VERSION_CHECK(5, 14, 0))
            return window->screen();
#else
            return window->windowHandle()->screen();
#endif
        };
    }

    auto isWindowFixedSize = [window]() -> bool {
        if(window->windowFlags() & Qt::MSWindowsFixedSizeDialogHint) return true;

        const auto minSize = window->minimumSize();
        const auto maxSize = window->maximumSize();

        if(!minSize.isEmpty() && !maxSize.isEmpty() && (minSize == maxSize)) return true;

        if(window->sizePolicy() == QSizePolicy(QSizePolicy::Fixed, QSizePolicy::Fixed)) return true;

        return false;
    };
    if(!params.isWindowFixedSize) {
        params.isWindowFixedSize = [isWindowFixedSize] { return isWindowFixedSize(); };
    }
    if(!params.setWindowFixedSize) {
        params.setWindowFixedSize = [window, isWindowFixedSize](const bool value) -> void {
            if(isWindowFixedSize() == value) return;

            if(value) {
                window->setFixedSize(window->size());
            } else {
                window->setMinimumSize(kDefaultWindowSize);
                window->setMaximumSize(QSize(QWIDGETSIZE_MAX, QWIDGETSIZE_MAX));
            }
#ifdef Q_OS_WINDOWS
            Utils::setAeroSnappingEnabled(window->winId(), !value);
#endif
            // emitSignalForAllInstances(FRAMELESSHELPER_BYTEARRAY_LITERAL("windowFixedSizeChanged"));
        };
    }
    if(!params.getWindowState) {
        params.getWindowState = [window]() -> Qt::WindowState { return Utils::windowStatesToWindowState(window->windowState()); };
    }
    if(!params.setWindowState) {
        params.setWindowState = [window](const Qt::WindowState state) -> void { window->setWindowState(state); };
    }
    if(!params.getWindowHandle) {
        params.getWindowHandle = [window]() -> QWindow * { return window->windowHandle(); };
    }
    if(!params.windowToScreen) {
        params.windowToScreen = [window](const QPoint &pos) -> QPoint { return window->mapToGlobal(pos); };
    }
    if(!params.screenToWindow) {
        params.screenToWindow = [window](const QPoint &pos) -> QPoint { return window->mapFromGlobal(pos); };
    }
    if(!params.isInsideSystemButtons) {
        params.isInsideSystemButtons = [/*window*/](const QPoint &/*pos*/, SystemButtonType *button) -> bool {
            *button = SystemButtonType::Unknown;
            return false;
        };
    }
    if(!params.isInsideTitleBarDraggableArea) {
        params.isInsideTitleBarDraggableArea = [/*window*/](const QPoint &/*pos*/) -> bool { return false; };
    }
    if(!params.getWindowDevicePixelRatio) {
        params.getWindowDevicePixelRatio = [window]() -> qreal { return window->devicePixelRatioF(); };
    }
    if(!params.setSystemButtonState) {
        params.setSystemButtonState = [/*window*/](const SystemButtonType /*button*/, const ButtonState /*state*/) -> void { };
    }
    if(!params.shouldIgnoreMouseEvents) {
        params.shouldIgnoreMouseEvents = [window](const QPoint &pos) -> bool {
            const auto withinFrameBorder = [window, &pos]() -> bool {
                if (pos.y() < kDefaultResizeBorderThickness) {
                    return true;
                }
#ifdef Q_OS_WINDOWS
                if (Utils::isWindowFrameBorderVisible()) {
                    return false;
                }
#endif
                return ((pos.x() < Global::kDefaultResizeBorderThickness)
                        || (pos.x() >= (window->width() - Global::kDefaultResizeBorderThickness)));
            }();

            return ((Utils::windowStatesToWindowState(window->windowState()) == Qt::WindowNoState) && withinFrameBorder);
        };
    }
    if(!params.showSystemMenu) {
        params.showSystemMenu = [/*window*/](const QPoint &/*pos*/) -> void {  };
    }
}

void FramelessManager::addWindow(FramelessParamsConst params)
{
    Q_D(FramelessManager);
    d->addWindow(params);
}

void FramelessManager::removeWindow(QWindow *window)
{
    Q_D(FramelessManager);
    d->removeWindow(window);
}

void FramelessManager::setOverrideTheme(const SystemTheme theme)
{
    Q_D(FramelessManager);
    d->setOverrideTheme(theme);
}

FRAMELESSHELPER_END_NAMESPACE
