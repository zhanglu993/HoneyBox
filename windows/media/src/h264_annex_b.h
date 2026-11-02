#pragma once

#include "honey_media_windows/status.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace hmw::internal {

struct H264AnnexBAccessUnit {
  std::vector<uint8_t> bytes;
  bool key;
};

class H264AnnexBNormalizer {
 public:
  Outcome SetSequenceHeader(const std::vector<uint8_t>& sequence_header);
  Result<H264AnnexBAccessUnit> Normalize(const std::vector<uint8_t>& sample,
                                         bool clean_point) const;

 private:
  size_t nal_length_size_ = 4U;
  bool avcc_configuration_set_ = false;
  std::vector<std::vector<uint8_t>> sps_;
  std::vector<std::vector<uint8_t>> pps_;
};

}  // namespace hmw::internal
