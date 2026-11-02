#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <propidl.h>

#include <cstdint>

namespace hmw::internal {

HRESULT GifUnsignedMetadataValue(const PROPVARIANT& value,
                                 VARTYPE expected_type, uint32_t* output);
HRESULT GifBooleanMetadataValue(const PROPVARIANT& value, bool* output);

}  // namespace hmw::internal
