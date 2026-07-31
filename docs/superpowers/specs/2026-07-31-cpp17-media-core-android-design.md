# C++17 eBadge 媒体核心 Android 迁移设计

**日期：** 2026-07-31
**状态：** 已完成方案讨论，待书面规格复核
**目标分支：** `codex/cpp17-media-core-android`

## 1. 背景

HoneyBox 当前由 Flutter/Dart 承担页面、状态、资源打包、缓存、BLE 和
L1/L2 协议；Android Kotlin 原生层承担视频/GIF 解码、裁剪缩放和设备媒体
编码。设备专用媒体核心目前直接实现在 Android 工程中：

- `CinepakEncoder.kt`：Cinepak/CVID 编码；
- `CinepakDecoder.kt`：Cinepak/CVID 解码及 AVI 解析；
- `CvidAviMuxer.kt`：CVID AVI 封装；
- `SoftwareCodec.kt`：MSV1 编解码、JPEG 系统编码包装及相关 AVI 封装。

这套实现可以在 Android 上工作，但代码与 Android 工程目录绑定，无法直接
供 iOS、Windows、WebAssembly、uni-app 或原生应用复用。

长期目标是形成一个不绑定 Flutter、Kotlin、Swift 或 uni-app 的媒体核心库。
第一版先用 C++17 替换 Android 生产路径中的 Kotlin 软件编解码核心，同时在
Windows 上构建并运行同一核心的一致性测试，以验证可移植性。其他产品逻辑和
其他平台的完整功能暂不修改。

## 2. 第一版目标

1. 建立独立、可移植的 C++17 媒体核心。
2. 对外提供稳定的 C99 ABI，不向调用方暴露 C++ ABI。
3. 将 Cinepak 编码/解码、MSV1 编码/解码和 AVI 封装/解析迁入 C++。
4. Android 通过 JNI 使用 C++ 实现，现有 Flutter 接口和产品行为保持不变。
5. Windows 使用 MSVC/CMake 构建同一核心，并运行原生一致性与健壮性测试。
6. 以现有 Kotlin 实现生成的固定数据作为迁移基准，确认格式兼容。
7. 为后续 iOS、完整 Windows、WASM 和其他前端框架保留稳定边界。

## 3. 非目标

第一版明确不包含：

- 修改 Flutter 页面、Riverpod 状态、缓存、资源包、BLE 或 L1/L2 协议；
- 修改 `ebadge/converter` 的方法名、参数或返回结构；
- 将 Android 视频/GIF 解码迁入 C++；
- 替换 Android `MediaMetadataRetriever`、`android.graphics.Movie`、
  `Bitmap` 或 `Canvas`；
- 替换 JPEG 的 Android `Bitmap.compress` 实现；
- 替换 H.264 的 Android `MediaCodec` 实现；
- 为 Windows 增加 MP4/MOV/GIF 系统解码、Flutter MethodChannel 或视频页面；
- 实现 iOS、macOS、Linux、WASM 或 uni-app 绑定；
- 引入 FFmpeg 或其他第三方媒体编解码库；
- 第一版进行 NEON、SSE 或 WASM SIMD 优化。

## 4. 总体架构

```text
Flutter / Riverpod / BLE / L1 / L2
                │
                │ 现有 MethodChannel，接口不变
                ▼
Android MainActivity / VideoConverter / CameraEncoder
                │
                │ Kotlin 薄包装 + JNI
                ▼
        libebadge_media.so
                │
                ▼
        C ABI + C++17 核心
        ├── Cinepak 编码/解码
        ├── MSV1 编码/解码
        ├── CVID AVI 封装/解析
        └── MSV1/JPEG AVI 封装
```

Windows 第一版不接 Flutter，而是：

```text
media_core_tests.exe
        │
        ▼
同一个 ebadge_media.h / C++17 核心
```

Android 是功能接入和设备行为验证平台；Windows 是第二编译器、第二运行环境和
公共核心一致性验证平台。

## 5. 模块与目录

```text
media_core/
├── CMakeLists.txt
├── include/
│   └── ebadge_media.h
├── src/
│   ├── cinepak_encoder.cpp
│   ├── cinepak_decoder.cpp
│   ├── msv1_codec.cpp
│   ├── avi_muxer.cpp
│   ├── avi_parser.cpp
│   └── ebadge_media_c_api.cpp
└── tests/
    ├── CMakeLists.txt
    ├── media_core_tests.cpp
    └── fixtures/

android/app/src/main/cpp/
├── CMakeLists.txt
└── ebadge_media_jni.cpp

android/app/src/main/kotlin/com/honeygui/honeybox/
└── NativeMediaCodec.kt
```

