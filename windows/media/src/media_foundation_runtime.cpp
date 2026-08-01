#include "media_foundation_runtime.h"

#include <mfapi.h>

#include <cstddef>
#include <mutex>
#include <new>
#include <optional>
#include <utility>

namespace hmw::internal {
namespace {

std::mutex runtime_mutex;
size_t runtime_references = 0;

}  // namespace

MediaFoundationRuntime::~MediaFoundationRuntime() {
  std::lock_guard<std::mutex> lock(runtime_mutex);
  if (runtime_references == 0) {
    return;
  }
  --runtime_references;
  if (runtime_references == 0) {
    MFShutdown();
  }
}

Result<std::shared_ptr<MediaFoundationRuntime>>
AcquireMediaFoundationRuntime() {
  std::lock_guard<std::mutex> lock(runtime_mutex);
  if (runtime_references == 0) {
    const HRESULT result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(result)) {
      return Result<std::shared_ptr<MediaFoundationRuntime>>{
          std::nullopt,
          Error{Status::kDecodeFailed,
                "Media Foundation runtime initialization failed"}};
    }
  }
  try {
    std::shared_ptr<MediaFoundationRuntime> runtime(
        new MediaFoundationRuntime());
    ++runtime_references;
    return Result<std::shared_ptr<MediaFoundationRuntime>>{
        std::move(runtime), std::nullopt};
  } catch (const std::bad_alloc&) {
    if (runtime_references == 0) {
      MFShutdown();
    }
    return Result<std::shared_ptr<MediaFoundationRuntime>>{
        std::nullopt,
        Error{Status::kIoError,
              "Media Foundation runtime token allocation failed"}};
  }
}

}  // namespace hmw::internal
