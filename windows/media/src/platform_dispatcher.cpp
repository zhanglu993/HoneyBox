#include "honey_media_windows/platform_dispatcher.h"

#ifdef _WIN32

#include <memory>
#include <new>
#include <utility>

namespace hmw {
namespace {

constexpr UINT kCallbackMessage = WM_APP + 0x41U;
constexpr WPARAM kCallbackCookie = static_cast<WPARAM>(0x484d5755U);

using OwnedCallback = std::function<void()>;

}  // namespace

Win32PlatformDispatcher::Win32PlatformDispatcher(HWND window)
    : Win32PlatformDispatcher(
          window, [](HWND target, UINT message, WPARAM wparam, LPARAM lparam) {
            return PostMessageW(target, message, wparam, lparam) != FALSE;
          }) {}

Win32PlatformDispatcher::Win32PlatformDispatcher(
    HWND window, PostWindowMessage post_message)
    : window_(window), post_message_(std::move(post_message)) {}

bool Win32PlatformDispatcher::Post(std::function<void()> callback) {
  if (window_ == nullptr || !post_message_ || !callback) {
    return false;
  }
  std::unique_ptr<OwnedCallback> owned(
      new (std::nothrow) OwnedCallback(std::move(callback)));
  if (!owned) {
    return false;
  }
  bool posted = false;
  try {
    posted = post_message_(window_, kCallbackMessage, kCallbackCookie,
                           reinterpret_cast<LPARAM>(owned.get()));
  } catch (...) {
    return false;
  }
  if (!posted) {
    return false;
  }
  owned.release();
  return true;
}

std::optional<LRESULT> Win32PlatformDispatcher::HandleMessage(
    UINT message, WPARAM wparam, LPARAM lparam) {
  if (message != kCallbackMessage || wparam != kCallbackCookie ||
      lparam == 0) {
    return std::nullopt;
  }
  std::unique_ptr<OwnedCallback> callback(
      reinterpret_cast<OwnedCallback*>(lparam));
  try {
    (*callback)();
  } catch (...) {
  }
  return LRESULT{0};
}

}  // namespace hmw

#endif