`media_core` 不得包含 JNI、Android、Flutter、Win32、文件选择或 UI 头文件。
平台绑定只能依赖公共 C 头文件。

## 6. 公共 C ABI

公共接口使用固定宽度整数、opaque handle 和显式内存所有权。内部可以使用
`std::vector`、RAII 和 C++ 类，但不得穿过 ABI 边界。

首版接口覆盖：

- 查询 ABI 版本；
- 创建/销毁 Cinepak 编码会话；
- 输入一帧 RGBA8888；
- 强制关键帧；
- 获得编码帧；
- 解析和解码 Cinepak AVI；
- 编码/解码 MSV1 帧；
- 将编码帧封装为 AVI；
- 释放由库分配的输出 buffer；
- 返回稳定错误码和可诊断错误文本。

接口约束：

- 所有公开结构体包含 `struct_size`；
- 所有尺寸和长度在进入核心前做溢出检查；
- 输入 buffer 由调用者持有，调用期间保持有效；
- 输出 buffer 由核心分配，只能通过核心提供的释放函数释放；
- C++ 异常不得越过 C ABI 或 JNI；
- 失败时返回错误码，不返回部分有效对象；
- 帧编码会话不承诺线程安全，一个会话只能由一个线程使用；
- 不依赖宿主字节序，AVI 和 codec 字段显式读写大小端；
- 相同输入、参数和调用顺序必须产生确定性输出。

## 7. Android 集成

Android 继续负责：

- MP4/MOV 元数据和视频帧解码；
- GIF 检测、帧解码和透明背景合成；
- Bitmap/Canvas 裁剪、旋转、缩放和 RGBA 生成；
- 转换采样时间、FPS、最大帧数、进度和取消；
- Flutter MethodChannel 和 EventChannel；
- JPEG 系统编码和 H.264 系统编码；
- 文件缓存、资源打包和 BLE/WiFi 发送。

`NativeMediaCodec.kt` 提供 Kotlin 友好的薄包装，隐藏 native handle 和 JNI
细节。`VideoConverter.kt` 与 `CameraEncoder.kt` 只把已经生成的 RGBA
`ByteArray` 交给该包装层，不直接操作 C 指针。

JNI 负责：

- 校验 Java/Kotlin 参数；
- 将 `ByteArray` 映射或复制到 native 输入；
- 调用公共 C ABI；
- 把输出转换回 `ByteArray`；
- 将 C 错误码转换为稳定的 Kotlin 异常；
- 使用 `try/finally` 或 `AutoCloseable` 保证 native handle 释放。

转换取消仍由当前 Kotlin 循环检查 `AtomicBoolean`。首版不在长时间运行的单帧
编码内部增加跨语言取消回调，避免扩大 ABI。

## 8. Windows 验收

Windows 第一版只构建公共核心和原生测试程序，不接入现有 Flutter Windows
Runner。

Windows 验收要求：

1. MSVC x64 Debug 和 Release 均可构建；
2. 核心在不定义 Android/JNI 宏的情况下完整编译；
3. 编译器警告作为错误处理；
4. 固定 RGBA 输入在 Windows 和 Android C++ 上得到相同输出；
5. 与迁移前 Kotlin golden 输出比较；
6. 解析截断、畸形和溢出输入时返回错误而不是崩溃；
7. 条件允许时启用 AddressSanitizer 运行原生测试；
8. 重复运行相同用例时输出保持确定。

Windows 测试通过只代表公共媒体核心可移植，不代表 Windows App 已具备完整
视频转换、原视频预览或缓存预览功能。

## 9. 迁移策略

迁移采用参考实现和新实现并行验证，避免一次性替换后无法定位格式差异。

### 阶段 A：固定参考行为

- 为 Kotlin Cinepak、MSV1 和 AVI 生成确定性测试输入；
- 保存必要的 golden bytes、hash 和解析结果；
- 覆盖关键帧、差分帧、skip block、奇数长度 padding 和多帧 AVI；
- 明确允许的有损图像误差和必须逐字节一致的容器字段。

### 阶段 B：实现可移植核心

