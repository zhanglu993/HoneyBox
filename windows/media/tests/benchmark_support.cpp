#include "benchmark_support.h"

#include "honey_media_windows/conversion_controller.h"
#include "honey_media_windows/media_source.h"
#include "honey_media_windows/platform_dispatcher.h"

#include <Windows.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <system_error>
#include <utility>

namespace hmw::test {
namespace {

class QueueDispatcher final : public PlatformDispatcher {
 public:
  bool Post(std::function<void()> callback) override {
    try {
      {
        std::lock_guard<std::mutex> lock(mutex_);
        callbacks_.push_back(std::move(callback));
      }
      condition_.notify_one();
      return true;
    } catch (...) {
      return false;
    }
  }

  bool RunOne(std::chrono::milliseconds timeout) {
    std::function<void()> callback;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      if (!condition_.wait_for(lock, timeout,
                               [this] { return !callbacks_.empty(); })) {
        return false;
      }
      callback = std::move(callbacks_.front());
      callbacks_.pop_front();
    }
    callback();
    return true;
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<std::function<void()>> callbacks_;
};

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  if (size <= 0) {
    return {};
  }
  std::string output(static_cast<size_t>(size), '\0');
  if (WideCharToMultiByte(CP_UTF8, 0, value.data(),
                          static_cast<int>(value.size()), output.data(), size,
                          nullptr, nullptr) != size) {
    return {};
  }
  return output;
}

std::string CpuName() {
  DWORD bytes = 0;
  if (RegGetValueW(HKEY_LOCAL_MACHINE,
                   L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
                   L"ProcessorNameString", RRF_RT_REG_SZ, nullptr, nullptr,
                   &bytes) != ERROR_SUCCESS || bytes < sizeof(wchar_t)) {
    return "unknown";
  }
  std::wstring value(bytes / sizeof(wchar_t), L'\0');
  if (RegGetValueW(HKEY_LOCAL_MACHINE,
                   L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
                   L"ProcessorNameString", RRF_RT_REG_SZ, nullptr,
                   value.data(), &bytes) != ERROR_SUCCESS) {
    return "unknown";
  }
  while (!value.empty() && value.back() == L'\0') {
    value.pop_back();
  }
  const std::string utf8 = WideToUtf8(value);
  return utf8.empty() ? "unknown" : utf8;
}

uint64_t PhysicalMemoryBytes() {
  MEMORYSTATUSEX status{};
  status.dwLength = sizeof(status);
  return GlobalMemoryStatusEx(&status) ? status.ullTotalPhys : 0U;
}

std::string WindowsVersion() {
  using RtlGetVersionFunction = LONG(WINAPI*)(OSVERSIONINFOW*);
  const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  const auto rtl_get_version = reinterpret_cast<RtlGetVersionFunction>(
      ntdll == nullptr ? nullptr : GetProcAddress(ntdll, "RtlGetVersion"));
  OSVERSIONINFOW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  if (rtl_get_version == nullptr || rtl_get_version(&version) != 0) {
    return "unknown";
  }
  std::ostringstream output;
  output << "Windows " << version.dwMajorVersion << '.'
         << version.dwMinorVersion << " build " << version.dwBuildNumber;
  return output.str();
}

std::string JsonEscape(const std::string& value) {
  std::ostringstream output;
  for (const unsigned char byte : value) {
    switch (byte) {
      case '\\':
        output << "\\\\";
        break;
      case '"':
        output << "\\\"";
        break;
      case '\n':
        output << "\\n";
        break;
      case '\r':
        output << "\\r";
        break;
      case '\t':
        output << "\\t";
        break;
      default:
        if (byte < 0x20U) {
          output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                 << static_cast<unsigned int>(byte) << std::dec;
        } else {
          output << static_cast<char>(byte);
        }
        break;
    }
  }
  return output.str();
}

Error BenchmarkError(Status status, std::string message) {
  return Error{status, std::move(message)};
}

}  // namespace

Result<std::filesystem::path> BenchmarkEvidencePathFromWideArguments(
    const std::vector<std::wstring>& arguments) {
  if (arguments.size() != 3U || arguments[1] != L"--json" ||
      arguments[2].empty()) {
    return {std::nullopt,
            BenchmarkError(Status::kInvalidArgument,
                           "expected --json and an evidence path")};
  }
  return {std::filesystem::path(arguments[2]), std::nullopt};
}

