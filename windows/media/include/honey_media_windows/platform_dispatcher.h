#pragma once

#include <functional>

#ifdef _WIN32
#include <Windows.h>

#include <optional>
#endif

namespace hmw {

class PlatformDispatcher {
 public:
  virtual ~PlatformDispatcher() = default;
  virtual bool Post(std::function<void()> callback) = 0;
};

#ifdef _WIN32
class Win32PlatformDispatcher final : public PlatformDispatcher {
 public:
  using PostWindowMessage =
      std::function<bool(HWND, UINT, WPARAM, LPARAM)>;

  explicit Win32PlatformDispatcher(HWND window);
  Win32PlatformDispatcher(HWND window, PostWindowMessage post_message);

  bool Post(std::function<void()> callback) override;

  static std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                               LPARAM lparam);

 private:
  HWND window_;
  PostWindowMessage post_message_;
};
#endif

}  // namespace hmw
