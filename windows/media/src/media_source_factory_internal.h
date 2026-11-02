#pragma once

#include "honey_media_windows/status.h"

#include <filesystem>
#include <system_error>

namespace hmw::internal {

Result<bool> ValidateMediaFileStatus(
    const std::filesystem::file_status& file_status,
    const std::error_code& error);

}  // namespace hmw::internal
