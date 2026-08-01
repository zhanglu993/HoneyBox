#include "honey_media_windows/media_source.h"

#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <system_error>

namespace hmw {

Result<std::unique_ptr<FrameSource>> OpenMediaFoundationSource(
    const std::filesystem::path& path);

namespace {

template <typename T>
Result<T> Failure(Status status, const char* message) {
  return Result<T>{std::nullopt, Error{status, message}};
}

bool HasGifSignature(const std::array<uint8_t, 6>& signature) {
  const bool prefix = signature[0] == 'G' && signature[1] == 'I' &&
                      signature[2] == 'F' && signature[3] == '8';
  return prefix && (signature[4] == '7' || signature[4] == '9') &&
         signature[5] == 'a';
}

}  // namespace

Result<std::unique_ptr<FrameSource>> OpenMediaSource(
    const std::filesystem::path& path) {
  if (path.empty()) {
    return Failure<std::unique_ptr<FrameSource>>(
        Status::kInvalidArgument, "media source path must not be empty");
  }
  std::error_code error;
  const std::filesystem::file_status status =
      std::filesystem::status(path, error);
  if (error == std::errc::no_such_file_or_directory ||
      !std::filesystem::exists(status)) {
    return Failure<std::unique_ptr<FrameSource>>(
        Status::kNotFound, "media source was not found");
  }
  if (error) {
    return Failure<std::unique_ptr<FrameSource>>(
        Status::kIoError, "media source status query failed");
  }
  if (!std::filesystem::is_regular_file(status)) {
    return Failure<std::unique_ptr<FrameSource>>(
        Status::kUnsupportedMedia, "media source is not a regular file");
  }

  std::ifstream stream(path, std::ios::binary);
  if (!stream) {
    return Failure<std::unique_ptr<FrameSource>>(
        Status::kIoError, "media source could not be opened for probing");
  }
  std::array<uint8_t, 6> signature{};
  stream.read(reinterpret_cast<char*>(signature.data()),
              static_cast<std::streamsize>(signature.size()));
  const std::streamsize bytes_read = stream.gcount();
  if (bytes_read == static_cast<std::streamsize>(signature.size()) &&
      HasGifSignature(signature)) {
    return OpenGifSource(path);
  }
  return OpenMediaFoundationSource(path);
}

}  // namespace hmw
