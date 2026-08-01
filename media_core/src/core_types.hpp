#pragma once

#include <cstddef>
#include <limits>

namespace honey::media {

inline bool checked_add_size(std::size_t left, std::size_t right, std::size_t *result) noexcept
{
    if (result == nullptr || right > std::numeric_limits<std::size_t>::max() - left) {
        return false;
    }

    *result = left + right;
    return true;
}

inline bool checked_multiply_size(std::size_t left, std::size_t right, std::size_t *result) noexcept
{
    if (result == nullptr || (left != 0u && right > std::numeric_limits<std::size_t>::max() / left)) {
        return false;
    }

    *result = left * right;
    return true;
}

} // namespace honey::media
