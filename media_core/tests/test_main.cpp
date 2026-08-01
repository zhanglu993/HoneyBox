#include "honey_media_core/media_core.h"

#include "core_types.hpp"

#include "test_support.hpp"

#include <cstdint>
#include <cstring>
#include <limits>

namespace {

static_assert(sizeof(hmc_status_t) == sizeof(std::int32_t), "hmc_status_t must be exactly 32 bits");
static_assert(sizeof(hmc_encode_flags_t) == sizeof(std::uint32_t), "encode flags must be exactly 32 bits");
static_assert(sizeof(hmc_frame_flags_t) == sizeof(std::uint32_t), "frame flags must be exactly 32 bits");

HMC_TEST(abi_version_is_packed_one_zero)
{
    HMC_EXPECT(HMC_ABI_VERSION_1_0 == UINT32_C(0x00010000));
    HMC_EXPECT(HMC_ABI_VERSION_CURRENT == HMC_ABI_VERSION_1_0);
    HMC_EXPECT(HMC_ABI_VERSION_GET_MAJOR(HMC_ABI_VERSION_CURRENT) == UINT32_C(1));
    HMC_EXPECT(HMC_ABI_VERSION_GET_MINOR(HMC_ABI_VERSION_CURRENT) == UINT32_C(0));
    HMC_EXPECT(hmc_abi_version() == UINT32_C(0x00010000));
}

HMC_TEST(status_and_flag_values_are_frozen)
{
    HMC_EXPECT(HMC_STATUS_OK == static_cast<hmc_status_t>(0));
    HMC_EXPECT(HMC_STATUS_INVALID_ARGUMENT == static_cast<hmc_status_t>(1));
    HMC_EXPECT(HMC_STATUS_OUT_OF_MEMORY == static_cast<hmc_status_t>(2));
    HMC_EXPECT(HMC_STATUS_MALFORMED_DATA == static_cast<hmc_status_t>(3));
    HMC_EXPECT(HMC_STATUS_OVERFLOW == static_cast<hmc_status_t>(4));
    HMC_EXPECT(HMC_STATUS_INTERNAL_ERROR == static_cast<hmc_status_t>(5));
    HMC_EXPECT(HMC_STATUS_UNSUPPORTED == static_cast<hmc_status_t>(6));
    HMC_EXPECT(HMC_STATUS_BUFFER_TOO_SMALL == static_cast<hmc_status_t>(7));
    HMC_EXPECT(HMC_STATUS_INVALID_STATE == static_cast<hmc_status_t>(8));

    HMC_EXPECT(HMC_ENCODE_FLAG_NONE == UINT32_C(0));
    HMC_EXPECT(HMC_ENCODE_FLAG_FORCE_KEY == UINT32_C(0x00000001));
    HMC_EXPECT(HMC_FRAME_FLAG_NONE == UINT32_C(0));
    HMC_EXPECT(HMC_FRAME_FLAG_KEY == UINT32_C(0x00000001));
    HMC_EXPECT(HMC_FRAME_FLAG_KEY_KNOWN == UINT32_C(0x00000002));
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
        HMC_STATUS_UNSUPPORTED,
        HMC_STATUS_BUFFER_TOO_SMALL,
        HMC_STATUS_INVALID_STATE,
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
