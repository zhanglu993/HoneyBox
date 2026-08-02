#include "benchmark_support.h"

#include "test_support.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <optional>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

namespace {

class TemporaryDirectory {
 public:
  TemporaryDirectory() {
    static std::atomic<uint64_t> counter{0U};
    const uint64_t sequence = counter.fetch_add(1U);
    const auto timestamp = std::chrono::steady_clock::now()
                               .time_since_epoch()
                               .count();
    path_ = std::filesystem::temp_directory_path() /
            ("hmw-benchmark-" + std::to_string(timestamp) + "-" +
             std::to_string(sequence));
    std::error_code error;
    std::filesystem::create_directories(path_, error);
    HMW_EXPECT(!error);
  }

  ~TemporaryDirectory() {
    std::error_code error;
    std::filesystem::remove_all(path_, error);
  }

  const std::filesystem::path& path() const { return path_; }

 private:
  std::filesystem::path path_;
};

class ScopedCurrentDirectory {
 public:
  explicit ScopedCurrentDirectory(const std::filesystem::path& path)
      : previous_(std::filesystem::current_path()) {
    std::error_code error;
    std::filesystem::current_path(path, error);
    HMW_EXPECT(!error);
  }

  ~ScopedCurrentDirectory() {
    std::error_code error;
    std::filesystem::current_path(previous_, error);
  }

 private:
  std::filesystem::path previous_;
};

std::string ReadText(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

void WriteText(const std::filesystem::path& path, const std::string& text) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output << text;
  HMW_EXPECT(output.good());
}

hmw::Result<hmw::MediaJobResult> CancelledResult() {
  return {std::nullopt,
          hmw::Error{hmw::Status::kCancelled, "cancelled by test"}};
}

}  // namespace

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
  const std::string expected =
      "{\"cpu\":\"CPU \\\"name\\\"\",\"memory_bytes\":17179869184,"
      "\"windows_version\":\"Windows 11\\n23H2\","
      "\"source_seconds\":10.5,\"elapsed_seconds\":8.25,"
      "\"cancel_milliseconds\":250,\"realtime_pass\":true,"
      "\"cancel_pass\":true}\n";
  HMW_EXPECT(json == expected);
}

HMW_TEST(benchmark_evidence_path_preserves_non_acp_unicode) {
  const TemporaryDirectory directory;
  const std::filesystem::path destination =
      directory.path() / L"证据-😀.json";
  const std::vector<std::wstring> arguments{
      L"hmw_windows_media_benchmark.exe", L"--json", destination.native()};
  const auto parsed =
      hmw::test::BenchmarkEvidencePathFromWideArguments(arguments);
  HMW_EXPECT(parsed.ok());
  if (!parsed.ok()) {
    return;
  }
  HMW_EXPECT(*parsed.value == destination);
  const hmw::Outcome written =
      hmw::test::WriteBenchmarkEvidenceAtomically(*parsed.value, "{}\n");
  HMW_EXPECT(written.ok());
  HMW_EXPECT(ReadText(destination) == "{}\n");
}

HMW_TEST(benchmark_atomic_write_supports_parentless_path) {
  const TemporaryDirectory directory;
  const ScopedCurrentDirectory current(directory.path());
  const std::filesystem::path destination = L"证据-😀.json";
  const hmw::Outcome written =
      hmw::test::WriteBenchmarkEvidenceAtomically(destination, "first");
  HMW_EXPECT(written.ok());
  HMW_EXPECT(ReadText(destination) == "first");
}

HMW_TEST(benchmark_atomic_write_creates_directories_and_replaces_old_file) {
  const TemporaryDirectory directory;
  const std::filesystem::path destination =
      directory.path() / L"嵌套-😀" / L"证据.json";
  HMW_EXPECT(
      hmw::test::WriteBenchmarkEvidenceAtomically(destination, "old").ok());
  HMW_EXPECT(
      hmw::test::WriteBenchmarkEvidenceAtomically(destination, "new").ok());
  HMW_EXPECT(ReadText(destination) == "new");
}

HMW_TEST(benchmark_atomic_move_failure_preserves_old_file_and_cleans_temp) {
  const TemporaryDirectory directory;
  const std::filesystem::path destination =
      directory.path() / L"证据-😀.json";
  WriteText(destination, "old");
  std::filesystem::path observed_temporary;
  const hmw::Outcome written = hmw::test::WriteBenchmarkEvidenceAtomically(
      destination, "new",
      [&observed_temporary](const std::filesystem::path& temporary,
                            const std::filesystem::path&) {
        observed_temporary = temporary;
        return false;
      });
  HMW_EXPECT(!written.ok());
  HMW_EXPECT(ReadText(destination) == "old");
  HMW_EXPECT(!observed_temporary.empty());
  HMW_EXPECT(!std::filesystem::exists(observed_temporary));
}

