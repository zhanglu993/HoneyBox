#include "honey_media_windows/encoder_backend.h"
#include "honey_media_windows/status.h"

#include "test_support.h"

#include <optional>

HMW_TEST(status_contract_exposes_streaming_failures) {
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kCodecUnavailable) ==
             "codec_unavailable");
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kUnsupportedFeature) ==
             "unsupported_feature");
}

HMW_TEST(encoder_backend_factory_creates_h264_backend) {
  const auto result = hmw::CreateDefaultEncoderBackendFactory()(
      hmw::EncoderFormat::kH264);
  HMW_EXPECT(result.ok());
  HMW_EXPECT(result.value.has_value());
  if (result.value) {
    HMW_EXPECT(*result.value != nullptr);
  }
}

HMW_TEST(status_contract_exposes_ok) {
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kOk) == "ok");
}

HMW_TEST(encoder_backend_factory_reports_jpeg_unavailable) {
  const auto result = hmw::CreateDefaultEncoderBackendFactory()(
      hmw::EncoderFormat::kJpeg);
  HMW_EXPECT(!result.ok());
  HMW_EXPECT(!result.value.has_value());
  HMW_EXPECT(result.error.has_value());
  HMW_EXPECT(result.error->status == hmw::Status::kCodecUnavailable);
  HMW_EXPECT(hmw::StatusCode(result.error->status) == "codec_unavailable");
}

HMW_TEST(encoder_backend_factory_reports_msv1_unavailable) {
  const auto result = hmw::CreateDefaultEncoderBackendFactory()(
      hmw::EncoderFormat::kMsv1);
  HMW_EXPECT(!result.ok());
  HMW_EXPECT(!result.value.has_value());
  HMW_EXPECT(result.error.has_value());
  HMW_EXPECT(result.error->status == hmw::Status::kCodecUnavailable);
  HMW_EXPECT(hmw::StatusCode(result.error->status) == "codec_unavailable");
}

HMW_TEST(result_ok_tracks_value_presence_for_every_value_error_combination) {
  hmw::Result<int> successful{42, std::nullopt};
  HMW_EXPECT(successful.ok());
  HMW_EXPECT(successful.value.has_value());
  HMW_EXPECT(!successful.error.has_value());

  hmw::Result<int> failed{
      std::nullopt,
      std::optional<hmw::Error>{
          hmw::Error{hmw::Status::kDecodeFailed, "decode failed"}}};
  HMW_EXPECT(!failed.ok());
  HMW_EXPECT(!failed.value.has_value());
  HMW_EXPECT(failed.error.has_value());
  HMW_EXPECT(failed.error->status == hmw::Status::kDecodeFailed);
  HMW_EXPECT(failed.error->message == "decode failed");

  hmw::Result<int> empty{};
  HMW_EXPECT(!empty.ok());
  HMW_EXPECT(!empty.value.has_value());
  HMW_EXPECT(!empty.error.has_value());

  hmw::Result<int> value_and_error{
      7,
      std::optional<hmw::Error>{
          hmw::Error{hmw::Status::kBusy, "still carrying a value"}}};
  HMW_EXPECT(value_and_error.ok());
  HMW_EXPECT(value_and_error.value.has_value());
  HMW_EXPECT(value_and_error.error.has_value());
  HMW_EXPECT(value_and_error.error->status == hmw::Status::kBusy);
}

HMW_TEST(outcome_ok_tracks_error_absence) {
  hmw::Outcome successful{};
  HMW_EXPECT(successful.ok());
  HMW_EXPECT(!successful.error.has_value());

  hmw::Outcome failed{std::optional<hmw::Error>{
      hmw::Error{hmw::Status::kIoError, "write failed"}}};
  HMW_EXPECT(!failed.ok());
  HMW_EXPECT(failed.error.has_value());
  HMW_EXPECT(failed.error->status == hmw::Status::kIoError);
  HMW_EXPECT(failed.error->message == "write failed");
}
