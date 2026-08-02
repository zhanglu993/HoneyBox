#include "benchmark_support.h"

#include "honey_media_windows/conversion_controller.h"
#include "honey_media_windows/media_source.h"
#include "honey_media_windows/platform_dispatcher.h"

#include <Windows.h>

#include <chrono>
#include <condition_variable>
#include <deque>
#include <iomanip>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
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

Result<uint64_t> MeasureRealCancellationMilliseconds(
    const std::filesystem::path& mov_fixture) {
  QueueDispatcher dispatcher;
  ConversionController controller(dispatcher);
  bool saw_progress = false;
  bool completed = false;
  uint32_t completion_count = 0U;
  Result<MediaJobResult> completion_result{};
  const Result<uint64_t> started = controller.Start(
      DefaultBenchmarkRequest(mov_fixture),
      [&saw_progress](uint32_t, uint32_t) { saw_progress = true; },
      [&completed, &completion_count,
       &completion_result](Result<MediaJobResult> result) {
        ++completion_count;
        completion_result = std::move(result);
        completed = true;
      });
  if (!started.ok()) {
    return {std::nullopt, std::move(started.error)};
  }

  const auto progress_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(30);
  while (!saw_progress && std::chrono::steady_clock::now() < progress_deadline) {
    (void)dispatcher.RunOne(std::chrono::milliseconds(100));
  }
  if (!saw_progress) {
    controller.Shutdown();
    return {std::nullopt,
            BenchmarkError(Status::kInvalidState,
                           "benchmark did not report progress")};
  }

  const auto cancelled_at = std::chrono::steady_clock::now();
  controller.Cancel();
  const auto completion_deadline = cancelled_at + std::chrono::seconds(5);
  while (!completed &&
         std::chrono::steady_clock::now() < completion_deadline) {
    (void)dispatcher.RunOne(std::chrono::milliseconds(100));
  }
  const uint64_t elapsed = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - cancelled_at)
          .count());
  controller.Shutdown();
  if (!completed || completion_count != 1U || completion_result.ok() ||
      !completion_result.error.has_value() ||
      completion_result.error->status != Status::kCancelled) {
    return {std::nullopt,
            BenchmarkError(Status::kInvalidState,
                           "benchmark cancellation completion was invalid")};
  }
  return {elapsed, std::nullopt};
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
