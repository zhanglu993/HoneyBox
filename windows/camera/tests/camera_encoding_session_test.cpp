#include "honey_camera_windows/camera_encoding_session.h"

#include "test_support.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace std::chrono_literals;

struct EncodeCall {
  uint8_t marker;
  uint32_t width;
  uint32_t height;
  int64_t pts_100ns;
  int64_t duration_100ns;
  size_t rgba_size;
};

class FakeBackendState final {
 public:
  hmw::Outcome Start(const hmw::EncodingConfig& config) {
    std::lock_guard<std::mutex> lock(mutex_);
    backend_threads_.push_back(std::this_thread::get_id());
    config_ = config;
    trace_.push_back("start");
    condition_.notify_all();
    return {};
  }

  hmw::Result<std::vector<hmw::EncodedFrame>> Encode(
      const hmw::EncoderInputFrame& input) {
    std::unique_lock<std::mutex> lock(mutex_);
    backend_threads_.push_back(std::this_thread::get_id());
    const uint8_t marker = input.rgba_size == 0U ? 0U : input.rgba[0];
    encodes_.push_back({marker, input.width, input.height, input.pts_100ns,
                        input.duration_100ns, input.rgba_size});
    trace_.push_back("encode:" + std::to_string(marker));
    condition_.notify_all();
    condition_.wait(lock, [this] { return !block_encode_ || release_encode_; });
    if (encode_error_) {
      return {std::nullopt,
              hmw::Error{hmw::Status::kEncodeFailed, "fake encode failed"}};
    }
    const auto bytes = std::make_shared<const std::vector<uint8_t>>(
        std::vector<uint8_t>{marker});
    std::vector<hmw::EncodedFrame> frames{
        {bytes, input.pts_100ns, false}};
    if (return_extra_frame_) {
      frames.push_back({bytes, input.pts_100ns, false});
    }
    return {std::move(frames), std::nullopt};
  }

  hmw::Outcome RequestKeyframe() {
    std::lock_guard<std::mutex> lock(mutex_);
    backend_threads_.push_back(std::this_thread::get_id());
    trace_.push_back("key");
    condition_.notify_all();
    return {};
  }

  hmw::Result<std::vector<hmw::EncodedFrame>> Drain() {
    std::lock_guard<std::mutex> lock(mutex_);
    backend_threads_.push_back(std::this_thread::get_id());
    trace_.push_back("drain");
    condition_.notify_all();
    return {std::vector<hmw::EncodedFrame>{}, std::nullopt};
  }

  hmw::Outcome Stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    backend_threads_.push_back(std::this_thread::get_id());
    trace_.push_back("stop");
    ++stop_count_;
    condition_.notify_all();
    return {};
  }

  void BlockEncode() {
    std::lock_guard<std::mutex> lock(mutex_);
    block_encode_ = true;
    release_encode_ = false;
  }

  void ReleaseEncode() {
    std::lock_guard<std::mutex> lock(mutex_);
    release_encode_ = true;
    condition_.notify_all();
  }

  void FailEncode() {
    std::lock_guard<std::mutex> lock(mutex_);
    encode_error_ = true;
  }

  void ReturnExtraFrame() {
    std::lock_guard<std::mutex> lock(mutex_);
    return_extra_frame_ = true;
  }

  void RecordFactoryThread() {
    std::lock_guard<std::mutex> lock(mutex_);
    factory_thread_ = std::this_thread::get_id();
  }

  void RecordDestructionThread() {
    std::lock_guard<std::mutex> lock(mutex_);
    destruction_thread_ = std::this_thread::get_id();
    condition_.notify_all();
  }

  bool WaitForDestruction() {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(
        lock, 2s, [this] { return destruction_thread_.has_value(); });
  }

  bool BackendStayedOnOneWorker(std::thread::id caller) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return factory_thread_.has_value() && destruction_thread_.has_value() &&
           *factory_thread_ == *destruction_thread_ &&
           *factory_thread_ != caller && !backend_threads_.empty() &&
           std::all_of(backend_threads_.begin(), backend_threads_.end(),
                       [&](std::thread::id id) { return id == *factory_thread_; });
  }

  bool WaitForEncodeCount(size_t count) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s,
                               [this, count] { return encodes_.size() >= count; });
  }

  std::vector<EncodeCall> encodes() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return encodes_;
  }

  std::vector<std::string> trace() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return trace_;
  }

  size_t stop_count() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stop_count_;
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::optional<hmw::EncodingConfig> config_;
  std::vector<EncodeCall> encodes_;
  std::vector<std::string> trace_;
  bool block_encode_ = false;
  bool release_encode_ = false;
  bool encode_error_ = false;
  bool return_extra_frame_ = false;
  size_t stop_count_ = 0;
  std::optional<std::thread::id> factory_thread_;
  std::optional<std::thread::id> destruction_thread_;
  std::vector<std::thread::id> backend_threads_;
};

