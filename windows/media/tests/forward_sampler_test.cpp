#include "../src/media_converter_internal.h"

#include "test_support.h"

#include <cstdint>
#include <utility>
#include <vector>

namespace {

hmw::RgbaFrame SampleFrame(uint8_t red, int64_t pts_100ns) {
  std::vector<uint8_t> pixels(4U * 4U * 4U, 255U);
  for (size_t offset = 0; offset < pixels.size(); offset += 4U) {
    pixels[offset] = red;
    pixels[offset + 1U] = 0U;
    pixels[offset + 2U] = 0U;
  }
  return hmw::RgbaFrame{4, 4, pts_100ns, 0, std::move(pixels)};
}

class CountingFrameSource final : public hmw::FrameSource {
 public:
  explicit CountingFrameSource(std::vector<hmw::RgbaFrame> frames)
      : frames_(std::move(frames)) {}

  const hmw::SourceInfo& info() const override { return info_; }

  hmw::Result<bool> ReadNext(hmw::RgbaFrame* frame) override {
    ++read_count;
    if (next_ == frames_.size()) {
      return hmw::Result<bool>{false, std::nullopt};
    }
    *frame = frames_[next_++];
    return hmw::Result<bool>{true, std::nullopt};
  }

  hmw::Outcome Seek(int64_t) override {
    ++seek_count;
    return hmw::Outcome{std::nullopt};
  }

  uint32_t read_count = 0;
  uint32_t seek_count = 0;

 private:
  hmw::SourceInfo info_{4, 4, 100, 10.0, 0, false};
  std::vector<hmw::RgbaFrame> frames_;
  size_t next_ = 0;
};

}  // namespace

HMW_TEST(forward_sampler_reads_linearly_without_seek_and_holds_last_frame) {
  CountingFrameSource source({SampleFrame(10, 0), SampleFrame(20, 0),
                              SampleFrame(30, 10), SampleFrame(40, 40)});
  hmw::internal::ForwardFrameSampler sampler(&source);
  const std::vector<std::pair<int64_t, int>> samples{
      {0, 20}, {5, 20}, {10, 30}, {39, 30}, {40, 40}, {100, 40}};
  for (const auto& sample : samples) {
    const auto result = sampler.Sample(sample.first, NeverCancel);
    HMW_EXPECT(result.ok());
    if (result.ok()) {
      HMW_EXPECT(result.value->get().pixels[0] == sample.second);
      HMW_EXPECT(result.value->get().duration_100ns == 0);
    }
  }
  HMW_EXPECT(source.seek_count == 0);
  HMW_EXPECT(source.read_count == 5);
}
