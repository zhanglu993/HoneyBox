#pragma once

#include <cstdint>

namespace honey::media {

struct CinepakCodebookEntry {
    std::int16_t y[4];
    std::int16_t u;
    std::int16_t v;
};

} // namespace honey::media