class FakeBackend final : public hmw::EncoderBackend {
 public:
  explicit FakeBackend(std::shared_ptr<FakeBackendState> state)
      : state_(std::move(state)) {}
  ~FakeBackend() override { state_->RecordDestructionThread(); }

  hmw::Outcome Start(const hmw::EncodingConfig& config) override {
    return state_->Start(config);
  }
  hmw::Result<std::vector<hmw::EncodedFrame>> Encode(
      const hmw::EncoderInputFrame& input) override {
    return state_->Encode(input);
  }
  hmw::Outcome RequestKeyframe() override { return state_->RequestKeyframe(); }
  hmw::Result<std::vector<hmw::EncodedFrame>> Drain() override {
    return state_->Drain();
  }
  hmw::Outcome Stop() override { return state_->Stop(); }

 private:
  std::shared_ptr<FakeBackendState> state_;
};

hmw::EncoderBackendFactory FakeFactory(
    const std::shared_ptr<FakeBackendState>& state) {
  return [state](hmw::EncoderFormat)
             -> hmw::Result<std::unique_ptr<hmw::EncoderBackend>> {
    state->RecordFactoryThread();
    return {std::make_unique<FakeBackend>(state), std::nullopt};
  };
}

hmw::EncodingConfig H264Config(uint32_t width = 2U, uint32_t height = 1U,
                               uint32_t fps = 10U) {
  return {hmw::EncoderFormat::kH264, width, height, fps, 1'000'000U, 1U, 1.0,
          false, 0U, 90U, false, true};
}

hcw::CameraFrame Frame(uint8_t marker, int64_t pts_100ns,
                       uint32_t width = 2U, uint32_t height = 1U,
                       size_t rgba_size = 0U) {
  const size_t size = rgba_size == 0U
                          ? static_cast<size_t>(width) * height * 4U
                          : rgba_size;
  return {width, height, pts_100ns,
          std::make_shared<const std::vector<uint8_t>>(
              std::vector<uint8_t>(size, marker))};
}

class CallbackCapture final {
 public:
  hmw::EncoderCallbacks callbacks() {
    return {{},
            [this](uint64_t, hmw::EncodedFrame) {
              std::lock_guard<std::mutex> lock(mutex_);
              ++frames_;
              condition_.notify_all();
            },
            [this](uint64_t, hmw::EncodingStats stats) {
              std::lock_guard<std::mutex> lock(mutex_);
              stats_.push_back(stats);
              condition_.notify_all();
            },
            {},
            [this](uint64_t, hmw::Error) {
              std::lock_guard<std::mutex> lock(mutex_);
              ++errors_;
              condition_.notify_all();
            },
            {}};
  }

  bool WaitForErrors(size_t count) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s,
                               [this, count] { return errors_ >= count; });
  }

  bool WaitForStats(size_t count) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s,
                               [this, count] { return stats_.size() >= count; });
  }

  bool WaitForFrames(size_t count) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, 2s,
                               [this, count] { return frames_ >= count; });
  }

  size_t frames() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return frames_;
  }
  size_t errors() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return errors_;
  }
  std::vector<hmw::EncodingStats> stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  size_t frames_ = 0U;
  size_t errors_ = 0U;
  std::vector<hmw::EncodingStats> stats_;
};

}  // namespace

