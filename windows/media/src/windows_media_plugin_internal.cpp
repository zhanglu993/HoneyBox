#include "windows_media_plugin_internal.h"

#ifdef _WIN32

namespace hmw::internal {

void AttachFlutterViewAndRegisterPlugin(
    HWND flutter_view, const AttachFlutterView& attach_view,
    const RegisterFlutterPlugin& register_plugin) {
  attach_view(flutter_view);
  register_plugin();
}

HWND ResolvePluginDispatchWindow(HWND flutter_view) noexcept {
  if (flutter_view == nullptr) {
    return nullptr;
  }
  const HWND root = GetAncestor(flutter_view, GA_ROOT);
  return root == nullptr ? flutter_view : root;
}

}  // namespace hmw::internal

#endif
