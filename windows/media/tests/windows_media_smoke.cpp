#include "honey_media_windows/media_converter.h"

#include "test_support.h"

HMW_TEST(smoke_converts_bundled_mov_and_gif_and_decodes_outputs) {
  const auto mov = hmw::ConvertMedia(hmw::test::MovFixtureRequest(),
                                     IgnoreProgress, NeverCancel);
  const auto gif = hmw::ConvertMedia(hmw::test::GifFixtureRequest(),
                                     IgnoreProgress, NeverCancel);
  HMW_EXPECT(mov.ok());
  HMW_EXPECT(gif.ok());
  if (!mov.ok() || !gif.ok()) {
    return;
  }
  HMW_EXPECT(hmw::test::ValidateCvidAndDecodeFirstLast(mov.value->avi).ok());
  HMW_EXPECT(hmw::test::ValidateCvidAndDecodeFirstLast(gif.value->avi).ok());
  HMW_EXPECT(hmw::MakeThumbnail({hmw::test::MovFixturePath()}, NeverCancel)
                 .ok());
  HMW_EXPECT(hmw::MakeThumbnail({hmw::test::GifFixturePath()}, NeverCancel)
                 .ok());
  HMW_EXPECT(hmw::MakePreview({hmw::test::MovFixturePath(), 12U, 160U},
                              NeverCancel)
                 .ok());
  HMW_EXPECT(hmw::MakePreview({hmw::test::GifFixturePath(), 12U, 160U},
                              NeverCancel)
                 .ok());
}
