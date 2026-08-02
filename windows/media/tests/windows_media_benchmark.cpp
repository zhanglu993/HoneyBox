#include "benchmark_support.h"

#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

namespace {

std::filesystem::path MovFixturePath() {
  return std::filesystem::path(HMW_PROJECT_SOURCE_DIR) /
         "assets/example/video/badge-preset-video-1.mov";
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  std::vector<std::wstring> arguments;
  arguments.reserve(static_cast<size_t>(argc));
  for (int index = 0; index < argc; ++index) {
    arguments.emplace_back(argv[index]);
  }
  const auto evidence_path =
      hmw::test::BenchmarkEvidencePathFromWideArguments(arguments);
  if (!evidence_path.ok()) {
    std::cerr << "usage: hmw_windows_media_benchmark.exe --json <path>\n";
    return 2;
  }
  const hmw::Result<hmw::test::BenchmarkEvidence> result =
      hmw::test::RunTenSecondEquivalentBenchmark(MovFixturePath());
  if (!result.ok()) {
    std::cerr << "benchmark failed: "
              << (result.error ? result.error->message : "unknown error")
              << '\n';
    return 2;
  }
  const std::string json = hmw::test::BenchmarkEvidenceJson(*result.value);
  if (!hmw::test::WriteBenchmarkEvidenceAtomically(*evidence_path.value, json)
           .ok()) {
    std::cerr << "benchmark evidence could not be written atomically\n";
    return 2;
  }
  std::cout << json;
  return result.value->realtime_pass && result.value->cancel_pass ? 0 : 1;
}
