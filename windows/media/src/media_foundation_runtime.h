#pragma once

#include "honey_media_windows/status.h"

#include <memory>

namespace hmw::internal {

class MediaFoundationRuntime final {
 public:
  ~MediaFoundationRuntime();

  MediaFoundationRuntime(const MediaFoundationRuntime&) = delete;
  MediaFoundationRuntime& operator=(const MediaFoundationRuntime&) = delete;

 private:
  MediaFoundationRuntime() = default;

  friend Result<std::shared_ptr<MediaFoundationRuntime>>
  AcquireMediaFoundationRuntime();
};

Result<std::shared_ptr<MediaFoundationRuntime>>
AcquireMediaFoundationRuntime();

}  // namespace hmw::internal