- 先完成无状态字节序、AVI 和单帧 codec 基元；
- 再完成带上一帧重建状态的编码/解码会话；
- 在 Windows 原生测试中先跑通；
- 同时保持 C ABI 无 Android 依赖。

### 阶段 C：Android JNI 并行接入

- 新增 JNI 和 Kotlin 薄包装；
- Debug/测试路径可同时运行 Kotlin 和 C++，比较输出；
- 生产路径在一致性验证完成前仍使用 Kotlin；
- 差异必须定位到具体帧、chunk 或字段。

### 阶段 D：切换生产路径

- Cinepak、MSV1 和 AVI 调用切换到 C++；
- JPEG、H.264 和 Android 解码保持原实现；
- 移除生产代码对旧 Kotlin codec 类的依赖；
- golden fixtures 和跨平台一致性测试继续保留。

## 10. 测试设计

### Cinepak

- 黑白、纯色、渐变、棋盘格和固定伪随机 RGBA；
- 240×240、360×360、480×480；
- quality、refine、strips、skipThresh、keyint 边界；
- 首帧关键帧；
- 相同帧、微小变化和大面积变化的 inter frame；
- 强制关键帧和周期关键帧；
- 编码后由 Kotlin/C++ 解码器重建并比较。

### MSV1

- I-frame 和带上一帧的 P-frame；
- 单色块、双色块和 skip block；
- skip threshold 边界；
- RGB555 特殊颜色和 skip code 冲突保护；
- AVI 封装与解码回环。

### AVI

- RIFF、LIST、strh、strf、movi、idx1；
- FPS、宽、高、总帧数和最大帧大小；
- 奇数帧长度 padding；
- frame offset 和 size；
- 空帧列表、过大输出和整数溢出；
- 截断 chunk、错误 size、缺失 movi/idx1。

### 集成

- 现有 Flutter 测试；
- Android debug/release 构建；
- JNI 加载和 ABI 打包检查；
- Android 转换固定素材；
- 缓存视频解码预览；
- MSV1/JPEG/H.264 相机路径回归；
- 有设备条件时发送并播放 Cinepak AVI 和 MSV1 流。

## 11. 验收标准

第一版完成必须同时满足：

- Flutter `ebadge/converter` 对外合同不变；
- Android 的 Cinepak、MSV1 和 AVI 生产路径已使用 C++；
- 旧 Kotlin codec 不再参与生产编码/解码；
- JPEG 和 H.264 行为没有被迁移任务改变；
- Windows MSVC 原生测试通过；
- Android/Windows C++ 对固定输入输出一致；
- 必须保持的 Kotlin golden 字段逐字节一致；
- 有损编解码重建误差不高于 Kotlin 参考；
- 现有 Flutter 测试通过；
- Android 构建通过；
- 没有已知 native handle 泄漏、越界或 double-free；
- 文档明确区分代码验证、Android 构建和 eBadge 真机验证。

若缺少 Android SDK、NDK、MSVC、设备或签名环境，对应项必须标记为未验证，
不能用其他平台的通过结果替代。

## 12. 风险与控制

### 格式行为漂移

以 Kotlin golden 和设备解析结果作为迁移门槛；生产切换前保留双实现对比。

### JNI 复制和内存峰值

首版保持接口简单并记录性能基线；避免一次跨 JNI 传递全部原始视频帧，采用
逐帧编码会话。

### C++ 内存安全

内部使用 RAII、边界检查和 checked arithmetic；Windows 原生测试启用可用的
sanitizer；解析器对外部长度不做信任。

### C++ ABI 锁定

仅公开 C ABI，结构体带版本和大小；不导出 STL、异常或 C++ 类。

### 范围膨胀

第一版不实现 Windows 产品功能、iOS、WASM、SIMD 或 FFmpeg。Windows 只作为
公共核心构建和一致性验收平台。

### 源码来源与许可证

迁移时保留现有实现的来源说明并单独核查授权；语言迁移不改变原始源码的许可
义务。

## 13. 后续演进

第一版稳定后，按独立项目逐步增加：

1. Windows Media Foundation 解码与 Flutter Windows 绑定；
2. iOS AVFoundation 解码和 XCFramework；
3. Emscripten/WASM 构建和浏览器视频适配；
4. uni-app、Flutter FFI 和原生 SDK 包装；
5. 基于性能数据增加 NEON、SSE 或 WASM SIMD。

这些平台复用同一 C ABI 和 C++ 核心，不要求保留 Flutter 或任何特定 UI 框架。
