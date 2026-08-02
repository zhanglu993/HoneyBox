#pragma once

#include <cstdint>
#include <functional>

#ifdef _WIN32
#include <Windows.h>

#include <optional>
#endif

namespace hmw {

class PlatformDispatcher {
 public:
  virtual ~PlatformDispatcher() = default;

  // Enqueues callback for later execution on the platform thread. Implementors
  // must not invoke callback before Post returns and must not throw. Returning
  // true transfers callback ownership to the dispatcher; returning false must
  // release it before returning.
  virtual bool Post(std::function<void()> callback) = 0;
};

#ifdef _WIN32
class Win32PlatformDispatcher final : public PlatformDispatcher {
 public:
  using PostWindowMessage =
      std::function<bool(HWND, UINT, WPARAM, LPARAM)>;

  explicit Win32PlatformDispatcher(HWND window);
  Win32PlatformDispatcher(HWND window, PostWindowMessage post_message);
  ~Win32PlatformDispatcher() override;

  Win32PlatformDispatcher(const Win32PlatformDispatcher&) = delete;
  Win32PlatformDispatcher& operator=(const Win32PlatformDispatcher&) = delete;
  Win32PlatformDispatcher(Win32PlatformDispatcher&&) = delete;
  Win32PlatformDispatcher& operator=(Win32PlatformDispatcher&&) = delete;

  bool Post(std::function<void()> callback) override;

  static std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                               LPARAM lparam);

 private:
  HWND window_;
  PostWindowMessage post_message_;
  uint64_t owner_id_;
};
#endif

}  // namespace hmw
