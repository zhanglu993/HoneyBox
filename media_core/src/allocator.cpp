#include "allocator.hpp"

#if defined(HMC_ENABLE_TEST_HOOKS)
#include <atomic>
#endif
#include <cstdlib>

namespace honey::media {
namespace {

#if defined(HMC_ENABLE_TEST_HOOKS)
std::atomic<std::size_t> g_fail_allocation{0u};
std::atomic<std::size_t> g_allocation_count{0u};
#endif

} // namespace

void *allocate(std::size_t size) noexcept
{
#if defined(HMC_ENABLE_TEST_HOOKS)
    const std::size_t allocation = g_allocation_count.fetch_add(1u) + 1u;
    if (g_fail_allocation.load() == allocation) {
        return nullptr;
    }
#endif
    return std::malloc(size);
}

void deallocate(void *pointer) noexcept
{
    std::free(pointer);
}

#if defined(HMC_ENABLE_TEST_HOOKS)
HMC_API void allocation_test_fail_nth(std::size_t allocation_number) noexcept
{
    g_allocation_count.store(0u);
    g_fail_allocation.store(allocation_number);
}

HMC_API void allocation_test_clear_failure() noexcept
{
    g_fail_allocation.store(0u);
    g_allocation_count.store(0u);
}

HMC_API std::size_t allocation_test_count() noexcept
{
    return g_allocation_count.load();
}
#endif

} // namespace honey::media
