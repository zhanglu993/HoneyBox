#include "benchmark_support.h"

#include "test_support.h"

#include <cstdint>
#include <string>

HMW_TEST(benchmark_accumulates_at_least_ten_source_seconds) {
  HMW_EXPECT(hmw::test::BenchmarkSourceSecondsForDuration(3.25) == 13.0);
  HMW_EXPECT(hmw::test::BenchmarkSourceSecondsForDuration(10.0) == 10.0);
}

HMW_TEST(benchmark_uses_360_square_ten_fps_default_quality) {
  const hmw::ConversionRequest request =
      hmw::test::DefaultBenchmarkRequest("fixture.mov");
  HMW_EXPECT(request.width == 360U);
  HMW_EXPECT(request.height == 360U);
  HMW_EXPECT(request.fps == 10U);
  HMW_EXPECT(request.quality == 60U);
  HMW_EXPECT(request.refine == 3U);
  HMW_EXPECT(request.strips == 2U);
  HMW_EXPECT(request.skip_threshold == 720U);
  HMW_EXPECT(request.key_interval == 0U);
  HMW_EXPECT(request.max_frames == 300U);
  HMW_EXPECT(request.background_argb == 0xff000000U);
  HMW_EXPECT(request.fit == hmw::FitMode::kCover);
  HMW_EXPECT(!request.crop.has_value());
}

HMW_TEST(benchmark_realtime_pass_compares_elapsed_to_source_duration) {
  hmw::test::BenchmarkEvidence evidence{"cpu", 1U, "windows", 10.0, 9.99,
                                         1001U, false, false};
  const auto evaluated = hmw::test::EvaluateBenchmarkEvidence(evidence);
  HMW_EXPECT(evaluated.realtime_pass);
  HMW_EXPECT(!evaluated.cancel_pass);
  evidence.elapsed_seconds = 10.01;
  HMW_EXPECT(!hmw::test::EvaluateBenchmarkEvidence(evidence).realtime_pass);
}

HMW_TEST(benchmark_cancel_pass_requires_at_most_one_thousand_ms) {
  hmw::test::BenchmarkEvidence evidence{"cpu", 1U, "windows", 10.0, 1.0,
                                         1000U, false, false};
  HMW_EXPECT(hmw::test::EvaluateBenchmarkEvidence(evidence).cancel_pass);
  evidence.cancel_milliseconds = 1001U;
  HMW_EXPECT(!hmw::test::EvaluateBenchmarkEvidence(evidence).cancel_pass);
}

HMW_TEST(benchmark_json_contains_machine_source_elapsed_and_cancel_fields) {
  const hmw::test::BenchmarkEvidence evidence{
      "CPU \"name\"", 17179869184ULL, "Windows 11\n23H2", 10.5,
      8.25, 250U, true, true};
  const std::string json = hmw::test::BenchmarkEvidenceJson(evidence);
  HMW_EXPECT(json.find("\"cpu\":\"CPU \\\"name\\\"\"") !=
             std::string::npos);
  HMW_EXPECT(json.find("\"memory_bytes\":17179869184") !=
             std::string::npos);
  HMW_EXPECT(json.find("\"windows_version\":\"Windows 11\\n23H2\"") !=
             std::string::npos);
  HMW_EXPECT(json.find("\"source_seconds\":10.5") != std::string::npos);
  HMW_EXPECT(json.find("\"elapsed_seconds\":8.25") != std::string::npos);
  HMW_EXPECT(json.find("\"cancel_milliseconds\":250") !=
             std::string::npos);
  HMW_EXPECT(json.find("\"realtime_pass\":true") != std::string::npos);
  HMW_EXPECT(json.find("\"cancel_pass\":true") != std::string::npos);
}
