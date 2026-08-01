#include "wic_helpers.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <objbase.h>
#include <propvarutil.h>
#include <wincodec.h>
#include <wrl/client.h>

#include "wic_metadata_internal.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace hmw::internal {

HRESULT GifUnsignedMetadataValue(const PROPVARIANT& value,
                                 VARTYPE expected_type, uint32_t* output) {
  if (value.vt != expected_type) {
    return WINCODEC_ERR_UNEXPECTEDMETADATATYPE;
  }
  switch (value.vt) {
    case VT_UI1:
      *output = value.bVal;
      return S_OK;
    case VT_UI2:
      *output = value.uiVal;
      return S_OK;
    case VT_UI4:
      *output = value.ulVal;
      return S_OK;
    case VT_UI8:
      if (value.uhVal.QuadPart <= std::numeric_limits<uint32_t>::max()) {
        *output = static_cast<uint32_t>(value.uhVal.QuadPart);
        return S_OK;
      }
      return HRESULT_FROM_WIN32(ERROR_ARITHMETIC_OVERFLOW);
    case VT_I1:
      if (value.cVal >= 0) {
        *output = static_cast<uint32_t>(value.cVal);
        return S_OK;
      }
      break;
    case VT_I2:
      if (value.iVal >= 0) {
        *output = static_cast<uint32_t>(value.iVal);
        return S_OK;
      }
      break;
    case VT_I4:
      if (value.lVal >= 0) {
        *output = static_cast<uint32_t>(value.lVal);
        return S_OK;
      }
      break;
    case VT_I8:
      if (value.hVal.QuadPart >= 0 &&
          static_cast<uint64_t>(value.hVal.QuadPart) <=
              std::numeric_limits<uint32_t>::max()) {
        *output = static_cast<uint32_t>(value.hVal.QuadPart);
        return S_OK;
      }
      break;
    default:
      break;
  }
  return WINCODEC_ERR_UNEXPECTEDMETADATATYPE;
}

HRESULT GifBooleanMetadataValue(const PROPVARIANT& value, bool* output) {
  if (value.vt != VT_BOOL) {
    return WINCODEC_ERR_UNEXPECTEDMETADATATYPE;
  }
  *output = value.boolVal != VARIANT_FALSE;
  return S_OK;
}

namespace {

using Microsoft::WRL::ComPtr;

constexpr int64_t kHundredNanosecondsPerCentisecond = 100000;
constexpr int64_t kFallbackDelay100ns = 1000000;
constexpr int64_t kMinimumDelay100ns = 100000;
constexpr int64_t kMaximumDelay100ns = 100000000;

class ComApartment {
 public:
  ComApartment() : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
  ~ComApartment() {
    if (result_ == S_OK || result_ == S_FALSE) {
      CoUninitialize();
    }
  }

  HRESULT result() const {
    return result_ == RPC_E_CHANGED_MODE ? S_OK : result_;
  }

 private:
  HRESULT result_;
};

class ScopedPropVariant {
 public:
  ScopedPropVariant() { PropVariantInit(&value_); }
  ~ScopedPropVariant() { PropVariantClear(&value_); }

  PROPVARIANT* get() { return &value_; }
  const PROPVARIANT& value() const { return value_; }

 private:
  PROPVARIANT value_;
};

class ScopedGlobalLock {
 public:
  explicit ScopedGlobalLock(HGLOBAL memory)
      : memory_(memory), data_(GlobalLock(memory)) {}
  ~ScopedGlobalLock() {
    if (data_ != nullptr) {
      GlobalUnlock(memory_);
    }
  }

  const uint8_t* data() const { return static_cast<const uint8_t*>(data_); }

 private:
  HGLOBAL memory_;
  void* data_;
};

template <typename T>
Result<T> Failure(Status status, const char* message) {
  return Result<T>{std::nullopt, Error{status, message}};
}

bool CheckedMultiply(size_t lhs, size_t rhs, size_t* product) {
  if (lhs != 0 && rhs > std::numeric_limits<size_t>::max() / lhs) {
    return false;
  }
  *product = lhs * rhs;
  return true;
}

bool PixelByteCount(uint32_t width, uint32_t height, size_t* byte_count) {
  size_t pixel_count = 0;
  return CheckedMultiply(static_cast<size_t>(width),
                         static_cast<size_t>(height), &pixel_count) &&
         CheckedMultiply(pixel_count, static_cast<size_t>(4), byte_count);
}

Status DecodeStatus(HRESULT result) {
  if (result == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
      result == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND)) {
    return Status::kNotFound;
  }
  return Status::kDecodeFailed;
}

