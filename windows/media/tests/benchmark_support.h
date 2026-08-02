#pragma once

#include "honey_media_windows/media_converter.h"
#include "honey_media_windows/status.h"

#include <cstdint>
#include <filesystem>
#include <string>

namespace hmw::test {

struct BenchmarkEvidence {
  std::string cpu;
  uint64_t memory_bytes;
  std::string windows_version;
  double source_seconds;
  double elapsed_seconds;
  uint64_t cancel_milliseconds;
  bool realtime_pass;
  bool cancel_pass;
};

Result<BenchmarkEvidence> RunTenSecondEquivalentBenchmark(
    const std::filesystem::path& mov_fixture);
ConversionRequest DefaultBenchmarkRequest(
    const std::filesystem::path& mov_fixture);
BenchmarkEvidence EvaluateBenchmarkEvidence(BenchmarkEvidence evidence);
std::string BenchmarkEvidenceJson(const BenchmarkEvidence& evidence);
Result<uint64_t> MeasureRealCancellationMilliseconds(
    const std::filesystem::path& mov_fixture);

double BenchmarkSourceSecondsForDuration(double one_source_seconds);

}  // namespace hmw::test
