#pragma once

#include "honey_media_windows/media_converter.h"
#include "honey_media_windows/status.h"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace hmw::test {

using BenchmarkCompletion = std::function<void(Result<MediaJobResult>)>;

struct CancellationMeasurementHooks {
  std::function<Result<uint64_t>(Progress, BenchmarkCompletion)> start;
  std::function<void()> cancel;
  std::function<bool(std::chrono::milliseconds)> pump;
  std::function<Outcome()> wait_for_worker;
  std::function<void()> shutdown;
};

using AtomicEvidenceReplace = std::function<bool(
    const std::filesystem::path&, const std::filesystem::path&)>;

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

Result<uint64_t> MeasureCancellationMillisecondsWithHooks(
    CancellationMeasurementHooks hooks);

Result<std::filesystem::path> BenchmarkEvidencePathFromWideArguments(
    const std::vector<std::wstring>& arguments);

Outcome WriteBenchmarkEvidenceAtomically(
    const std::filesystem::path& destination,
    const std::string& json);

Outcome WriteBenchmarkEvidenceAtomically(
    const std::filesystem::path& destination,
    const std::string& json,
    AtomicEvidenceReplace replace);

double BenchmarkSourceSecondsForDuration(double one_source_seconds);

}  // namespace hmw::test
