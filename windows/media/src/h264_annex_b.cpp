#include "h264_annex_b.h"

#include <cstddef>
#include <limits>
#include <optional>
#include <utility>

namespace hmw::internal {
namespace {

Outcome InvalidArgument(const char* message) {
  return {Error{Status::kInvalidArgument, message}};
}

Result<H264AnnexBAccessUnit> InvalidAccessUnit(const char* message) {
  return {std::nullopt, Error{Status::kInvalidArgument, message}};
}

bool Add(size_t left, size_t right, size_t* result) {
  if (right > (std::numeric_limits<size_t>::max)() - left) {
    return false;
  }
  *result = left + right;
  return true;
}

size_t StartCodeSizeAt(const std::vector<uint8_t>& bytes, size_t position) {
  if (position > bytes.size()) {
    return 0U;
  }
  const size_t remaining = bytes.size() - position;
  if (remaining >= 4U && bytes[position] == 0U &&
      bytes[position + 1U] == 0U && bytes[position + 2U] == 0U &&
      bytes[position + 3U] == 1U) {
    return 4U;
  }
  if (remaining >= 3U && bytes[position] == 0U &&
      bytes[position + 1U] == 0U && bytes[position + 2U] == 1U) {
    return 3U;
  }
  return 0U;
}

bool ParseAnnexB(const std::vector<uint8_t>& sample,
                 std::vector<std::vector<uint8_t>>* nals) {
  const size_t first_start_code = StartCodeSizeAt(sample, 0U);
  if (first_start_code == 0U || first_start_code == sample.size()) {
    return false;
  }
  size_t position = first_start_code;
  while (position < sample.size()) {
    const size_t nal_start = position;
    while (position < sample.size() && StartCodeSizeAt(sample, position) == 0U) {
      ++position;
    }
    if (position == nal_start) {
      return false;
    }
    nals->emplace_back(sample.begin() + static_cast<std::ptrdiff_t>(nal_start),
                       sample.begin() + static_cast<std::ptrdiff_t>(position));
    if (position == sample.size()) {
      return true;
    }
    position += StartCodeSizeAt(sample, position);
    if (position == sample.size()) {
      return false;
    }
  }
  return !nals->empty();
}

bool ParseLengthPrefixed(const std::vector<uint8_t>& sample,
                         size_t length_size,
                         std::vector<std::vector<uint8_t>>* nals) {
  if (sample.empty() || length_size == 0U || length_size > 4U) {
    return false;
  }
  size_t position = 0U;
  while (position < sample.size()) {
    if (sample.size() - position < length_size) {
      return false;
    }
    uint32_t nal_size = 0U;
    for (size_t i = 0U; i < length_size; ++i) {
      nal_size = (nal_size << 8U) | sample[position + i];
    }
    position += length_size;
    if (nal_size == 0U || nal_size > sample.size() - position) {
      return false;
    }
    const size_t nal_end = position + nal_size;
    nals->emplace_back(sample.begin() + static_cast<std::ptrdiff_t>(position),
                       sample.begin() + static_cast<std::ptrdiff_t>(nal_end));
    position = nal_end;
  }
  return !nals->empty();
}

bool ReadUint16(const std::vector<uint8_t>& bytes, size_t* position,
                uint16_t* value) {
  if (*position > bytes.size() || bytes.size() - *position < 2U) {
    return false;
  }
  *value = static_cast<uint16_t>((static_cast<uint16_t>(bytes[*position]) << 8U) |
                                 bytes[*position + 1U]);
  *position += 2U;
  return true;
}

bool ReadParameterSets(const std::vector<uint8_t>& header, size_t* position,
                       size_t count, uint8_t expected_type,
                       std::vector<std::vector<uint8_t>>* parameter_sets) {
  if (count == 0U) {
    return false;
  }
  for (size_t i = 0U; i < count; ++i) {
    uint16_t size = 0U;
    if (!ReadUint16(header, position, &size) || size == 0U ||
        *position > header.size() || size > header.size() - *position) {
      return false;
    }
    const size_t end = *position + size;
    if ((header[*position] & 0x1fU) != expected_type) {
      return false;
    }
    parameter_sets->emplace_back(
        header.begin() + static_cast<std::ptrdiff_t>(*position),
        header.begin() + static_cast<std::ptrdiff_t>(end));
    *position = end;
  }
  return true;
}

bool ContainsType(const std::vector<std::vector<uint8_t>>& nals, uint8_t type) {
  for (const std::vector<uint8_t>& nal : nals) {
    if (!nal.empty() && (nal.front() & 0x1fU) == type) {
      return true;
    }
  }
  return false;
}

bool AppendNals(const std::vector<std::vector<uint8_t>>& nals,
                size_t* total) {
  for (const std::vector<uint8_t>& nal : nals) {
    size_t next = 0U;
    if (nal.empty() || !Add(*total, 4U, &next) ||
        !Add(next, nal.size(), total)) {
      return false;
    }
  }
  return true;
}

void AppendNormalized(const std::vector<std::vector<uint8_t>>& nals,
                      std::vector<uint8_t>* output) {
  for (const std::vector<uint8_t>& nal : nals) {
    output->insert(output->end(), {0U, 0U, 0U, 1U});
    output->insert(output->end(), nal.begin(), nal.end());
  }
}

}  // namespace

Outcome H264AnnexBNormalizer::SetSequenceHeader(
    const std::vector<uint8_t>& sequence_header) {
  if (sequence_header.size() < 7U || sequence_header[0] != 1U ||
      (sequence_header[4] & 0xfcU) != 0xfcU ||
      (sequence_header[5] & 0xe0U) != 0xe0U) {
    return InvalidArgument("Invalid AVCC sequence header.");
  }

  const size_t next_length_size = (sequence_header[4] & 0x03U) + 1U;
  size_t position = 6U;
  std::vector<std::vector<uint8_t>> next_sps;
  if (!ReadParameterSets(sequence_header, &position,
                         sequence_header[5] & 0x1fU, 7U, &next_sps) ||
      position >= sequence_header.size()) {
    return InvalidArgument("Invalid AVCC SPS parameter sets.");
  }

  const size_t pps_count = sequence_header[position++];
  std::vector<std::vector<uint8_t>> next_pps;
  if (!ReadParameterSets(sequence_header, &position, pps_count, 8U, &next_pps) ||
      position != sequence_header.size()) {
    return InvalidArgument("Invalid AVCC PPS parameter sets.");
  }

  nal_length_size_ = next_length_size;
  sps_ = std::move(next_sps);
  pps_ = std::move(next_pps);
  avcc_configuration_set_ = true;
  return {};
}

Result<H264AnnexBAccessUnit> H264AnnexBNormalizer::Normalize(
    const std::vector<uint8_t>& sample, bool clean_point) const {
  std::vector<std::vector<uint8_t>> nals;
  const bool parsed = avcc_configuration_set_
                          ? ParseLengthPrefixed(sample, nal_length_size_, &nals)
                          : StartCodeSizeAt(sample, 0U) != 0U
                                ? ParseAnnexB(sample, &nals)
                                : ParseLengthPrefixed(sample, nal_length_size_, &nals);
  if (!parsed) {
    return InvalidAccessUnit("Malformed H.264 access unit.");
  }

  const bool has_sps = ContainsType(nals, 7U);
  const bool has_pps = ContainsType(nals, 8U);
  const bool key = clean_point || ContainsType(nals, 5U);
  size_t output_size = 0U;
  if ((key && !has_sps && !AppendNals(sps_, &output_size)) ||
      (key && !has_pps && !AppendNals(pps_, &output_size)) ||
      !AppendNals(nals, &output_size)) {
    return InvalidAccessUnit("Normalized H.264 access unit is too large.");
  }

  std::vector<uint8_t> bytes;
  bytes.reserve(output_size);
  if (key && !has_sps) {
    AppendNormalized(sps_, &bytes);
  }
  if (key && !has_pps) {
    AppendNormalized(pps_, &bytes);
  }
  AppendNormalized(nals, &bytes);
  return {H264AnnexBAccessUnit{std::move(bytes), key}, std::nullopt};
}

}  // namespace hmw::internal