HMW_TEST(camera_encoding_session_starts_with_two_h264_permits_and_keeps_latest_slot) {
  const auto backend = std::make_shared<FakeBackendState>();
  backend->BlockEncode();
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), {}).ok());
  session.OfferFrame(7U, Frame(1U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  session.OfferFrame(7U, Frame(2U, 1'000'000));
  session.OfferFrame(7U, Frame(3U, 2'000'000));
  backend->ReleaseEncode();
  HMW_EXPECT(backend->WaitForEncodeCount(2U));
  const auto encodes = backend->encodes();
  HMW_EXPECT(encodes.size() == 2U);
  if (encodes.size() == 2U) {
    HMW_EXPECT(encodes[0].marker == 1U);
    HMW_EXPECT(encodes[1].marker == 3U);
  }
  session.OfferFrame(7U, Frame(4U, 3'000'000));
  HMW_EXPECT(!backend->WaitForEncodeCount(3U));
  session.GrantFramePermit();
  HMW_EXPECT(backend->WaitForEncodeCount(3U));
  const auto after_grant = backend->encodes();
  HMW_EXPECT(after_grant.size() == 3U);
  if (after_grant.size() == 3U) {
    HMW_EXPECT(after_grant[2].marker == 4U);
  }
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_ignores_stale_camera_generation) {
  const auto backend = std::make_shared<FakeBackendState>();
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), {}).ok());
  session.OfferFrame(6U, Frame(9U, 0));
  HMW_EXPECT(!backend->WaitForEncodeCount(1U));
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_suppresses_stale_encode_callback_after_stop) {
  const auto backend = std::make_shared<FakeBackendState>();
  backend->BlockEncode();
  CallbackCapture callbacks;
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), callbacks.callbacks()).ok());
  session.OfferFrame(7U, Frame(3U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  auto stopping = std::async(std::launch::async, [&] { return session.Stop(); });
  HMW_EXPECT(stopping.wait_for(50ms) == std::future_status::timeout);
  backend->ReleaseEncode();
  HMW_EXPECT(stopping.get().ok());
  HMW_EXPECT(callbacks.frames() == 0U);
}

HMW_TEST(camera_encoding_session_samples_fps_from_pts_not_wall_clock) {
  const auto backend = std::make_shared<FakeBackendState>();
  CallbackCapture callbacks;
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), callbacks.callbacks()).ok());
  session.OfferFrame(7U, Frame(1U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  session.OfferFrame(7U, Frame(2U, 1'000'000));
  HMW_EXPECT(backend->WaitForEncodeCount(2U));
  HMW_EXPECT(callbacks.WaitForStats(2U));
  const auto stats = callbacks.stats();
  HMW_EXPECT(stats.size() >= 2U);
  if (stats.size() >= 2U) {
    HMW_EXPECT(stats.back().fps == 10.0);
  }
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_serializes_key_request_before_next_encode) {
  const auto backend = std::make_shared<FakeBackendState>();
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), {}).ok());
  session.RequestKeyframe();
  session.OfferFrame(7U, Frame(5U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  const auto trace = backend->trace();
  HMW_EXPECT(trace.size() >= 3U);
  if (trace.size() >= 3U) {
    HMW_EXPECT(trace[0] == "start");
    HMW_EXPECT(trace[1] == "key");
    HMW_EXPECT(trace[2] == "encode:5");
  }
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_keeps_key_request_arriving_during_encode) {
  const auto backend = std::make_shared<FakeBackendState>();
  backend->BlockEncode();
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), {}).ok());
  session.OfferFrame(7U, Frame(1U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  session.RequestKeyframe();
  session.OfferFrame(7U, Frame(2U, 1'000'000));
  backend->ReleaseEncode();
  HMW_EXPECT(backend->WaitForEncodeCount(2U));
  const auto trace = backend->trace();
  HMW_EXPECT(trace.size() >= 4U);
  if (trace.size() >= 4U) {
    HMW_EXPECT(trace[1] == "encode:1");
    HMW_EXPECT(trace[2] == "key");
    HMW_EXPECT(trace[3] == "encode:2");
  }
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_drains_before_stopping_backend) {
  const auto backend = std::make_shared<FakeBackendState>();
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), {}).ok());
  HMW_EXPECT(session.Stop().ok());
  const auto trace = backend->trace();
  HMW_EXPECT(trace.size() == 3U);
  if (trace.size() == 3U) {
    HMW_EXPECT(trace[0] == "start");
    HMW_EXPECT(trace[1] == "drain");
    HMW_EXPECT(trace[2] == "stop");
  }
}

