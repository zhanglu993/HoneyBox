#include "honey_media_windows/platform_dispatcher.h"

#ifdef _WIN32

#include <algorithm>
#include <cstdint>
#include <list>
#include <mutex>
#include <optional>
#include <utility>

namespace hmw {
namespace {

constexpr UINT kCallbackMessage = WM_APP + 0x41U;
constexpr WPARAM kCallbackCookie = static_cast<WPARAM>(0x484d5755U);

using DispatchToken = uint64_t;
using OwnerId = uint64_t;
using OwnedCallback = std::function<void()>;

static_assert(sizeof(DispatchToken) <= sizeof(LPARAM),
              "Win32 dispatcher requires a 64-bit LPARAM");

class PendingCallbackRegistry {
 public:
  OwnerId CreateOwner() {
    std::lock_guard<std::mutex> lock(mutex_);
    const OwnerId owner = next_owner_++;
    if (next_owner_ == 0) {
      next_owner_ = 1;
    }
    return owner;
  }

  std::optional<DispatchToken> Add(OwnerId owner, OwnedCallback callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    DispatchToken token = 0;
    do {
      token = next_token_++;
      if (next_token_ == 0) {
        next_token_ = 1;
      }
    } while (token == 0 || Find(token) != pending_.end());
    pending_.push_back(
        PendingCallback{token, owner, std::move(callback)});
    return token;
  }

  std::optional<OwnedCallback> Take(DispatchToken token) {
    std::optional<OwnedCallback> callback;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto found = Find(token);
      if (found == pending_.end()) {
        return std::nullopt;
      }
      callback.emplace(std::move(found->callback));
      pending_.erase(found);
    }
    return callback;
  }

  void Remove(OwnerId owner, DispatchToken token) {
    std::optional<OwnedCallback> removed;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto found = Find(token);
      if (found == pending_.end() || found->owner != owner) {
        return;
      }
      removed.emplace(std::move(found->callback));
      pending_.erase(found);
    }
  }

  void RemoveOwner(OwnerId owner) {
    std::list<PendingCallback> removed;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (auto current = pending_.begin(); current != pending_.end();) {
        if (current->owner != owner) {
          ++current;
          continue;
        }
        const auto owned = current++;
        removed.splice(removed.end(), pending_, owned);
      }
    }
  }

 private:
  struct PendingCallback {
    DispatchToken token;
    OwnerId owner;
    OwnedCallback callback;
  };

  using Iterator = std::list<PendingCallback>::iterator;

  Iterator Find(DispatchToken token) {
    return std::find_if(
        pending_.begin(), pending_.end(),
        [token](const PendingCallback& pending) {
          return pending.token == token;
        });
  }

  std::mutex mutex_;
  std::list<PendingCallback> pending_;
  OwnerId next_owner_ = 1;
  DispatchToken next_token_ = 1;
};

PendingCallbackRegistry& PendingCallbacks() {
  static PendingCallbackRegistry registry;
  return registry;
}

DispatchToken TokenFromMessage(LPARAM lparam) {
  return static_cast<DispatchToken>(static_cast<ULONG_PTR>(lparam));
}

LPARAM TokenToMessage(DispatchToken token) {
  return static_cast<LPARAM>(static_cast<ULONG_PTR>(token));
}

}  // namespace

Win32PlatformDispatcher::Win32PlatformDispatcher(HWND window)
    : Win32PlatformDispatcher(
          window, [](HWND target, UINT message, WPARAM wparam, LPARAM lparam) {
            return PostMessageW(target, message, wparam, lparam) != FALSE;
          }) {}

Win32PlatformDispatcher::Win32PlatformDispatcher(
    HWND window, PostWindowMessage post_message)
    : window_(window),
      post_message_(std::move(post_message)),
      owner_id_(PendingCallbacks().CreateOwner()) {}

Win32PlatformDispatcher::~Win32PlatformDispatcher() {
  PendingCallbacks().RemoveOwner(owner_id_);
}

bool Win32PlatformDispatcher::Post(std::function<void()> callback) {
  if (window_ == nullptr || !post_message_ || !callback) {
    return false;
  }
  std::optional<DispatchToken> token;
  try {
    token = PendingCallbacks().Add(owner_id_, std::move(callback));
  } catch (...) {
    return false;
  }
  if (!token) {
    return false;
  }

  bool posted = false;
  try {
    posted = post_message_(window_, kCallbackMessage, kCallbackCookie,
                           TokenToMessage(*token));
  } catch (...) {
    PendingCallbacks().Remove(owner_id_, *token);
    return false;
  }
  if (!posted) {
    PendingCallbacks().Remove(owner_id_, *token);
    return false;
  }
  return true;
}

std::optional<LRESULT> Win32PlatformDispatcher::HandleMessage(
    UINT message, WPARAM wparam, LPARAM lparam) {
  if (message != kCallbackMessage || wparam != kCallbackCookie) {
    return std::nullopt;
  }
  std::optional<OwnedCallback> callback =
      PendingCallbacks().Take(TokenFromMessage(lparam));
  if (!callback) {
    return LRESULT{0};
  }
  try {
    (*callback)();
  } catch (...) {
  }
  return LRESULT{0};
}

}  // namespace hmw

#endif
