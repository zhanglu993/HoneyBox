#pragma once

#ifdef _WIN32

#include <windows.h>

#include <functional>

namespace hmw::internal {

using AttachFlutterView = std::function<void(HWND)>;
using RegisterFlutterPlugin = std::function<void()>;
void AttachFlutterViewAndRegisterPlugin(
    HWND flutter_view, const AttachFlutterView& attach_view,
    const RegisterFlutterPlugin& register_plugin);

HWND ResolvePluginDispatchWindow(HWND flutter_view) noexcept;

}  // namespace hmw::internal

#endif
