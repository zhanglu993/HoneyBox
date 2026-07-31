#include "honey_media_core/media_core.h"

#include "core_types.hpp"

#include "test_support.hpp"

#include <cstdint>
#include <cstring>
#include <limits>

namespace {

HMC_TEST(abi_version_is_one)
{
    HMC_EXPECT(hmc_abi_version() == 1u);
}

HMC_TEST(status_messages_are_stable_and_non_empty)
{
    const hmc_status_t statuses[] = {
        HMC_STATUS_OK,
        HMC_STATUS_INVALID_ARGUMENT,
        HMC_STATUS_OUT_OF_MEMORY,
        HMC_STATUS_MALFORMED_DATA,
        HMC_STATUS_OVERFLOW,
        HMC_STATUS_INTERNAL_ERROR,
    };

    for (const hmc_status_t status : statuses) {
        const char *first = hmc_status_message(status);
        const char *second = hmc_status_message(status);
        HMC_EXPECT(first != nullptr);
        HMC_EXPECT(first[0] != '\0');
        HMC_EXPECT(second != nullptr);
        HMC_EXPECT(std::strcmp(first, second) == 0);
    }
}

HMC_TEST(releasing_an_empty_buffer_is_safe)
{
    hmc_owned_buffer_t buffer = {nullptr, 0u};
    hmc_owned_buffer_release(&buffer);
    HMC_EXPECT(buffer.data == nullptr);
    HMC_EXPECT(buffer.size == 0u);
}

HMC_TEST(checked_addition_rejects_overflow)
{
    std::size_t result = 0u;
    HMC_EXPECT(!honey::media::checked_add_size(std::numeric_limits<std::size_t>::max(), 1u, &result));
}

HMC_TEST(checked_multiplication_rejects_overflow)
{
    std::size_t result = 0u;
    HMC_EXPECT(!honey::media::checked_multiply_size(std::numeric_limits<std::size_t>::max(), 2u, &result));
}

} // namespace

int main()
{
    return honey::test::run_all_tests();
}
