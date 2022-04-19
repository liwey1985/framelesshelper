/*
 * MIT License
 *
 * Copyright (C) 2022 by wangwenx190 (Yuhang Zhao)
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

#include "framelesshelper_qt.h"
#include <QtCore/qmutex.h>
#include <QtGui/qevent.h>
#include <QtGui/qwindow.h>
#include "framelesswindowsmanager.h"
#include "framelesswindowsmanager_p.h"
#include "utils.h"

FRAMELESSHELPER_BEGIN_NAMESPACE

using namespace Global;

struct QtHelperData
{
    UserSettings settings = {};
    SystemParameters params = {};
    FramelessHelperQt *eventFilter = nullptr;
};

struct QtHelper
{
    QMutex mutex = {};
    QHash<WId, QtHelperData> data = {};
};

Q_GLOBAL_STATIC(QtHelper, g_qtHelper)

FramelessHelperQt::FramelessHelperQt(QObject *parent) : QObject(parent) {}

FramelessHelperQt::~FramelessHelperQt() = default;

void FramelessHelperQt::addWindow(const UserSettings &settings, const SystemParameters &params)
{
    Q_ASSERT(params.isValid());
    if (!params.isValid()) {
        return;
    }
    const WId windowId = params.getWindowId();
    g_qtHelper()->mutex.lock();
    if (g_qtHelper()->data.contains(windowId)) {
        g_qtHelper()->mutex.unlock();
        return;
    }
    QtHelperData data = {};
    data.settings = settings;
    data.params = params;
    QWindow *window = params.getWindowHandle();
    // Give it a parent so that it can be deleted even if we forget to do so.
    data.eventFilter = new FramelessHelperQt(window);
    g_qtHelper()->data.insert(windowId, data);
    g_qtHelper()->mutex.unlock();
#ifndef Q_OS_MACOS
    params.setWindowFlags(params.getWindowFlags() | Qt::FramelessWindowHint);
#endif
    window->installEventFilter(data.eventFilter);
#ifdef Q_OS_MACOS
    Utils::setSystemTitleBarVisible(windowId, false);
#endif
}

bool FramelessHelperQt::eventFilter(QObject *object, QEvent *event)
{
    Q_ASSERT(object);
    Q_ASSERT(event);
    if (!object || !event) {
        return false;
    }
    // First detect whether we got a theme change event or not, if so,
    // inform the user the system theme has changed.
    if (Utils::isThemeChangeEvent(event)) {
        FramelessWindowsManager *manager = FramelessWindowsManager::instance();
        FramelessWindowsManagerPrivate *managerPriv = FramelessWindowsManagerPrivate::get(manager);
        managerPriv->notifySystemThemeHasChangedOrNot();
        return false;
    }
    // Only monitor window events.
    if (!object->isWindowType()) {
        return false;
    }
    const QEvent::Type type = event->type();
    // We are only interested in mouse events.
    if ((type != QEvent::MouseButtonPress) && (type != QEvent::MouseMove)) {
        return false;
    }
    const auto window = qobject_cast<QWindow *>(object);
    const WId windowId = window->winId();
    g_qtHelper()->mutex.lock();
    if (!g_qtHelper()->data.contains(windowId)) {
        g_qtHelper()->mutex.unlock();
        return false;
    }
    const QtHelperData data = g_qtHelper()->data.value(windowId);
    g_qtHelper()->mutex.unlock();
    if (data.params.isWindowFixedSize()) {
        return false;
    }
    const auto mouseEvent = static_cast<QMouseEvent *>(event);
#if (QT_VERSION >= QT_VERSION_CHECK(6, 0, 0))
    const QPoint scenePos = mouseEvent->scenePosition().toPoint();
    const QPoint globalPos = mouseEvent->globalPosition().toPoint();
#else
    const QPoint scenePos = mouseEvent->windowPos().toPoint();
    const QPoint globalPos = mouseEvent->screenPos().toPoint();
#endif
    switch (type) {
    case QEvent::MouseMove: {
        if (data.settings.options & Option::DontTouchCursorShape) {
            return false;
        }
        const Qt::CursorShape cs = Utils::calculateCursorShape(window, scenePos);
        if (cs == Qt::ArrowCursor) {
            window->unsetCursor();
        } else {
            window->setCursor(cs);
        }
    } break;
    case QEvent::MouseButtonPress: {
        if (mouseEvent->button() != Qt::LeftButton) {
            return false;
        }
        const Qt::Edges edges = Utils::calculateWindowEdges(window, scenePos);
        if (edges == Qt::Edges{}) {
            return false;
        }
        Utils::startSystemResize(window, edges, globalPos);
        return true;
    }
    default:
        break;
    }
    return false;
}

FRAMELESSHELPER_END_NAMESPACE
