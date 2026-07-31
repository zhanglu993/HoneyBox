#include "ebadge/media_core.h"

#include "core_types.hpp"

#include "test_support.hpp"

#include <cstdint>
#include <limits>

namespace {

void test_abi_version_is_one()
{
    EB_EXPECT(eb_media_abi_version() == 1u);
}

void test_status_messages_are_stable_and_non_empty()
{
    const eb_status_t statuses[] = {
        EB_STATUS_OK,
        EB_STATUS_INVALID_ARGUMENT,
        EB_STATUS_OUT_OF_MEMORY,
        EB_STATUS_MALFORMED_DATA,
        EB_STATUS_OVERFLOW,
        EB_STATUS_INTERNAL_ERROR,
    };

    for (const eb_status_t status : statuses) {
        const char *first = eb_status_message(status);
        const char *second = eb_status_message(status);
        EB_EXPECT(first != nullptr);
        EB_EXPECT(first[0] != '\0');
        EB_EXPECT(second != nullptr);
        EB_EXPECT(std::strcmp(first, second) == 0);
    }
}

void test_releasing_an_empty_buffer_is_safe()
{
    eb_buffer_t buffer = {nullptr, 0u};
    eb_buffer_release(&buffer);
    EB_EXPECT(buffer.data == nullptr);
    EB_EXPECT(buffer.size == 0u);
}

void test_checked_addition_rejects_overflow()
{
    std::size_t result = 0u;
    EB_EXPECT(!ebadge::media_core::checked_add_size(std::numeric_limits<std::size_t>::max(), 1u, &result));
}

void test_checked_multiplication_rejects_overflow()
{
    std::size_t result = 0u;
    EB_EXPECT(!ebadge::media_core::checked_multiply_size(std::numeric_limits<std::size_t>::max(), 2u, &result));
}

} // namespace

int main()
{
    test_abi_version_is_one();
    test_status_messages_are_stable_and_non_empty();
    test_releasing_an_empty_buffer_is_safe();
    test_checked_addition_rejects_overflow();
    test_checked_multiplication_rejects_overflow();
    return ebadge::test::failures == 0 ? 0 : 1;
}
