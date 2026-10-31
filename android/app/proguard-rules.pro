# Optional classes referenced by the bundled AMap SDK.
-dontwarn com.amap.ams.gnss.GnssSoftLocator
-dontwarn net.jafama.FastMath

# Bundled Realtek SDK contains optional SPP and USB transports; this app uses
# GattDfuAdapter (BLE) and does not ship the separate optional transports.
-dontwarn com.realsil.sdk.bbpro.core.**
-dontwarn com.realsil.sdk.core.usb.**

# AMap SDKs use reflection and JNI internally。三个包缺一不可：
#   com.amap.**     对外 API 与地图/定位/搜索实现（jar 内 3038 个类）
#   com.autonavi.** 地图内核与导航核心（668 个类）。native 层用 JNI 反射
#                   查找这些类，被混淆后会抛
#                   ClassNotFoundException: com.autonavi.base.amap.mapcore.ClassTools
#                   以及 UnsatisfiedLinkError: AMapNaviLogger.getTreadId()
#   com.alibaba.**  阿里云语音合成（23 个类），setUseInnerVoice(true) 时
#                   由高德内部反射加载，对应 libnui.so 等三个 so
-keep class com.amap.** { *; }
-keep interface com.amap.** { *; }
-keep class com.autonavi.** { *; }
-keep interface com.autonavi.** { *; }
-keep class com.alibaba.** { *; }
-keep interface com.alibaba.** { *; }

# 上述包内的类由 native/反射调用，不能因“看起来没被引用”而被裁剪。
-keepclassmembers class com.amap.** { *; }
-keepclassmembers class com.autonavi.** { *; }
-keepclassmembers class com.alibaba.** { *; }

# Keep native method names and the Kotlin JNI bridge used by navi_jpeg.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
-keep class com.example.map1.navi.TurboJpegEncoder { *; }
