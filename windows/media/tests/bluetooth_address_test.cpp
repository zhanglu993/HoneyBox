#include "honey_media_windows/bluetooth_link.h"

#include "test_support.h"

#include <cstdint>

HMW_TEST(bluetooth_address_parses_a_colon_separated_address) {
  uint64_t address = 0U;
  HMW_EXPECT(hmw::ParseBluetoothAddress("03:22:33:77:33:13", &address));
  HMW_EXPECT(address == 0x032233773313ULL);
}

HMW_TEST(bluetooth_address_accepts_lower_case_hex) {
  uint64_t address = 0U;
  HMW_EXPECT(hmw::ParseBluetoothAddress("aa:bb:cc:dd:ee:ff", &address));
  HMW_EXPECT(address == 0xAABBCCDDEEFFULL);
}

HMW_TEST(bluetooth_address_keeps_leading_zero_octets) {
  uint64_t address = 0xFFFFFFFFFFFFULL;
  HMW_EXPECT(hmw::ParseBluetoothAddress("00:00:00:00:00:01", &address));
  HMW_EXPECT(address == 1ULL);
}

HMW_TEST(bluetooth_address_rejects_malformed_input) {
  uint64_t address = 0U;
  // Wrong octet count, wrong separator, non-hex, short octets, empty.
  HMW_EXPECT(!hmw::ParseBluetoothAddress("03:22:33:77:33", &address));
  HMW_EXPECT(!hmw::ParseBluetoothAddress("03:22:33:77:33:13:99", &address));
  HMW_EXPECT(!hmw::ParseBluetoothAddress("03-22-33-77-33-13", &address));
  HMW_EXPECT(!hmw::ParseBluetoothAddress("03:22:33:77:33:zz", &address));
  HMW_EXPECT(!hmw::ParseBluetoothAddress("3:22:33:77:33:13", &address));
  HMW_EXPECT(!hmw::ParseBluetoothAddress("", &address));
}

HMW_TEST(bluetooth_address_rejects_a_null_output) {
  HMW_EXPECT(!hmw::ParseBluetoothAddress("03:22:33:77:33:13", nullptr));
}

HMW_TEST(bluetooth_address_leaves_the_output_untouched_on_failure) {
  uint64_t address = 0x123456789ABCULL;
  HMW_EXPECT(!hmw::ParseBluetoothAddress("not an address", &address));
  HMW_EXPECT(address == 0x123456789ABCULL);
}
