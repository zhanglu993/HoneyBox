#include "honey_media_windows/status.h"

#include "test_support.h"

HMW_TEST(camera_status_codes_are_stable) {
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kPermissionDenied) ==
             "permission_denied");
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kDeviceUnavailable) ==
             "device_unavailable");
  HMW_EXPECT(hmw::StatusCode(hmw::Status::kDeviceLost) == "device_lost");
}
