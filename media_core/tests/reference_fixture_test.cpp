#include "test_support.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace {

std::vector<std::uint8_t> read_fixture(const char *name)
{
    const std::string path = std::string(HMC_FIXTURE_DIRECTORY) + "/" + name;
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        return {};
    }
    return std::vector<std::uint8_t>(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}

bool has_prefix(const std::vector<std::uint8_t> &bytes, std::size_t offset, const char *prefix)
{
    for (std::size_t index = 0u; prefix[index] != '\0'; ++index) {
        if (offset + index >= bytes.size() || bytes[offset + index] != static_cast<std::uint8_t>(prefix[index])) {
            return false;
        }
    }
    return true;
}

HMC_TEST(reference_fixtures_are_present_and_well_formed)
{
    constexpr std::array<const char *, 16u> fixtures = {
        "input_8x8_a.rgba", "input_8x8_b.rgba",
        "msv1_key.bin", "msv1_all_skip.bin", "msv1_inter.bin",
        "msv1_key.argb", "msv1_all_skip.argb", "msv1_inter.argb", "msvc_sample.avi",
        "cinepak_key.bin", "cinepak_all_skip.bin", "cinepak_inter.bin",
        "cinepak_key.argb", "cinepak_all_skip.argb", "cinepak_inter.argb", "cvid_sample.avi",
    };

    for (const char *fixture : fixtures) {
        HMC_EXPECT(!read_fixture(fixture).empty());
    }

    HMC_EXPECT(read_fixture("input_8x8_a.rgba").size() == 256u);
    HMC_EXPECT(read_fixture("input_8x8_b.rgba").size() == 256u);

    for (const char *fixture : {"msv1_key.argb", "msv1_all_skip.argb", "msv1_inter.argb",
                                "cinepak_key.argb", "cinepak_all_skip.argb", "cinepak_inter.argb"}) {
        HMC_EXPECT(read_fixture(fixture).size() == 256u);
    }

    for (const char *fixture : {"msvc_sample.avi", "cvid_sample.avi"}) {
        const std::vector<std::uint8_t> avi = read_fixture(fixture);
        HMC_EXPECT(has_prefix(avi, 0u, "RIFF"));
        HMC_EXPECT(has_prefix(avi, 8u, "AVI "));
    }
}

} // namespace
