#include "honey_media_windows/platform_dispatcher.h"

#ifdef _WIN32

#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <list>
#include <mutex>
#include <optional>
#include <unordered_map>
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

class PendingCallbackRegistry;

class ActiveOwnerScope {
 public:
  explicit ActiveOwnerScope(OwnerId owner) noexcept
      : owner_(owner), previous_(current_) {
    current_ = this;
  }

  ~ActiveOwnerScope() { current_ = previous_; }

  ActiveOwnerScope(const ActiveOwnerScope&) = delete;
  ActiveOwnerScope& operator=(const ActiveOwnerScope&) = delete;

  static size_t Depth(OwnerId owner) noexcept {
    size_t depth = 0;
    for (const ActiveOwnerScope* current = current_; current != nullptr;
         current = current->previous_) {
      if (current->owner_ == owner) {
        ++depth;
      }
    }
    return depth;
  }

 private:
  OwnerId owner_;
  ActiveOwnerScope* previous_;
  static thread_local ActiveOwnerScope* current_;
};

thread_local ActiveOwnerScope* ActiveOwnerScope::current_ = nullptr;

class ExecutionLease {
 public:
  ExecutionLease(PendingCallbackRegistry& registry, OwnerId owner,
                 OwnedCallback callback) noexcept
      : registry_(&registry), owner_(owner), callback_(std::move(callback)) {}

  ExecutionLease(ExecutionLease&& other) noexcept
      : registry_(std::exchange(other.registry_, nullptr)),
        owner_(other.owner_),
        callback_(std::move(other.callback_)) {}

  ExecutionLease(const ExecutionLease&) = delete;
  ExecutionLease& operator=(const ExecutionLease&) = delete;
  ExecutionLease& operator=(ExecutionLease&&) = delete;
  ~ExecutionLease();

  void Execute() noexcept;

 private:
  void Release() noexcept;

  PendingCallbackRegistry* registry_;
  OwnerId owner_;
  OwnedCallback callback_;
};

class PendingCallbackRegistry {
 public:
  OwnerId CreateOwner() {
    std::lock_guard<std::mutex> lock(mutex_);
    OwnerId owner = 0;
    do {
      owner = next_owner_++;
      if (next_owner_ == 0) {
        next_owner_ = 1;
      }
    } while (owner == 0 || owners_.find(owner) != owners_.end());
    owners_.emplace(owner, OwnerState{});
    return owner;
  }

  std::optional<DispatchToken> Add(OwnerId owner, OwnedCallback callback) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto owner_state = owners_.find(owner);
    if (owner_state == owners_.end() || owner_state->second.closing) {
      return std::nullopt;
    }
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

  std::optional<ExecutionLease> Take(DispatchToken token) {
    std::optional<ExecutionLease> lease;
    std::optional<OwnedCallback> rejected;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto found = Find(token);
      if (found == pending_.end()) {
        return std::nullopt;
      }
      const auto owner_state = owners_.find(found->owner);
      if (owner_state == owners_.end() || owner_state->second.closing) {
        rejected.emplace(std::move(found->callback));
      } else {
        ++owner_state->second.in_flight;
        lease.emplace(*this, found->owner, std::move(found->callback));
      }
      pending_.erase(found);
    }
    return lease;
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

  void CloseOwner(OwnerId owner) {
    std::list<PendingCallback> removed;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto owner_state = owners_.find(owner);
      if (owner_state == owners_.end()) {
        return;
      }
      owner_state->second.closing = true;
      for (auto current = pending_.begin(); current != pending_.end();) {
        if (current->owner != owner) {
          ++current;
          continue;
        }
        const auto owned = current++;
        removed.splice(removed.end(), pending_, owned);
      }
    }
    // User captures may run destructors that re-enter this registry.
    removed.clear();

    // A callback may destroy its own dispatcher. Wait for every other thread,
    // but let leases already active on this thread unwind naturally.
    const size_t current_thread_depth = ActiveOwnerScope::Depth(owner);
    std::unique_lock<std::mutex> lock(mutex_);
    condition_.wait(lock, [&] {
      const auto owner_state = owners_.find(owner);
      return owner_state == owners_.end() ||
             owner_state->second.in_flight <= current_thread_depth;
    });
    const auto owner_state = owners_.find(owner);
    if (owner_state != owners_.end() && owner_state->second.in_flight == 0) {
      owners_.erase(owner_state);
    }
  }

  void Complete(OwnerId owner) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto owner_state = owners_.find(owner);
      if (owner_state == owners_.end()) {
        return;
      }
      if (owner_state->second.in_flight != 0) {
        --owner_state->second.in_flight;
      }
      if (owner_state->second.closing &&
          owner_state->second.in_flight == 0) {
        owners_.erase(owner_state);
      }
    }
    condition_.notify_all();
  }

 private:
  struct OwnerState {
    bool closing = false;
    size_t in_flight = 0;
  };

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
  std::condition_variable condition_;
  std::list<PendingCallback> pending_;
  std::unordered_map<OwnerId, OwnerState> owners_;
  OwnerId next_owner_ = 1;
  DispatchToken next_token_ = 1;
};

ExecutionLease::~ExecutionLease() {
  if (registry_ != nullptr) {
    ActiveOwnerScope active_owner(owner_);
    Release();
  }
}

void ExecutionLease::Execute() noexcept {
  if (registry_ == nullptr) {
    return;
  }
  ActiveOwnerScope active_owner(owner_);
  try {
    callback_();
  } catch (...) {
  }
  Release();
}

void ExecutionLease::Release() noexcept {
  if (registry_ == nullptr) {
    return;
  }
  // Destroy callback captures before notifying teardown, and without holding
  // the registry mutex.
  callback_ = OwnedCallback{};
  PendingCallbackRegistry* registry =
      std::exchange(registry_, nullptr);
  try {
    registry->Complete(owner_);
  } catch (...) {
  }
}

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
  PendingCallbacks().CloseOwner(owner_id_);
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
  std::optional<ExecutionLease> callback =
      PendingCallbacks().Take(TokenFromMessage(lparam));
  if (!callback) {
    return LRESULT{0};
  }
  callback->Execute();
  return LRESULT{0};
}

}  // namespace hmw

#endif
