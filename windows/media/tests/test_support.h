#pragma once

#include "honey_media_core/media_core.h"
#include "honey_media_windows/media_converter.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <limits>
#include <memory>
#include <optional>
#include <string_view>
#include <vector>

namespace hmw::test {

inline int failures = 0;

using TestFunction = void (*)();

struct TestCase {
  const char* name;
  TestFunction function;
  TestCase* next;
};

inline TestCase*& RegisteredTests() {
  static TestCase* head = nullptr;
  return head;
}

class Registration {
 public:
  Registration(const char* name, TestFunction function)
      : test_case_{name, function, RegisteredTests()} {
    RegisteredTests() = &test_case_;
  }

 private:
  TestCase test_case_;
};

inline void Expect(bool condition, const char* expression, const char* file,
                   int line) {
  if (!condition) {
    std::fprintf(stderr, "%s:%d: expectation failed: %s\n", file, line,
                 expression);
    ++failures;
  }
}

inline int RunAllTests(std::string_view filter = {}) {
  failures = 0;
  for (TestCase* test = RegisteredTests(); test != nullptr; test = test->next) {
    if (!filter.empty() &&
        std::string_view(test->name).find(filter) == std::string_view::npos) {
      continue;
    }
    const int failures_before = failures;
    std::printf("[ RUN      ] %s\n", test->name);
    test->function();
    std::printf(failures == failures_before ? "[       OK ] %s\n"
                                            : "[  FAILED  ] %s\n",
                test->name);
  }
  return failures == 0 ? 0 : 1;
}

inline std::filesystem::path MovFixturePath() {
  return std::filesystem::path(HMW_PROJECT_SOURCE_DIR) /
         "assets/example/video/badge-preset-video-1.mov";
}

inline std::filesystem::path GifFixturePath() {
  return std::filesystem::path(HMW_TEST_SOURCE_DIR) / "fixtures" /
         "animated_disposal.gif";
}

inline hmw::ConversionRequest FixtureRequest(
    const std::filesystem::path& path) {
  return hmw::ConversionRequest{path,
                                32U,
                                32U,
                                10U,
                                60U,
                                3U,
                                2U,
                                720U,
                                0U,
                                300U,
                                0xff000000U,
                                hmw::FitMode::kCover,
                                std::nullopt};
}

inline hmw::ConversionRequest MovFixtureRequest() {
  return FixtureRequest(MovFixturePath());
}

inline hmw::ConversionRequest GifFixtureRequest() {
  return FixtureRequest(GifFixturePath());
}

inline hmw::Outcome ValidateCvidAndDecodeFirstLast(
    const std::vector<uint8_t>& avi) {
  hmc_avi_reader_t* raw_reader = nullptr;
  if (hmc_avi_reader_create_copy(avi.data(), avi.size(), &raw_reader) !=
      HMC_STATUS_OK) {
    return {hmw::Error{hmw::Status::kDecodeFailed,
                       "AVI reader creation failed"}};
  }
  std::unique_ptr<hmc_avi_reader_t, decltype(&hmc_avi_reader_destroy)> reader(
      raw_reader, &hmc_avi_reader_destroy);
  hmc_avi_info_t info{};
  info.struct_size = HMC_AVI_INFO_V1_SIZE;
  if (hmc_avi_reader_get_info(reader.get(), &info) != HMC_STATUS_OK ||
      info.handler_fourcc != HMC_MEDIA_FOURCC('c', 'v', 'i', 'd') ||
      info.frame_count == 0U) {
    return {hmw::Error{hmw::Status::kDecodeFailed, "expected CVID AVI"}};
  }
  hmc_cinepak_decoder_config_t config{};
  if (hmc_cinepak_decoder_config_init(
          &config, HMC_CINEPAK_DECODER_CONFIG_V1_SIZE) != HMC_STATUS_OK) {
    return {hmw::Error{hmw::Status::kDecodeFailed,
                       "decoder config failed"}};
  }
  config.width = info.width;
  config.height = info.height;
  hmc_cinepak_decoder_t* raw_decoder = nullptr;
  if (hmc_cinepak_decoder_create(&config, &raw_decoder) != HMC_STATUS_OK) {
    return {hmw::Error{hmw::Status::kDecodeFailed,
                       "decoder creation failed"}};
  }
  std::unique_ptr<hmc_cinepak_decoder_t,
                  decltype(&hmc_cinepak_decoder_destroy)>
      decoder(raw_decoder, &hmc_cinepak_decoder_destroy);
  const uint64_t pixel_count =
      static_cast<uint64_t>(info.width) * info.height;
  if (pixel_count == 0U ||
      pixel_count > (std::numeric_limits<size_t>::max)()) {
    return {hmw::Error{hmw::Status::kDecodeFailed,
                       "invalid decoded frame dimensions"}};
  }
  constexpr uint32_t kUnwrittenPixel = 0xdeadbeefU;
  std::vector<uint32_t> argb(static_cast<size_t>(pixel_count),
                             kUnwrittenPixel);
  bool first_written = false;
  bool last_written = false;
  for (uint32_t i = 0; i < info.frame_count; ++i) {
    std::fill(argb.begin(), argb.end(), kUnwrittenPixel);
    hmc_bytes_view_t frame{};
    if (hmc_avi_reader_get_frame_view(reader.get(), i, &frame) !=
            HMC_STATUS_OK ||
        hmc_cinepak_decoder_decode(decoder.get(), frame.data, frame.size,
                                   argb.data(), argb.size()) != HMC_STATUS_OK) {
      return {hmw::Error{hmw::Status::kDecodeFailed,
                         "sequential decode failed"}};
    }
    const bool frame_written =
        std::any_of(argb.begin(), argb.end(), [](uint32_t pixel) {
          return pixel != kUnwrittenPixel;
        });
    if (i == 0U) {
      first_written = frame_written;
    }
    if (i + 1U == info.frame_count) {
      last_written = frame_written;
    }
  }
  return first_written && last_written
             ? hmw::Outcome{std::nullopt}
             : hmw::Outcome{hmw::Error{hmw::Status::kDecodeFailed,
                                       "unwritten decoded smoke frame"}};
}

}  // namespace hmw::test

inline void IgnoreProgress(uint32_t, uint32_t) {}
inline bool NeverCancel() { return false; }

#define HMW_TEST(name) \
  static void name(); \
  static ::hmw::test::Registration name##_registration(#name, &name); \
  static void name()

#define HMW_EXPECT(...) \
  ::hmw::test::Expect((__VA_ARGS__), #__VA_ARGS__, __FILE__, __LINE__)
