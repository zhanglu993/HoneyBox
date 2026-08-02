#include "benchmark_support.h"

#include <Windows.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <system_error>

namespace {

std::filesystem::path MovFixturePath() {
  return std::filesystem::path(HMW_PROJECT_SOURCE_DIR) /
         "assets/example/video/badge-preset-video-1.mov";
}

bool WriteAtomically(const std::filesystem::path& destination,
                     const std::string& contents) {
  std::error_code error;
  const std::filesystem::path parent = destination.parent_path();
  if (!parent.empty()) {
    std::filesystem::create_directories(parent, error);
    if (error) {
      return false;
    }
  }
  const std::filesystem::path temporary =
      destination.parent_path() /
      (destination.filename().wstring() + L".tmp-" +
       std::to_wstring(GetCurrentProcessId()));
  {
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
    output.flush();
    if (!output.good()) {
      output.close();
      std::filesystem::remove(temporary, error);
      return false;
    }
  }
  if (!MoveFileExW(temporary.c_str(), destination.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    std::filesystem::remove(temporary, error);
    return false;
  }
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3 || std::string(argv[1]) != "--json") {
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
  if (!WriteAtomically(std::filesystem::path(argv[2]), json)) {
    std::cerr << "benchmark evidence could not be written atomically\n";
    return 2;
  }
  std::cout << json;
  return result.value->realtime_pass && result.value->cancel_pass ? 0 : 1;
}