Outcome WriteBenchmarkEvidenceAtomically(
    const std::filesystem::path& destination,
    const std::string& json,
    AtomicEvidenceReplace replace) {
  if (destination.empty() || !replace) {
    return {
        BenchmarkError(Status::kInvalidArgument,
                       "evidence destination or replace callback is invalid")};
  }

  std::error_code error;
  const std::filesystem::path parent = destination.parent_path();
  if (!parent.empty()) {
    std::filesystem::create_directories(parent, error);
    if (error) {
      return {BenchmarkError(Status::kIoError,
                             "evidence directory could not be created")};
    }
  }

  static std::atomic<uint64_t> temporary_sequence{0U};
  const uint64_t sequence = temporary_sequence.fetch_add(1U);
  const std::filesystem::path temporary =
      parent /
      (destination.filename().wstring() + L".tmp-" +
       std::to_wstring(GetCurrentProcessId()) + L"-" +
       std::to_wstring(sequence));

  {
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    output.write(json.data(), static_cast<std::streamsize>(json.size()));
    output.flush();
    if (!output.good()) {
      output.close();
      std::error_code cleanup_error;
      std::filesystem::remove(temporary, cleanup_error);
      return {BenchmarkError(Status::kIoError,
                             "temporary evidence could not be written")};
    }
  }

  if (!replace(temporary, destination)) {
    std::error_code cleanup_error;
    std::filesystem::remove(temporary, cleanup_error);
    return {BenchmarkError(Status::kIoError,
                           "evidence could not be replaced atomically")};
  }
  return {std::nullopt};
}

Outcome WriteBenchmarkEvidenceAtomically(
    const std::filesystem::path& destination,
    const std::string& json) {
  return WriteBenchmarkEvidenceAtomically(
      destination, json,
      [](const std::filesystem::path& temporary,
         const std::filesystem::path& final_path) {
        return MoveFileExW(
                   temporary.c_str(), final_path.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
      });
}

ConversionRequest DefaultBenchmarkRequest(
    const std::filesystem::path& mov_fixture) {
  return ConversionRequest{mov_fixture,
                           360U,
                           360U,
                           10U,
                           60U,
                           3U,
                           2U,
                           720U,
                           0U,
                           300U,
                           0xff000000U,
                           FitMode::kCover,
                           std::nullopt};
}

double BenchmarkSourceSecondsForDuration(double one_source_seconds) {
  if (one_source_seconds <= 0.0) {
    return 0.0;
  }
  double accumulated = 0.0;
  do {
    accumulated += one_source_seconds;
  } while (accumulated < 10.0);
  return accumulated;
}

BenchmarkEvidence EvaluateBenchmarkEvidence(BenchmarkEvidence evidence) {
  evidence.realtime_pass = evidence.source_seconds > 0.0 &&
                           evidence.elapsed_seconds <= evidence.source_seconds;
  evidence.cancel_pass = evidence.cancel_milliseconds <= 1000U;
  return evidence;
}

std::string BenchmarkEvidenceJson(const BenchmarkEvidence& evidence) {
  std::ostringstream output;
  output << std::setprecision(17) << '{'
         << "\"cpu\":\"" << JsonEscape(evidence.cpu) << "\","
         << "\"memory_bytes\":" << evidence.memory_bytes << ','
         << "\"windows_version\":\""
         << JsonEscape(evidence.windows_version) << "\","
         << "\"source_seconds\":" << evidence.source_seconds << ','
         << "\"elapsed_seconds\":" << evidence.elapsed_seconds << ','
         << "\"cancel_milliseconds\":" << evidence.cancel_milliseconds
         << ',' << "\"realtime_pass\":"
         << (evidence.realtime_pass ? "true" : "false") << ','
         << "\"cancel_pass\":"
         << (evidence.cancel_pass ? "true" : "false") << "}\n";
  return output.str();
}

Result<uint64_t> MeasureCancellationMillisecondsWithHooks(
    CancellationMeasurementHooks hooks) {
  if (!hooks.start || !hooks.cancel || !hooks.pump ||
      !hooks.wait_for_worker || !hooks.shutdown) {
    return {std::nullopt,
            BenchmarkError(Status::kInvalidArgument,
                           "benchmark cancellation hooks are incomplete")};
  }

  bool saw_progress = false;
  uint32_t completion_count = 0U;
  std::optional<Result<MediaJobResult>> first_completion;
  std::optional<std::chrono::steady_clock::time_point> first_completed_at;
  const Result<uint64_t> started = hooks.start(
      [&saw_progress](uint32_t, uint32_t) { saw_progress = true; },
      [&completion_count, &first_completion,
       &first_completed_at](Result<MediaJobResult> result) {
        ++completion_count;
        if (!first_completion.has_value()) {
          first_completion = std::move(result);
          first_completed_at = std::chrono::steady_clock::now();
        }
      });
  if (!started.ok()) {
    hooks.shutdown();
    return {std::nullopt, std::move(started.error)};
  }

  const auto progress_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(30);
  while (!saw_progress && std::chrono::steady_clock::now() < progress_deadline) {
    (void)hooks.pump(std::chrono::milliseconds(100));
  }
  if (!saw_progress) {
    hooks.cancel();
    Outcome waited = hooks.wait_for_worker();
    if (waited.ok()) {
      while (hooks.pump(std::chrono::milliseconds(0))) {
      }
    }
    hooks.shutdown();
    if (!waited.ok()) {
      return {std::nullopt, std::move(waited.error)};
    }
    return {std::nullopt,
            BenchmarkError(Status::kInvalidState,
                           "benchmark did not report progress")};
  }

  const auto cancelled_at = std::chrono::steady_clock::now();
  hooks.cancel();
  Outcome waited = hooks.wait_for_worker();
  if (!waited.ok()) {
    hooks.shutdown();
    return {std::nullopt, std::move(waited.error)};
  }
  while (hooks.pump(std::chrono::milliseconds(0))) {
  }

  const bool completion_is_unique_cancel =
      completion_count == 1U && first_completion.has_value() &&
      first_completed_at.has_value() && !first_completion->ok() &&
      first_completion->error.has_value() &&
      first_completion->error->status == Status::kCancelled &&
      *first_completed_at >= cancelled_at;

  hooks.shutdown();
  if (!completion_is_unique_cancel) {
    return {std::nullopt,
            BenchmarkError(Status::kInvalidState,
                           "benchmark cancellation completion was invalid")};
  }

  const uint64_t elapsed = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          *first_completed_at - cancelled_at)
          .count());
  return {elapsed, std::nullopt};
}

