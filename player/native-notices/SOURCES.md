# Native playback components

The player dynamically loads media_kit's unmodified native libmpv/FFmpeg builds. The Flutter dependency licenses are in the generated NOTICES asset and the app's Licenses page.

- Windows: media_kit_libs_windows_video 1.0.11; upstream binary archive `mpv-dev-x86_64-20230924-git-652a1dd.7z` from https://github.com/media-kit/libmpv-win32-video-build/releases/tag/2023-09-24 . Build recipes and source dependency references: https://github.com/media-kit/libmpv-win32-video-build . libmpv source: https://github.com/mpv-player/mpv/tree/652a1dd ; FFmpeg source revision in the build recipe: https://github.com/FFmpeg/FFmpeg/tree/ea3d24bbe3c58b171e55fe2151fc7ffaca3ab3d2 . This build disables GPL components and uses LGPL-compatible configurations. Windows ANGLE binaries are supplied by the same Flutter package, from https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/tag/v1.0.1 .
- Android: media_kit_libs_android_video 1.3.8; native JARs from https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.7 . Source and recipes: https://github.com/media-kit/libmpv-android-video-build .

Native files are unmodified. Their corresponding source, dependency versions, build flags and notices are maintained in those upstream projects. LGPL license texts are included here; LGPL 3 incorporates GPL 3 terms, also included. The app sources and pinned dependency versions are present in the surrounding project. Keep native library licenses and source references with copies of this personal build.
