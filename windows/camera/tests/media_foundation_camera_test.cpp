#include "media_foundation_camera_internal.h"

#include "test_support.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using namespace std::chrono_literals;
using hcw::internal::BgraBufferView;
using hcw::internal::CaptureMode;

HMW_TEST(camera_mode_selects_smallest_covering_candidate) {
  const std::vector<CaptureMode> candidates{
      {640, 480, 30, 1, 0},
      {1280, 720, 15, 1, 1},
      {320, 240, 30, 1, 2},
  };
  const auto selected = hcw::internal::SelectCaptureMode(
      candidates, hcw::CameraPreviewConfig{368, 368, 15});
  HMW_EXPECT(selected.has_value());
  HMW_EXPECT(selected->width == 640);
  HMW_EXPECT(selected->height == 480);
  HMW_EXPECT(selected->fps_numerator == 30);
  HMW_EXPECT(selected->fps_denominator == 1);
  HMW_EXPECT(selected->native_type_index == 0);
}

HMW_TEST(camera_mode_uses_largest_candidate_when_none_cover) {
  const std::vector<CaptureMode> candidates{
      {640, 480, 60, 1, 4},
      {1280, 720, 15, 1, 7},
      {320, 240, 120, 1, 9},
  };
  const auto selected = hcw::internal::SelectCaptureMode(
      candidates, hcw::CameraPreviewConfig{1920, 1080, 30});
  HMW_EXPECT(selected.has_value());
  HMW_EXPECT(selected->width == 1280);
  HMW_EXPECT(selected->height == 720);
  HMW_EXPECT(selected->native_type_index == 7);
}

HMW_TEST(camera_mode_negotiation_tries_next_ranked_candidate_after_failure) {
  const std::vector<CaptureMode> candidates{
      {640, 480, 30, 1, 3},
      {640, 480, 30, 1, 5},
      {1280, 720, 15, 1, 8},
  };
  std::vector<uint32_t> attempts;

  const auto selected = hcw::internal::SelectNegotiatedCaptureMode(
      candidates, hcw::CameraPreviewConfig{368, 368, 15},
      [&](const CaptureMode& candidate) {
        attempts.push_back(candidate.native_type_index);
        return candidate.native_type_index == 5;
      });

  HMW_EXPECT(selected.has_value());
  HMW_EXPECT(selected->native_type_index == 5);
  HMW_EXPECT(attempts == std::vector<uint32_t>({3, 5}));
}

HMW_TEST(camera_mode_hresult_detail_is_hexadecimal_and_bounded) {
  const std::string message = hcw::internal::FormatHresultDetail(
      std::string(200, 'x'), 0x80004005U);

  HMW_EXPECT(message.size() < 160);
  HMW_EXPECT(message.find("HRESULT 0x80004005") != std::string::npos);
}

HMW_TEST(camera_flush_waits_until_matching_callback_completion) {
  hcw::internal::AsyncFlushBarrier barrier;
  const auto generation = barrier.Arm();
  std::mutex mutex;
  std::condition_variable condition;
  bool wait_entered = false;
  bool wait_returned = false;

  std::thread waiter([&] {
    {
      std::lock_guard<std::mutex> lock(mutex);
      wait_entered = true;
      condition.notify_all();
    }
    barrier.Wait(generation);
    std::lock_guard<std::mutex> lock(mutex);
    wait_returned = true;
    condition.notify_all();
  });

  bool returned_before_completion = false;
  {
    std::unique_lock<std::mutex> lock(mutex);
    HMW_EXPECT(condition.wait_for(lock, 2s, [&] { return wait_entered; }));
    returned_before_completion =
        condition.wait_for(lock, 50ms, [&] { return wait_returned; });
  }
  barrier.Complete();
  bool returned_after_completion = false;
  {
    std::unique_lock<std::mutex> lock(mutex);
    returned_after_completion =
        condition.wait_for(lock, 2s, [&] { return wait_returned; });
  }
  if (!returned_after_completion) {
    barrier.Cancel(generation);
  }
  waiter.join();

  HMW_EXPECT(!returned_before_completion);
  HMW_EXPECT(returned_after_completion);
}

HMW_TEST(camera_flush_keeps_completion_that_arrives_before_wait) {
  hcw::internal::AsyncFlushBarrier barrier;
  const auto generation = barrier.Arm();
  barrier.Complete();
  std::mutex mutex;
  std::condition_variable condition;
  bool wait_returned = false;

  std::thread waiter([&] {
    barrier.Wait(generation);
    std::lock_guard<std::mutex> lock(mutex);
    wait_returned = true;
    condition.notify_all();
  });

  bool preserved_early_completion = false;
  {
    std::unique_lock<std::mutex> lock(mutex);
    preserved_early_completion =
        condition.wait_for(lock, 2s, [&] { return wait_returned; });
  }
  if (!preserved_early_completion) {
    barrier.Cancel(generation);
  }
  waiter.join();

  HMW_EXPECT(preserved_early_completion);
}

