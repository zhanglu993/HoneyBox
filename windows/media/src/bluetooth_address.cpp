#include "honey_media_windows/bluetooth_link.h"

namespace hmw {
namespace {

constexpr size_t kOctets = 6U;
constexpr size_t kTextLength = kOctets * 3U - 1U;  // "AA:BB:CC:DD:EE:FF"

bool HexDigit(char value, uint64_t* digit) {
  if (value >= '0' && value <= '9') {
    *digit = static_cast<uint64_t>(value - '0');
    return true;
  }
  if (value >= 'a' && value <= 'f') {
    *digit = static_cast<uint64_t>(value - 'a') + 10U;
    return true;
  }
  if (value >= 'A' && value <= 'F') {
    *digit = static_cast<uint64_t>(value - 'A') + 10U;
    return true;
  }
  return false;
}

}  // namespace

bool ParseBluetoothAddress(std::string_view text, uint64_t* address) {
  if (address == nullptr || text.size() != kTextLength) {
    return false;
  }
  uint64_t parsed = 0U;
  for (size_t octet = 0U; octet < kOctets; ++octet) {
    const size_t start = octet * 3U;
    if (octet != 0U && text[start - 1U] != ':') {
      return false;
    }
    uint64_t high = 0U;
    uint64_t low = 0U;
    if (!HexDigit(text[start], &high) || !HexDigit(text[start + 1U], &low)) {
      return false;
    }
    parsed = (parsed << 8) | (high << 4) | low;
  }
  *address = parsed;
  return true;
}

}  // namespace hmw