Result<uint64_t> MeasureRealCancellationMilliseconds(
    const std::filesystem::path& mov_fixture) {
  QueueDispatcher dispatcher;
  ConversionController controller(dispatcher);
  CancellationMeasurementHooks hooks;
  hooks.start = [&controller, &mov_fixture](
                    Progress progress, BenchmarkCompletion completion) {
    return controller.Start(DefaultBenchmarkRequest(mov_fixture),
                            std::move(progress), std::move(completion));
  };
  hooks.cancel = [&controller] { controller.Cancel(); };
  hooks.pump = [&dispatcher](std::chrono::milliseconds timeout) {
    return dispatcher.RunOne(timeout);
  };
  hooks.wait_for_worker = [&controller] {
    return controller.WaitForCurrentJob(std::chrono::seconds(5));
  };
  hooks.shutdown = [&controller] { controller.Shutdown(); };
  return MeasureCancellationMillisecondsWithHooks(std::move(hooks));
}

Result<BenchmarkEvidence> RunTenSecondEquivalentBenchmark(
    const std::filesystem::path& mov_fixture) {
  BenchmarkEvidence evidence{CpuName(), PhysicalMemoryBytes(), WindowsVersion(),
                             0.0, 0.0, 0U, false, false};
  Result<std::unique_ptr<FrameSource>> opened = OpenMediaSource(mov_fixture);
  if (!opened.ok()) {
    return {std::nullopt, std::move(opened.error)};
  }
  const double one_source_seconds =
      static_cast<double>((*opened.value)->info().duration_100ns) / 10000000.0;
  if (one_source_seconds <= 0.0) {
    return {std::nullopt,
            BenchmarkError(Status::kUnsupportedMedia,
                           "benchmark duration is zero")};
  }
  const double target_source_seconds =
      BenchmarkSourceSecondsForDuration(one_source_seconds);
  const auto started = std::chrono::steady_clock::now();
  do {
    Result<ConversionResult> converted =
        ConvertMedia(DefaultBenchmarkRequest(mov_fixture),
                     [](uint32_t, uint32_t) {},
                     [] { return false; });
    if (!converted.ok()) {
      return {std::nullopt, std::move(converted.error)};
    }
    evidence.source_seconds += one_source_seconds;
  } while (evidence.source_seconds < target_source_seconds);
  evidence.elapsed_seconds = std::chrono::duration<double>(
                                 std::chrono::steady_clock::now() - started)
                                 .count();
  Result<uint64_t> cancel_ms =
      MeasureRealCancellationMilliseconds(mov_fixture);
  if (!cancel_ms.ok()) {
    return {std::nullopt, std::move(cancel_ms.error)};
  }
  evidence.cancel_milliseconds = *cancel_ms.value;
  return {EvaluateBenchmarkEvidence(std::move(evidence)), std::nullopt};
}

}  // namespace hmw::test