HMW_TEST(benchmark_cancellation_drains_duplicate_after_worker_wait) {
  std::deque<std::function<void()>> queue;
  hmw::Progress progress_callback;
  hmw::test::BenchmarkCompletion completion_callback;
  bool worker_waited = false;
  bool shut_down = false;
  hmw::test::CancellationMeasurementHooks hooks;
  hooks.start = [&queue, &progress_callback, &completion_callback](
                    hmw::Progress progress,
                    hmw::test::BenchmarkCompletion completion) {
    progress_callback = std::move(progress);
    completion_callback = std::move(completion);
    queue.push_back([&progress_callback] { progress_callback(1U, 2U); });
    return hmw::Result<uint64_t>{1U, std::nullopt};
  };
  hooks.cancel = [&queue, &completion_callback] {
    queue.push_back(
        [&completion_callback] { completion_callback(CancelledResult()); });
    queue.push_back(
        [&completion_callback] { completion_callback(CancelledResult()); });
  };
  hooks.pump = [&queue](std::chrono::milliseconds) {
    if (queue.empty()) {
      return false;
    }
    std::function<void()> callback = std::move(queue.front());
    queue.pop_front();
    callback();
    return true;
  };
  hooks.wait_for_worker = [&worker_waited] {
    worker_waited = true;
    return hmw::Outcome{std::nullopt};
  };
  hooks.shutdown = [&queue, &shut_down] {
    shut_down = true;
    queue.clear();
  };

  const hmw::Result<uint64_t> measured =
      hmw::test::MeasureCancellationMillisecondsWithHooks(std::move(hooks));
  HMW_EXPECT(!measured.ok());
  HMW_EXPECT(measured.error.has_value());
  if (measured.error) {
    HMW_EXPECT(measured.error->status == hmw::Status::kInvalidState);
  }
  HMW_EXPECT(worker_waited);
  HMW_EXPECT(shut_down);
  HMW_EXPECT(queue.empty());
}

HMW_TEST(benchmark_cancellation_waits_for_worker_before_draining_completion) {
  std::deque<std::function<void()>> queue;
  hmw::Progress progress_callback;
  hmw::test::BenchmarkCompletion completion_callback;
  bool worker_waited = false;
  bool completion_delivered_before_wait = false;
  bool delayed_completion_delivered = false;
  bool shut_down = false;
  hmw::test::CancellationMeasurementHooks hooks;
  hooks.start = [&queue, &progress_callback, &completion_callback](
                    hmw::Progress progress,
                    hmw::test::BenchmarkCompletion completion) {
    progress_callback = std::move(progress);
    completion_callback = std::move(completion);
    queue.push_back([&progress_callback] { progress_callback(1U, 2U); });
    return hmw::Result<uint64_t>{1U, std::nullopt};
  };
  hooks.cancel = [&queue, &completion_callback, &worker_waited,
                  &completion_delivered_before_wait] {
    queue.push_back([&completion_callback, &worker_waited,
                     &completion_delivered_before_wait] {
      completion_delivered_before_wait = !worker_waited;
      completion_callback(CancelledResult());
    });
  };
  hooks.wait_for_worker = [&queue, &completion_callback, &worker_waited,
                           &delayed_completion_delivered] {
    worker_waited = true;
    queue.push_back(
        [&completion_callback, &delayed_completion_delivered] {
          delayed_completion_delivered = true;
          completion_callback(CancelledResult());
        });
    return hmw::Outcome{std::nullopt};
  };
  hooks.pump = [&queue](std::chrono::milliseconds) {
    if (queue.empty()) {
      return false;
    }
    std::function<void()> callback = std::move(queue.front());
    queue.pop_front();
    callback();
    return true;
  };
  hooks.shutdown = [&queue, &shut_down] {
    shut_down = true;
    queue.clear();
  };

  const hmw::Result<uint64_t> measured =
      hmw::test::MeasureCancellationMillisecondsWithHooks(std::move(hooks));
  HMW_EXPECT(!measured.ok());
  HMW_EXPECT(measured.error.has_value());
  if (measured.error) {
    HMW_EXPECT(measured.error->status == hmw::Status::kInvalidState);
  }
  HMW_EXPECT(worker_waited);
  HMW_EXPECT(!completion_delivered_before_wait);
  HMW_EXPECT(delayed_completion_delivered);
  HMW_EXPECT(shut_down);
  HMW_EXPECT(queue.empty());
}
