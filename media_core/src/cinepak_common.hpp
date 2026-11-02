#pragma once

#include <cstdint>

namespace honey::media {

inline std::int16_t decode_cinepak_signed_byte(std::uint8_t value) noexcept
{
    return value < UINT8_C(0x80)
        ? static_cast<std::int16_t>(value)
        : static_cast<std::int16_t>(static_cast<std::int32_t>(value) - 256);
}

struct CinepakCodebookEntry {
    std::int16_t y[4];
    std::int16_t u;
    std::int16_t v;
};

} // namespace honey::media
