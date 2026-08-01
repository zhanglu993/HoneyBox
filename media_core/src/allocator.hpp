#pragma once

#include "honey_media_core/media_core.h"

#include <cstddef>

namespace honey::media {

void *allocate(std::size_t size) noexcept;
void deallocate(void *pointer) noexcept;

#if defined(HMC_ENABLE_TEST_HOOKS)
HMC_API void allocation_test_fail_nth(std::size_t allocation_number) noexcept;
HMC_API void allocation_test_clear_failure() noexcept;
HMC_API std::size_t allocation_test_count() noexcept;
#endif

} // namespace honey::media