HRESULT CreateFactory(ComPtr<IWICImagingFactory>* factory) {
  return CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                          CLSCTX_INPROC_SERVER,
                          __uuidof(IWICImagingFactory),
                          reinterpret_cast<void**>(
                              factory->ReleaseAndGetAddressOf()));
}

HRESULT QueryUnsigned(IWICMetadataQueryReader* reader, const wchar_t* name,
                      VARTYPE expected_type,
                      std::optional<uint32_t>* output) {
  output->reset();
  ScopedPropVariant value;
  const HRESULT result = reader->GetMetadataByName(name, value.get());
  if (result == WINCODEC_ERR_PROPERTYNOTFOUND ||
      result == WINCODEC_ERR_PROPERTYNOTSUPPORTED) {
    return S_OK;
  }
  if (FAILED(result)) {
    return result;
  }
  uint32_t converted = 0;
  const HRESULT conversion =
      GifUnsignedMetadataValue(value.value(), expected_type, &converted);
  if (SUCCEEDED(conversion)) {
    *output = converted;
  }
  return conversion;
}

HRESULT QueryBoolean(IWICMetadataQueryReader* reader, const wchar_t* name,
                     bool* output) {
  *output = false;
  ScopedPropVariant value;
  const HRESULT result = reader->GetMetadataByName(name, value.get());
  if (result == WINCODEC_ERR_PROPERTYNOTFOUND ||
      result == WINCODEC_ERR_PROPERTYNOTSUPPORTED) {
    return S_OK;
  }
  if (FAILED(result)) {
    return result;
  }
  return GifBooleanMetadataValue(value.value(), output);
}

HRESULT RequiredUnsigned(IWICMetadataQueryReader* reader, const wchar_t* name,
                         VARTYPE expected_type, uint32_t* output) {
  std::optional<uint32_t> value;
  const HRESULT result = QueryUnsigned(reader, name, expected_type, &value);
  if (FAILED(result)) {
    return result;
  }
  if (!value.has_value()) {
    return WINCODEC_ERR_PROPERTYNOTFOUND;
  }
  *output = *value;
  return S_OK;
}

HRESULT ReadIndexedPixels(IWICImagingFactory* factory,
                          IWICBitmapFrameDecode* frame,
                          uint32_t transparent_index, bool has_transparency,
                          uint32_t width, uint32_t height,
                          std::vector<uint8_t>* rgba) {
  WICPixelFormatGUID pixel_format{};
  HRESULT result = frame->GetPixelFormat(&pixel_format);
  if (FAILED(result)) {
    return result;
  }

  ComPtr<IWICBitmapSource> indexed_source;
  if (IsEqualGUID(pixel_format, GUID_WICPixelFormat8bppIndexed)) {
    indexed_source = frame;
  } else {
    ComPtr<IWICFormatConverter> converter;
    result = factory->CreateFormatConverter(&converter);
    if (SUCCEEDED(result)) {
      result = converter->Initialize(frame, GUID_WICPixelFormat8bppIndexed,
                                     WICBitmapDitherTypeNone, nullptr, 0.0,
                                     WICBitmapPaletteTypeCustom);
    }
    if (FAILED(result)) {
      return result;
    }
    indexed_source = converter;
  }

  size_t index_count = 0;
  if (!CheckedMultiply(static_cast<size_t>(width), static_cast<size_t>(height),
                       &index_count) ||
      index_count > std::numeric_limits<UINT>::max()) {
    return HRESULT_FROM_WIN32(ERROR_ARITHMETIC_OVERFLOW);
  }
  std::vector<uint8_t> indices(index_count);
  result = indexed_source->CopyPixels(nullptr, width,
                                      static_cast<UINT>(indices.size()),
                                      indices.data());
  if (FAILED(result)) {
    return result;
  }

  ComPtr<IWICPalette> palette;
  result = factory->CreatePalette(&palette);
  if (SUCCEEDED(result)) {
    result = frame->CopyPalette(palette.Get());
  }
  UINT color_count = 0;
  if (SUCCEEDED(result)) {
    result = palette->GetColorCount(&color_count);
  }
  if (FAILED(result) || color_count == 0 || color_count > 256) {
    return FAILED(result) ? result : WINCODEC_ERR_BADIMAGE;
  }
  std::vector<WICColor> colors(color_count);
  UINT copied_colors = 0;
  result = palette->GetColors(color_count, colors.data(), &copied_colors);
  if (FAILED(result) || copied_colors != color_count) {
    return FAILED(result) ? result : WINCODEC_ERR_BADIMAGE;
  }

  size_t rgba_size = 0;
  if (!PixelByteCount(width, height, &rgba_size)) {
    return HRESULT_FROM_WIN32(ERROR_ARITHMETIC_OVERFLOW);
  }
  rgba->assign(rgba_size, 0);
  for (size_t index = 0; index < index_count; ++index) {
    const uint32_t palette_index = indices[index];
    if (palette_index >= color_count) {
      return WINCODEC_ERR_BADIMAGE;
    }
    const WICColor color = colors[palette_index];
    const size_t output = index * static_cast<size_t>(4);
    (*rgba)[output] = static_cast<uint8_t>((color >> 16) & 0xffU);
    (*rgba)[output + 1] = static_cast<uint8_t>((color >> 8) & 0xffU);
    (*rgba)[output + 2] = static_cast<uint8_t>(color & 0xffU);
    (*rgba)[output + 3] =
        has_transparency && palette_index == transparent_index
            ? 0
            : static_cast<uint8_t>(255);
  }
  return S_OK;
}

}  // namespace