HMW_TEST(camera_bgra_copies_positive_padded_stride_to_tight_rows) {
  const std::vector<uint8_t> input{
      1, 2, 3, 4, 5, 6, 7, 8, 90, 91, 92, 93,
      9, 10, 11, 12, 13, 14, 15, 16, 94, 95, 96, 97,
  };
  const auto copied = hcw::internal::CopyBgraRows(
      BgraBufferView{input.data(), input.size(), input.data(), 12}, 2, 2);
  HMW_EXPECT(copied.ok());
  HMW_EXPECT(*copied.value == std::vector<uint8_t>({
      1, 2, 3, 4, 5, 6, 7, 8,
      9, 10, 11, 12, 13, 14, 15, 16,
  }));
}

HMW_TEST(camera_bgra_copies_negative_stride_to_top_down_tight_rows) {
  const std::vector<uint8_t> input{
      9, 10, 11, 12, 13, 14, 15, 16, 94, 95, 96, 97,
      1, 2, 3, 4, 5, 6, 7, 8, 90, 91, 92, 93,
  };
  const uint8_t* scanline_zero = input.data() + 12;
  const auto copied = hcw::internal::CopyBgraRows(
      BgraBufferView{input.data(), input.size(), scanline_zero, -12}, 2, 2);
  HMW_EXPECT(copied.ok());
  HMW_EXPECT(*copied.value == std::vector<uint8_t>({
      1, 2, 3, 4, 5, 6, 7, 8,
      9, 10, 11, 12, 13, 14, 15, 16,
  }));
}

HMW_TEST(camera_bgra_rejects_short_source_buffer) {
  const std::vector<uint8_t> input(19, 0);
  const auto copied = hcw::internal::CopyBgraRows(
      BgraBufferView{input.data(), input.size(), input.data(), 12}, 2, 2);
  HMW_EXPECT(!copied.ok());
  HMW_EXPECT(copied.error.has_value());
  HMW_EXPECT(copied.error->status == hmw::Status::kIoError);
}

HMW_TEST(camera_bgra_rejects_negative_stride_before_buffer_start) {
  const std::vector<uint8_t> input(24, 0);
  const auto copied = hcw::internal::CopyBgraRows(
      BgraBufferView{input.data() + 1, input.size() - 1,
                     input.data() + 12, -12},
      2, 2);

  HMW_EXPECT(!copied.ok());
  HMW_EXPECT(copied.error.has_value());
  HMW_EXPECT(copied.error->status == hmw::Status::kIoError);
}

HMW_TEST(camera_rgba_normalizes_mf_rgb32_x_to_opaque_alpha) {
  const std::vector<uint8_t> bgra{
      0, 0, 255, 0,
      0, 255, 0, 17,
      255, 0, 0, 23,
  };
  const auto rgba = hcw::internal::BgraToRgba(3, 1, 123, bgra);
  HMW_EXPECT(rgba.ok());
  HMW_EXPECT(rgba.value->width == 3);
  HMW_EXPECT(rgba.value->height == 1);
  HMW_EXPECT(rgba.value->pts_100ns == 123);
  HMW_EXPECT(rgba.value->pixels == std::vector<uint8_t>({
      255, 0, 0, 255,
      0, 255, 0, 255,
      0, 0, 255, 255,
  }));
}

HMW_TEST(camera_texture_frame_publishes_mf_red_and_blue_as_rgba) {
  std::vector<uint8_t> red_bgra(4U * 4U * 4U, 0);
  std::vector<uint8_t> blue_bgra(4U * 4U * 4U, 0);
  const uint8_t x_values[]{0, 17, 23};
  for (size_t pixel = 0; pixel < 16U; ++pixel) {
    const size_t offset = pixel * 4U;
    red_bgra[offset + 2U] = 255;
    red_bgra[offset + 3U] = x_values[pixel % 3U];
    blue_bgra[offset] = 255;
    blue_bgra[offset + 3U] = x_values[pixel % 3U];
  }

  const auto red = hcw::internal::PrepareCameraTextureFrame(
      4, 4, 456, red_bgra, hcw::CameraPreviewConfig{4, 4, 15});
  const auto blue = hcw::internal::PrepareCameraTextureFrame(
      4, 4, 789, blue_bgra, hcw::CameraPreviewConfig{4, 4, 15});
  HMW_EXPECT(red.ok());
  HMW_EXPECT(blue.ok());
  if (!red.ok() || !blue.ok()) {
    return;
  }
  for (size_t offset = 0; offset < red.value->rgba->size(); offset += 4U) {
    HMW_EXPECT(red.value->rgba->at(offset) == 255);
    HMW_EXPECT(red.value->rgba->at(offset + 1U) == 0);
    HMW_EXPECT(red.value->rgba->at(offset + 2U) == 0);
    HMW_EXPECT(red.value->rgba->at(offset + 3U) == 255);
    HMW_EXPECT(blue.value->rgba->at(offset) == 0);
    HMW_EXPECT(blue.value->rgba->at(offset + 1U) == 0);
    HMW_EXPECT(blue.value->rgba->at(offset + 2U) == 255);
    HMW_EXPECT(blue.value->rgba->at(offset + 3U) == 255);
  }
}

}  // namespace