HMW_TEST(camera_encoding_session_reports_terminal_encode_error_once) {
  const auto backend = std::make_shared<FakeBackendState>();
  backend->FailEncode();
  CallbackCapture callbacks;
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), callbacks.callbacks()).ok());
  session.OfferFrame(7U, Frame(1U, 0));
  HMW_EXPECT(callbacks.WaitForErrors(1U));
  session.OfferFrame(7U, Frame(2U, 1'000'000));
  HMW_EXPECT(!backend->WaitForEncodeCount(2U));
  HMW_EXPECT(callbacks.errors() == 1U);
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_stop_is_idempotent_and_joins_worker) {
  const auto backend = std::make_shared<FakeBackendState>();
  backend->BlockEncode();
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), {}).ok());
  session.OfferFrame(7U, Frame(1U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  auto stopping = std::async(std::launch::async, [&] { return session.Stop(); });
  HMW_EXPECT(stopping.wait_for(50ms) == std::future_status::timeout);
  backend->ReleaseEncode();
  HMW_EXPECT(stopping.get().ok());
  HMW_EXPECT(session.Stop().ok());
  HMW_EXPECT(backend->stop_count() == 1U);
}

HMW_TEST(camera_encoding_session_rejects_mismatched_dimensions) {
  const auto backend = std::make_shared<FakeBackendState>();
  CallbackCapture callbacks;
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), callbacks.callbacks()).ok());
  session.OfferFrame(7U, Frame(1U, 0, 3U, 1U));
  HMW_EXPECT(callbacks.WaitForErrors(1U));
  HMW_EXPECT(!backend->WaitForEncodeCount(1U));
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_rejects_mismatched_rgba_size) {
  const auto backend = std::make_shared<FakeBackendState>();
  CallbackCapture callbacks;
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), callbacks.callbacks()).ok());
  session.OfferFrame(7U, Frame(2U, 0, 2U, 1U, 7U));
  HMW_EXPECT(callbacks.WaitForErrors(1U));
  HMW_EXPECT(!backend->WaitForEncodeCount(1U));
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_defaults_input_duration_from_configured_fps) {
  const auto backend = std::make_shared<FakeBackendState>();
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(2U, 1U, 20U), {}).ok());
  session.OfferFrame(7U, Frame(3U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  const auto encodes = backend->encodes();
  HMW_EXPECT(encodes.size() == 1U);
  if (encodes.size() == 1U) {
    HMW_EXPECT(encodes.front().width == 2U && encodes.front().height == 1U);
    HMW_EXPECT(encodes.front().rgba_size == 8U);
    HMW_EXPECT(encodes.front().duration_100ns == 500'000);
  }
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_jpeg_and_msv1_do_not_require_frame_permits) {
  for (const hmw::EncoderFormat format :
       {hmw::EncoderFormat::kJpeg, hmw::EncoderFormat::kMsv1}) {
    const auto backend = std::make_shared<FakeBackendState>();
    hcw::CameraEncodingSession session(FakeFactory(backend));
    auto config = H264Config();
    config.format = format;
    HMW_EXPECT(session.Start(7U, config, {}).ok());
    for (uint8_t marker = 1U; marker <= 3U; ++marker) {
      session.OfferFrame(
          7U, Frame(marker, static_cast<int64_t>(marker - 1U) * 1'000'000));
      HMW_EXPECT(backend->WaitForEncodeCount(marker));
    }
    HMW_EXPECT(session.Stop().ok());
  }
}

HMW_TEST(camera_encoding_session_h264_permits_saturate_at_two) {
  const auto backend = std::make_shared<FakeBackendState>();
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), {}).ok());
  for (size_t i = 0; i < 8U; ++i) {
    session.GrantFramePermit();
  }
  session.OfferFrame(7U, Frame(1U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  session.OfferFrame(7U, Frame(2U, 1'000'000));
  HMW_EXPECT(backend->WaitForEncodeCount(2U));
  session.OfferFrame(7U, Frame(3U, 2'000'000));
  HMW_EXPECT(!backend->WaitForEncodeCount(3U));
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_drops_pts_before_next_sampling_boundary) {
  const auto backend = std::make_shared<FakeBackendState>();
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), {}).ok());
  session.OfferFrame(7U, Frame(1U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  session.OfferFrame(7U, Frame(2U, 500'000));
  HMW_EXPECT(!backend->WaitForEncodeCount(2U));
  session.OfferFrame(7U, Frame(3U, 1'000'000));
  HMW_EXPECT(backend->WaitForEncodeCount(2U));
  const auto encodes = backend->encodes();
  HMW_EXPECT(encodes.size() == 2U);
  if (encodes.size() == 2U) {
    HMW_EXPECT(encodes[0].marker == 1U);
    HMW_EXPECT(encodes[1].marker == 3U);
  }
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_forwards_all_frames_returned_by_one_encode) {
  const auto backend = std::make_shared<FakeBackendState>();
  backend->ReturnExtraFrame();
  CallbackCapture callbacks;
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), callbacks.callbacks()).ok());
  session.OfferFrame(7U, Frame(4U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  HMW_EXPECT(callbacks.WaitForFrames(2U));
  HMW_EXPECT(callbacks.frames() == 2U);
  HMW_EXPECT(session.Stop().ok());
}

HMW_TEST(camera_encoding_session_backend_lifetime_stays_on_one_worker) {
  const std::thread::id caller = std::this_thread::get_id();
  const auto backend = std::make_shared<FakeBackendState>();
  hcw::CameraEncodingSession session(FakeFactory(backend));
  HMW_EXPECT(session.Start(7U, H264Config(), {}).ok());
  session.RequestKeyframe();
  session.OfferFrame(7U, Frame(1U, 0));
  HMW_EXPECT(backend->WaitForEncodeCount(1U));
  HMW_EXPECT(session.Stop().ok());
  HMW_EXPECT(backend->WaitForDestruction());
  HMW_EXPECT(backend->BackendStayedOnOneWorker(caller));
}