int64_t NormalizeGifDelay100ns(std::optional<int64_t> delay_100ns) {
  if (!delay_100ns.has_value() || *delay_100ns <= 0) {
    return kFallbackDelay100ns;
  }
  return std::clamp(*delay_100ns, kMinimumDelay100ns, kMaximumDelay100ns);
}

Result<std::vector<uint8_t>> EncodePngWithWic(const RgbaFrame& frame) {
  size_t byte_count = 0;
  if (frame.width == 0 || frame.height == 0 ||
      !PixelByteCount(frame.width, frame.height, &byte_count) ||
      frame.pixels.size() != byte_count ||
      frame.width > std::numeric_limits<UINT>::max() / 4U ||
      byte_count > std::numeric_limits<UINT>::max()) {
    return Failure<std::vector<uint8_t>>(
        Status::kInvalidArgument,
        "PNG input must be nonempty tightly packed RGBA within WIC limits");
  }

  try {
    ComApartment apartment;
    if (FAILED(apartment.result())) {
      return Failure<std::vector<uint8_t>>(Status::kEncodeFailed,
                                           "COM initialization failed");
    }
    ComPtr<IWICImagingFactory> factory;
    HRESULT result = CreateFactory(&factory);
    ComPtr<IStream> stream;
    if (SUCCEEDED(result)) {
      result = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
    }
    ComPtr<IWICBitmapEncoder> encoder;
    if (SUCCEEDED(result)) {
      result = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                      &encoder);
    }
    if (SUCCEEDED(result)) {
      result = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    }
    ComPtr<IWICBitmapFrameEncode> encoded_frame;
    ComPtr<IPropertyBag2> options;
    if (SUCCEEDED(result)) {
      result = encoder->CreateNewFrame(&encoded_frame, &options);
    }
    if (SUCCEEDED(result)) {
      result = encoded_frame->Initialize(options.Get());
    }
    if (SUCCEEDED(result)) {
      result = encoded_frame->SetSize(frame.width, frame.height);
    }
    WICPixelFormatGUID pixel_format = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(result)) {
      result = encoded_frame->SetPixelFormat(&pixel_format);
    }
    if (SUCCEEDED(result) &&
        !IsEqualGUID(pixel_format, GUID_WICPixelFormat32bppBGRA)) {
      result = WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT;
    }

    std::vector<uint8_t> bgra(byte_count);
    for (size_t index = 0; index < byte_count; index += 4) {
      bgra[index] = frame.pixels[index + 2];
      bgra[index + 1] = frame.pixels[index + 1];
      bgra[index + 2] = frame.pixels[index];
      bgra[index + 3] = frame.pixels[index + 3];
    }
    if (SUCCEEDED(result)) {
      result = encoded_frame->WritePixels(
          frame.height, frame.width * 4U, static_cast<UINT>(bgra.size()),
          bgra.data());
    }
    if (SUCCEEDED(result)) {
      result = encoded_frame->Commit();
    }
    if (SUCCEEDED(result)) {
      result = encoder->Commit();
    }

    STATSTG statistics{};
    if (SUCCEEDED(result)) {
      result = stream->Stat(&statistics, STATFLAG_NONAME);
    }
    if (SUCCEEDED(result) &&
        (statistics.cbSize.HighPart != 0 ||
         statistics.cbSize.LowPart > std::numeric_limits<size_t>::max())) {
      result = HRESULT_FROM_WIN32(ERROR_ARITHMETIC_OVERFLOW);
    }
    HGLOBAL memory = nullptr;
    if (SUCCEEDED(result)) {
      result = GetHGlobalFromStream(stream.Get(), &memory);
    }
    if (FAILED(result)) {
      return Failure<std::vector<uint8_t>>(Status::kEncodeFailed,
                                           "WIC PNG encoding failed");
    }
    ScopedGlobalLock locked(memory);
    if (locked.data() == nullptr) {
      return Failure<std::vector<uint8_t>>(Status::kEncodeFailed,
                                           "WIC PNG stream lock failed");
    }
    const size_t encoded_size = static_cast<size_t>(statistics.cbSize.LowPart);
    return Result<std::vector<uint8_t>>{
        std::vector<uint8_t>(locked.data(), locked.data() + encoded_size),
        std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<std::vector<uint8_t>>(Status::kIoError,
                                         "PNG buffer allocation failed");
  }
}

