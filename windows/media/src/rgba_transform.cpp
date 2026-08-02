#include "honey_media_windows/rgba_transform.h"

#include "rgba_transform_internal.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>
#include <new>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace hmw::internal {

SamplingBounds SamplingBoundsForCrop(double crop_start, double crop_extent,
                                     uint32_t source_length) {
  if (source_length == 0) {
    return SamplingBounds{0.0, 0.0};
  }
  const double source_maximum = static_cast<double>(source_length) - 1.0;
  const double minimum = std::clamp(crop_start, 0.0, source_maximum);
  const double maximum = std::max(
      minimum, std::clamp(crop_start + crop_extent - 1.0, 0.0, source_maximum));
  return SamplingBounds{minimum, maximum};
}

}  // namespace hmw::internal

namespace hmw {
namespace {

struct PixelRect {
  double x;
  double y;
  double width;
  double height;
};

Result<RgbaFrame> InvalidArgument(const char* message) {
  return Result<RgbaFrame>{std::nullopt,
                           Error{Status::kInvalidArgument, message}};
}

Result<RgbaFrame> AllocationFailure() {
  return Result<RgbaFrame>{std::nullopt,
                           Error{Status::kIoError, "RGBA buffer allocation failed"}};
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
  return CheckedMultiply(static_cast<size_t>(width), static_cast<size_t>(height),
                         &pixel_count) &&
         CheckedMultiply(pixel_count, static_cast<size_t>(4), byte_count);
}

size_t PixelOffset(size_t x, size_t y, size_t width) {
  return (y * width + x) * static_cast<size_t>(4);
}

bool ValidRotation(uint32_t degrees) {
  return degrees == 0 || degrees == 90 || degrees == 180 || degrees == 270;
}

uint8_t RoundedChannel(double value) {
  const double clamped = std::clamp(value, 0.0, 255.0);
  return static_cast<uint8_t>(std::floor(clamped + 0.5));
}

void WriteArgbBackground(std::vector<uint8_t>* pixels, uint32_t argb) {
  const uint8_t alpha = static_cast<uint8_t>((argb >> 24) & 0xffU);
  const uint8_t red = static_cast<uint8_t>((argb >> 16) & 0xffU);
  const uint8_t green = static_cast<uint8_t>((argb >> 8) & 0xffU);
  const uint8_t blue = static_cast<uint8_t>(argb & 0xffU);
  for (size_t index = 0; index < pixels->size(); index += 4) {
    (*pixels)[index] = red;
    (*pixels)[index + 1] = green;
    (*pixels)[index + 2] = blue;
    (*pixels)[index + 3] = alpha;
  }
}

void RotateClockwise(const RgbaFrame& source, uint32_t degrees,
                     std::vector<uint8_t>* upright_pixels,
                     uint32_t* upright_width, uint32_t* upright_height) {
  if (degrees == 0) {
    *upright_pixels = source.pixels;
    *upright_width = source.width;
    *upright_height = source.height;
    return;
  }

  *upright_width = degrees == 180 ? source.width : source.height;
  *upright_height = degrees == 180 ? source.height : source.width;
  const size_t upright_width_size = static_cast<size_t>(*upright_width);
  const size_t source_width_size = static_cast<size_t>(source.width);
  for (size_t source_y = 0; source_y < static_cast<size_t>(source.height);
       ++source_y) {
    for (size_t source_x = 0; source_x < source_width_size; ++source_x) {
      size_t destination_x = 0;
      size_t destination_y = 0;
      switch (degrees) {
        case 90:
          destination_x = static_cast<size_t>(source.height) - 1 - source_y;
          destination_y = source_x;
          break;
        case 180:
          destination_x = source_width_size - 1 - source_x;
          destination_y = static_cast<size_t>(source.height) - 1 - source_y;
          break;
        case 270:
          destination_x = source_y;
          destination_y = source_width_size - 1 - source_x;
          break;
        default:
          return;
      }
      const size_t source_offset = PixelOffset(source_x, source_y, source_width_size);
      const size_t destination_offset =
          PixelOffset(destination_x, destination_y, upright_width_size);
      for (size_t channel = 0; channel < 4; ++channel) {
        (*upright_pixels)[destination_offset + channel] =
            source.pixels[source_offset + channel];
      }
    }
  }
}

bool ExplicitCrop(const CropRect& crop, uint32_t width, uint32_t height,
                  PixelRect* selected) {
  if (!std::isfinite(crop.x) || !std::isfinite(crop.y) ||
      !std::isfinite(crop.width) || !std::isfinite(crop.height) ||
      crop.width <= 0.0 || crop.height <= 0.0) {
    return false;
  }

  const double left = std::clamp(crop.x, 0.0, 1.0);
  const double top = std::clamp(crop.y, 0.0, 1.0);
  const double right = std::clamp(crop.x + crop.width, 0.0, 1.0);
  const double bottom = std::clamp(crop.y + crop.height, 0.0, 1.0);
  if (right <= left || bottom <= top) {
    return false;
  }

  const double width_double = static_cast<double>(width);
  const double height_double = static_cast<double>(height);
  const double start_x = std::floor(left * width_double + 0.5);
  const double start_y = std::floor(top * height_double + 0.5);
  const double end_x = std::floor(right * width_double + 0.5);
  const double end_y = std::floor(bottom * height_double + 0.5);
  const double clamped_start_x = std::clamp(start_x, 0.0, width_double - 1.0);
  const double clamped_start_y = std::clamp(start_y, 0.0, height_double - 1.0);
  const double clamped_end_x = std::clamp(end_x, clamped_start_x + 1.0, width_double);
  const double clamped_end_y = std::clamp(end_y, clamped_start_y + 1.0, height_double);
  *selected = PixelRect{clamped_start_x, clamped_start_y,
                        clamped_end_x - clamped_start_x,
                        clamped_end_y - clamped_start_y};
  return true;
}

PixelRect CenterCoverCrop(uint32_t source_width, uint32_t source_height,
                          uint32_t output_width, uint32_t output_height) {
  const double source_width_double = static_cast<double>(source_width);
  const double source_height_double = static_cast<double>(source_height);
  const double target_aspect = static_cast<double>(output_width) /
                               static_cast<double>(output_height);
  const double source_aspect = source_width_double / source_height_double;
  if (source_aspect > target_aspect) {
    const double width = source_height_double * target_aspect;
    return PixelRect{(source_width_double - width) / 2.0, 0.0, width,
                     source_height_double};
  }
  const double height = source_width_double / target_aspect;
  return PixelRect{0.0, (source_height_double - height) / 2.0,
                   source_width_double, height};
}

void BilinearScale(const std::vector<uint8_t>& source_pixels,
                   uint32_t source_width, uint32_t source_height,
                   const PixelRect& crop, uint32_t destination_x,
                   uint32_t destination_y, uint32_t destination_width,
                   uint32_t destination_height, uint32_t destination_canvas_width,
                   std::vector<uint8_t>* destination) {
  const internal::SamplingBounds horizontal_bounds =
      internal::SamplingBoundsForCrop(crop.x, crop.width, source_width);
  const internal::SamplingBounds vertical_bounds =
      internal::SamplingBoundsForCrop(crop.y, crop.height, source_height);
  const size_t source_width_size = static_cast<size_t>(source_width);
  const size_t destination_width_size = static_cast<size_t>(destination_width);
  for (size_t output_y = 0; output_y < static_cast<size_t>(destination_height);
       ++output_y) {
    const double mapped_y = crop.y +
        ((static_cast<double>(output_y) + 0.5) * crop.height /
         static_cast<double>(destination_height) - 0.5);
    const double sample_y = std::clamp(
        mapped_y, vertical_bounds.minimum, vertical_bounds.maximum);
    const size_t y0 = static_cast<size_t>(std::floor(sample_y));
    const size_t y1 = static_cast<size_t>(std::ceil(sample_y));
    const double y_fraction = sample_y - static_cast<double>(y0);
    for (size_t output_x = 0; output_x < destination_width_size; ++output_x) {
      const double mapped_x = crop.x +
          ((static_cast<double>(output_x) + 0.5) * crop.width /
           static_cast<double>(destination_width) - 0.5);
      const double sample_x = std::clamp(
          mapped_x, horizontal_bounds.minimum, horizontal_bounds.maximum);
      const size_t x0 = static_cast<size_t>(std::floor(sample_x));
      const size_t x1 = static_cast<size_t>(std::ceil(sample_x));
      const double x_fraction = sample_x - static_cast<double>(x0);
      const size_t top_left = PixelOffset(x0, y0, source_width_size);
      const size_t top_right = PixelOffset(x1, y0, source_width_size);
      const size_t bottom_left = PixelOffset(x0, y1, source_width_size);
      const size_t bottom_right = PixelOffset(x1, y1, source_width_size);
      const size_t output_offset = PixelOffset(
          static_cast<size_t>(destination_x) + output_x,
          static_cast<size_t>(destination_y) + output_y,
          static_cast<size_t>(destination_canvas_width));
      for (size_t channel = 0; channel < 4; ++channel) {
        const double top = static_cast<double>(source_pixels[top_left + channel]) +
            (static_cast<double>(source_pixels[top_right + channel]) -
             static_cast<double>(source_pixels[top_left + channel])) * x_fraction;
        const double bottom = static_cast<double>(source_pixels[bottom_left + channel]) +
            (static_cast<double>(source_pixels[bottom_right + channel]) -
             static_cast<double>(source_pixels[bottom_left + channel])) * x_fraction;
        (*destination)[output_offset + channel] =
            RoundedChannel(top + (bottom - top) * y_fraction);
      }
    }
  }
}

void BilinearScaleViewport(const std::vector<uint8_t>& source_pixels,
                           uint32_t source_width, uint32_t source_height,
                           const CropRect& viewport,
                           uint32_t destination_width,
                           uint32_t destination_height,
                           std::vector<uint8_t>* destination) {
  const double viewport_x = viewport.x * static_cast<double>(source_width);
  const double viewport_y = viewport.y * static_cast<double>(source_height);
  const double viewport_width =
      viewport.width * static_cast<double>(source_width);
  const double viewport_height =
      viewport.height * static_cast<double>(source_height);
  const double maximum_x = static_cast<double>(source_width) - 1.0;
  const double maximum_y = static_cast<double>(source_height) - 1.0;
  const size_t source_width_size = static_cast<size_t>(source_width);
  const size_t destination_width_size =
      static_cast<size_t>(destination_width);

  for (size_t output_y = 0;
       output_y < static_cast<size_t>(destination_height); ++output_y) {
    const double sample_y =
        viewport_y +
        (static_cast<double>(output_y) + 0.5) * viewport_height /
            static_cast<double>(destination_height) -
        0.5;
    if (sample_y < 0.0 || sample_y > maximum_y) {
      continue;
    }
    const size_t y0 = static_cast<size_t>(std::floor(sample_y));
    const size_t y1 = static_cast<size_t>(std::ceil(sample_y));
    const double y_fraction = sample_y - static_cast<double>(y0);
    for (size_t output_x = 0; output_x < destination_width_size; ++output_x) {
      const double sample_x =
          viewport_x +
          (static_cast<double>(output_x) + 0.5) * viewport_width /
              static_cast<double>(destination_width) -
          0.5;
      if (sample_x < 0.0 || sample_x > maximum_x) {
        continue;
      }
      const size_t x0 = static_cast<size_t>(std::floor(sample_x));
      const size_t x1 = static_cast<size_t>(std::ceil(sample_x));
      const double x_fraction = sample_x - static_cast<double>(x0);
      const size_t top_left = PixelOffset(x0, y0, source_width_size);
      const size_t top_right = PixelOffset(x1, y0, source_width_size);
      const size_t bottom_left = PixelOffset(x0, y1, source_width_size);
      const size_t bottom_right = PixelOffset(x1, y1, source_width_size);
      const size_t output_offset =
          PixelOffset(output_x, output_y, destination_width_size);
      for (size_t channel = 0; channel < 4; ++channel) {
        const double top =
            static_cast<double>(source_pixels[top_left + channel]) +
            (static_cast<double>(source_pixels[top_right + channel]) -
             static_cast<double>(source_pixels[top_left + channel])) *
                x_fraction;
        const double bottom =
            static_cast<double>(source_pixels[bottom_left + channel]) +
            (static_cast<double>(source_pixels[bottom_right + channel]) -
             static_cast<double>(source_pixels[bottom_left + channel])) *
                x_fraction;
        (*destination)[output_offset + channel] =
            RoundedChannel(top + (bottom - top) * y_fraction);
      }
    }
  }
}

}  // namespace

Result<RgbaFrame> TransformRgba(const RgbaFrame& source,
                                const TransformRequest& request) {
  if (request.output_width == 0 || request.output_height == 0 ||
      request.output_width % 4 != 0 || request.output_height % 4 != 0) {
    return InvalidArgument("output dimensions must be nonzero multiples of four");
  }
  if (source.width == 0 || source.height == 0) {
    return InvalidArgument("source dimensions must be nonzero");
  }
  if (!ValidRotation(request.clockwise_rotation)) {
    return InvalidArgument("clockwise rotation must be 0, 90, 180, or 270");
  }

  size_t source_bytes = 0;
  if (!PixelByteCount(source.width, source.height, &source_bytes) ||
      source.pixels.size() != source_bytes) {
    return InvalidArgument("source pixels must be tightly packed RGBA");
  }
  size_t destination_bytes = 0;
  if (!PixelByteCount(request.output_width, request.output_height,
                      &destination_bytes)) {
    return InvalidArgument("output dimensions overflow RGBA buffer size");
  }

  try {
    std::vector<uint8_t> upright_pixels(source_bytes);
    uint32_t upright_width = 0;
    uint32_t upright_height = 0;
    RotateClockwise(source, request.clockwise_rotation, &upright_pixels,
                    &upright_width, &upright_height);

    PixelRect crop{};
    const bool has_explicit_crop = request.crop.has_value();
    if (has_explicit_crop) {
      if (!ExplicitCrop(*request.crop, upright_width, upright_height, &crop)) {
        return InvalidArgument("crop must intersect the upright source frame");
      }
    } else if (request.fit == FitMode::kCover) {
      crop = CenterCoverCrop(upright_width, upright_height, request.output_width,
                             request.output_height);
    } else {
      crop = PixelRect{0.0, 0.0, static_cast<double>(upright_width),
                       static_cast<double>(upright_height)};
    }

    std::vector<uint8_t> destination(destination_bytes);
    uint32_t destination_x = 0;
    uint32_t destination_y = 0;
    uint32_t scaled_width = request.output_width;
    uint32_t scaled_height = request.output_height;
    const bool crop_extends_outside_source =
        has_explicit_crop &&
        (request.crop->x < 0.0 || request.crop->y < 0.0 ||
         request.crop->x + request.crop->width > 1.0 ||
         request.crop->y + request.crop->height > 1.0);
    if (crop_extends_outside_source) {
      WriteArgbBackground(&destination, request.background_argb);
    } else if (!has_explicit_crop && request.fit == FitMode::kContain) {
      const double scale = std::min(
          static_cast<double>(request.output_width) / crop.width,
          static_cast<double>(request.output_height) / crop.height);
      const double scaled_width_double = std::floor(crop.width * scale + 0.5);
      const double scaled_height_double = std::floor(crop.height * scale + 0.5);
      scaled_width = static_cast<uint32_t>(std::clamp(
          scaled_width_double, 1.0, static_cast<double>(request.output_width)));
      scaled_height = static_cast<uint32_t>(std::clamp(
          scaled_height_double, 1.0, static_cast<double>(request.output_height)));
      destination_x = (request.output_width - scaled_width) / 2;
      destination_y = (request.output_height - scaled_height) / 2;
      WriteArgbBackground(&destination, request.background_argb);
    }
    if (crop_extends_outside_source) {
      BilinearScaleViewport(upright_pixels, upright_width, upright_height,
                            *request.crop, request.output_width,
                            request.output_height, &destination);
    } else {
      BilinearScale(upright_pixels, upright_width, upright_height, crop,
                    destination_x, destination_y, scaled_width, scaled_height,
                    request.output_width, &destination);
    }
    return Result<RgbaFrame>{
        RgbaFrame{request.output_width, request.output_height, source.pts_100ns,
                  source.duration_100ns, std::move(destination)},
        std::nullopt};
  } catch (const std::bad_alloc&) {
    return AllocationFailure();
  }
}

}  // namespace hmw
