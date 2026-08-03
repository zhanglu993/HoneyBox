#include "test_support.h"

#include "honey_media_windows/platform_dispatcher.h"
#include "windows_media_plugin_internal.h"

#include <chrono>
#include <cstdint>
#include <string>

namespace {

using namespace std::chrono_literals;

LRESULT CALLBACK RootWindowProc(HWND window, UINT message, WPARAM wparam,
                                LPARAM lparam) {
  const auto handled =
      hmw::Win32PlatformDispatcher::HandleMessage(message, wparam, lparam);
  if (handled.has_value()) {
    return *handled;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

LRESULT CALLBACK ChildWindowProc(HWND window, UINT message, WPARAM wparam,
                                 LPARAM lparam) {
  return DefWindowProcW(window, message, wparam, lparam);
}

class TestWindowPair final {
 public:
  TestWindowPair() {
    instance_ = GetModuleHandleW(nullptr);
    const uintptr_t suffix = reinterpret_cast<uintptr_t>(this);
    root_class_name_ = L"HmwDispatchRoot_" + std::to_wstring(suffix);
    child_class_name_ = L"HmwDispatchChild_" + std::to_wstring(suffix);
    root_class_ = Register(root_class_name_, &RootWindowProc);
    child_class_ = Register(child_class_name_, &ChildWindowProc);
    if (root_class_ == 0 || child_class_ == 0) {
      return;
    }
    root_ = CreateWindowExW(0, root_class_name_.c_str(), L"",
                            WS_OVERLAPPED, 0, 0, 1, 1, nullptr, nullptr,
                            instance_, nullptr);
    child_ = CreateWindowExW(0, child_class_name_.c_str(), L"",
                             WS_CHILD, 0, 0, 1, 1, GetDesktopWindow(), nullptr,
                             instance_, nullptr);
  }

  bool AttachChildToRoot() {
    if (child_ == nullptr || root_ == nullptr) {
      return false;
    }
    SetParent(child_, root_);
    return GetParent(child_) == root_;
  }

  ~TestWindowPair() {
    if (child_ != nullptr) {
      DestroyWindow(child_);
    }
    if (root_ != nullptr) {
      DestroyWindow(root_);
    }
    if (child_class_ != 0) {
      UnregisterClassW(child_class_name_.c_str(), instance_);
    }
    if (root_class_ != 0) {
      UnregisterClassW(root_class_name_.c_str(), instance_);
    }
  }

  TestWindowPair(const TestWindowPair&) = delete;
  TestWindowPair& operator=(const TestWindowPair&) = delete;

  HWND root() const noexcept { return root_; }
  HWND child() const noexcept { return child_; }

 private:
  ATOM Register(const std::wstring& class_name, WNDPROC window_proc) const {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = instance_;
    window_class.lpszClassName = class_name.c_str();
    return RegisterClassW(&window_class);
  }

  HINSTANCE instance_ = nullptr;
  std::wstring root_class_name_;
  std::wstring child_class_name_;
  ATOM root_class_ = 0;
  ATOM child_class_ = 0;
  HWND root_ = nullptr;
  HWND child_ = nullptr;
};

bool PumpUntil(bool& completed, std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (!completed && std::chrono::steady_clock::now() < deadline) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE) != FALSE) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    if (!completed) {
      Sleep(1);
    }
  }
  return completed;
}

}  // namespace

HMW_TEST(win32_dispatch_window_routes_child_view_callbacks_to_root_delegate) {
  TestWindowPair windows;
  HMW_EXPECT(windows.root() != nullptr);
  HMW_EXPECT(windows.child() != nullptr);
  if (windows.root() == nullptr || windows.child() == nullptr) {
    return;
  }
  HMW_EXPECT(windows.AttachChildToRoot());

  const HWND dispatch_window =
      hmw::internal::ResolvePluginDispatchWindow(windows.child());
  HMW_EXPECT(dispatch_window == windows.root());

  hmw::Win32PlatformDispatcher dispatcher(dispatch_window);
  bool callback_completed = false;
  uint32_t callback_calls = 0;
  HMW_EXPECT(dispatcher.Post(
      [&] { ++callback_calls; callback_completed = true; }));
  HMW_EXPECT(PumpUntil(callback_completed, 250ms));
  HMW_EXPECT(callback_calls == 1);
}

HMW_TEST(win32_dispatch_window_keeps_root_window) {
  TestWindowPair windows;
  HMW_EXPECT(windows.root() != nullptr);
  if (windows.root() != nullptr) {
    HMW_EXPECT(hmw::internal::ResolvePluginDispatchWindow(windows.root()) ==
               windows.root());
  }
}

HMW_TEST(win32_dispatch_window_keeps_null_window) {
  HMW_EXPECT(hmw::internal::ResolvePluginDispatchWindow(nullptr) == nullptr);
}

HMW_TEST(win32_dispatch_window_falls_back_for_invalid_window) {
  const HWND invalid =
      reinterpret_cast<HWND>(static_cast<uintptr_t>(1));
  HMW_EXPECT(hmw::internal::ResolvePluginDispatchWindow(invalid) == invalid);
}

HMW_TEST(win32_dispatch_window_attaches_view_before_plugin_registration) {
  TestWindowPair windows;
  HMW_EXPECT(windows.root() != nullptr);
  HMW_EXPECT(windows.child() != nullptr);
  if (windows.root() == nullptr || windows.child() == nullptr) {
    return;
  }
  const HWND before_attach =
      hmw::internal::ResolvePluginDispatchWindow(windows.child());
  HMW_EXPECT(before_attach != windows.root());

  uint32_t sequence = 0;
  HWND resolved_at_registration = nullptr;
  hmw::internal::AttachFlutterViewAndRegisterPlugin(
      windows.child(),
      [&](HWND view) {
        HMW_EXPECT(sequence == 0);
        HMW_EXPECT(view == windows.child());
        sequence = 1;
        HMW_EXPECT(windows.AttachChildToRoot());
      },
      [&] {
        HMW_EXPECT(sequence == 1);
        sequence = 2;
        resolved_at_registration =
            hmw::internal::ResolvePluginDispatchWindow(windows.child());
      });
  HMW_EXPECT(sequence == 2);
  HMW_EXPECT(resolved_at_registration == windows.root());
}