Result<DecodedGif> DecodeGifWithWic(const std::filesystem::path& path) {
  if (path.empty()) {
    return Failure<DecodedGif>(Status::kInvalidArgument,
                               "GIF path must not be empty");
  }
  try {
    ComApartment apartment;
    if (FAILED(apartment.result())) {
      return Failure<DecodedGif>(Status::kDecodeFailed,
                                 "COM initialization failed");
    }
    ComPtr<IWICImagingFactory> factory;
    HRESULT result = CreateFactory(&factory);
    ComPtr<IWICBitmapDecoder> decoder;
    if (SUCCEEDED(result)) {
      result = factory->CreateDecoderFromFilename(
          path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad,
          &decoder);
    }
    if (FAILED(result)) {
      return Failure<DecodedGif>(DecodeStatus(result),
                                 "WIC could not open the GIF source");
    }
    GUID container{};
    result = decoder->GetContainerFormat(&container);
    if (FAILED(result)) {
      return Failure<DecodedGif>(Status::kDecodeFailed,
                                 "WIC could not identify the media container");
    }
    if (!IsEqualGUID(container, GUID_ContainerFormatGif)) {
      return Failure<DecodedGif>(Status::kUnsupportedMedia,
                                 "media container is not GIF");
    }

    ComPtr<IWICMetadataQueryReader> logical_reader;
    result = decoder->GetMetadataQueryReader(&logical_reader);
    uint32_t canvas_width = 0;
    uint32_t canvas_height = 0;
    if (SUCCEEDED(result)) {
      result = RequiredUnsigned(logical_reader.Get(), L"/logscrdesc/Width",
                                VT_UI2, &canvas_width);
    }
    if (SUCCEEDED(result)) {
      result = RequiredUnsigned(logical_reader.Get(), L"/logscrdesc/Height",
                                VT_UI2, &canvas_height);
    }
    size_t canvas_bytes = 0;
    if (FAILED(result) || canvas_width == 0 || canvas_height == 0 ||
        !PixelByteCount(canvas_width, canvas_height, &canvas_bytes)) {
      return Failure<DecodedGif>(Status::kDecodeFailed,
                                 "GIF logical screen is invalid");
    }

    std::array<uint8_t, 4> background_rgba{0, 0, 0, 0};
    bool has_global_color_table = false;
    std::optional<uint32_t> background_index;
    result = QueryBoolean(logical_reader.Get(),
                          L"/logscrdesc/GlobalColorTableFlag",
                          &has_global_color_table);
    if (SUCCEEDED(result)) {
      result = QueryUnsigned(logical_reader.Get(),
                             L"/logscrdesc/BackgroundColorIndex",
                             VT_UI1,
                             &background_index);
    }
    if (FAILED(result)) {
      return Failure<DecodedGif>(Status::kDecodeFailed,
                                 "GIF logical background metadata is invalid");
    }
    if (has_global_color_table && background_index.has_value()) {
      ComPtr<IWICPalette> global_palette;
      HRESULT palette_result = factory->CreatePalette(&global_palette);
      if (SUCCEEDED(palette_result)) {
        palette_result = decoder->CopyPalette(global_palette.Get());
      }
      UINT color_count = 0;
      if (SUCCEEDED(palette_result)) {
        palette_result = global_palette->GetColorCount(&color_count);
      }
      if (SUCCEEDED(palette_result) && color_count > 0 && color_count <= 256 &&
          *background_index < color_count) {
        std::vector<WICColor> colors(color_count);
        UINT copied_colors = 0;
        palette_result = global_palette->GetColors(
            color_count, colors.data(), &copied_colors);
        if (SUCCEEDED(palette_result) && copied_colors == color_count) {
          const WICColor color = colors[*background_index];
          background_rgba = {
              static_cast<uint8_t>((color >> 16) & 0xffU),
              static_cast<uint8_t>((color >> 8) & 0xffU),
              static_cast<uint8_t>(color & 0xffU),
              static_cast<uint8_t>(255),
          };
        }
      }
    }

    UINT frame_count = 0;
    result = decoder->GetFrameCount(&frame_count);
    if (FAILED(result) || frame_count == 0) {
      return Failure<DecodedGif>(Status::kDecodeFailed,
                                 "GIF contains no decodable frames");
    }
    DecodedGif decoded{canvas_width, canvas_height, background_rgba, {}};
    decoded.frames.reserve(frame_count);
    for (UINT index = 0; index < frame_count; ++index) {
      ComPtr<IWICBitmapFrameDecode> frame;
      result = decoder->GetFrame(index, &frame);
      ComPtr<IWICMetadataQueryReader> frame_reader;
      if (SUCCEEDED(result)) {
        result = frame->GetMetadataQueryReader(&frame_reader);
      }
      uint32_t left = 0;
      uint32_t top = 0;
      uint32_t width = 0;
      uint32_t height = 0;
      if (SUCCEEDED(result)) {
        result = RequiredUnsigned(frame_reader.Get(), L"/imgdesc/Left", VT_UI2,
                                  &left);
      }
      if (SUCCEEDED(result)) {
        result = RequiredUnsigned(frame_reader.Get(), L"/imgdesc/Top", VT_UI2,
                                  &top);
      }
      if (SUCCEEDED(result)) {
        result = RequiredUnsigned(frame_reader.Get(), L"/imgdesc/Width", VT_UI2,
                                  &width);
      }
      if (SUCCEEDED(result)) {
        result = RequiredUnsigned(frame_reader.Get(), L"/imgdesc/Height", VT_UI2,
                                  &height);
      }
      if (FAILED(result) || width == 0 || height == 0 ||
          left > canvas_width || top > canvas_height ||
          width > canvas_width - left || height > canvas_height - top) {
        return Failure<DecodedGif>(Status::kDecodeFailed,
                                   "GIF frame rectangle is invalid");
      }

      UINT decoded_width = 0;
      UINT decoded_height = 0;
      result = frame->GetSize(&decoded_width, &decoded_height);
      if (FAILED(result) || decoded_width != width || decoded_height != height) {
        return Failure<DecodedGif>(Status::kDecodeFailed,
                                   "WIC GIF frame size does not match metadata");
      }
      std::optional<uint32_t> delay;
      std::optional<uint32_t> disposal;
      std::optional<uint32_t> transparent_index;
      bool has_transparency = false;
      result = QueryUnsigned(frame_reader.Get(), L"/grctlext/Delay", VT_UI2,
                             &delay);
      if (SUCCEEDED(result)) {
        result = QueryUnsigned(frame_reader.Get(), L"/grctlext/Disposal",
                               VT_UI1,
                               &disposal);
      }
      if (SUCCEEDED(result)) {
        result = QueryBoolean(frame_reader.Get(),
                              L"/grctlext/TransparencyFlag",
                              &has_transparency);
      }
      if (SUCCEEDED(result)) {
        result = QueryUnsigned(frame_reader.Get(),
                               L"/grctlext/TransparentColorIndex",
                               VT_UI1,
                               &transparent_index);
      }
      if (FAILED(result)) {
        return Failure<DecodedGif>(Status::kDecodeFailed,
                                   "GIF frame metadata is invalid");
      }
      std::optional<int64_t> delay_100ns;
      if (delay.has_value()) {
        delay_100ns = static_cast<int64_t>(*delay) *
                      kHundredNanosecondsPerCentisecond;
      }
      const uint32_t transparent = transparent_index.value_or(0);
      std::vector<uint8_t> pixels;
      result = ReadIndexedPixels(factory.Get(), frame.Get(), transparent,
                                 has_transparency, width, height, &pixels);
      if (FAILED(result)) {
        return Failure<DecodedGif>(Status::kDecodeFailed,
                                   "WIC GIF pixel decoding failed");
      }
      decoded.frames.push_back(GifFrameData{
          left, top, width, height, disposal.value_or(0),
          NormalizeGifDelay100ns(delay_100ns),
          std::move(pixels)});
    }
    return Result<DecodedGif>{std::move(decoded), std::nullopt};
  } catch (const std::bad_alloc&) {
    return Failure<DecodedGif>(Status::kIoError,
                               "GIF buffer allocation failed");
  }
}

}  // namespace hmw::internal
