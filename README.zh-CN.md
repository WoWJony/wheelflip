# WheelFlip

**鼠标滚轮反转，触控板保持自然滚动；每个应用可以设置不同方向。**

用 SwiftUI / AppKit 编写的 macOS 菜单栏小工具。无需账号或联网，没有广告和统计服务。

[English](README.md) · [MIT 许可证](LICENSE) · [参与贡献](CONTRIBUTING.md)

<p align="center">
  <img src="docs/assets/panel-zh.png" width="380" alt="WheelFlip 中文菜单栏面板">
</p>

## 功能

- 只反转离散滚轮事件，连续滚动事件原样通过。
- 每个应用可设为「跟随默认 / 反转 / 保持原方向」。
- 按实际接收滚动事件的窗口所属应用选择规则，包括鼠标下方的非前台窗口。
- 一键暂停全部，保留已保存规则。
- 菜单栏常驻，无 Dock 图标，提供中英文界面。
- 设置保存在本机应用容器中，不上传应用清单或滚动记录。详见[隐私说明](PRIVACY.md)。

截图使用真实界面和演示数据生成。

## 从源码构建

需要 macOS 14+、包含 macOS 14 或更新 SDK 的 Xcode，以及 XcodeGen。目前没有经过 Apple 公证的二进制下载。

```sh
brew install xcodegen
git clone https://github.com/WoWJony/wheelflip.git
cd wheelflip/app
xcodegen generate
xcodebuild -project WheelFlip.xcodeproj -scheme WheelFlip \
  -configuration Release -derivedDataPath build/local build
codesign -f -s - --entitlements WheelFlip/WheelFlip.entitlements \
  --identifier com.jonywu.WheelFlip \
  build/local/Build/Products/Release/WheelFlip.app
open build/local/Build/Products/Release/WheelFlip.app
```

构建使用本地临时签名。替换应用前先退出旧副本；重新构建可能使辅助功能授权失效。开发时请使用独立构建目录。

## 首次使用

1. 如果希望触控板保持自然滚动、鼠标采用传统方向，请保持系统「自然滚动」开启。
2. 打开「系统设置 → 隐私与安全性 → 辅助功能」。
3. 添加刚构建的 `WheelFlip.app` 并开启开关。应用面板可在 Finder 中定位正在运行的副本。
4. 在 WheelFlip 中选择「重新打开并检查」。
5. 设置默认方向，再添加各应用的例外规则。

服务启动后会注册登录自启；「暂停全部」保留登录项，只在本次会话生效。**「退出 WheelFlip」会停止服务并注销登录自启。** 也可以在系统设置中管理登录项。

## 使用边界

- 只处理方向，不提供平滑滚动、速度或指针加速度设置。
- 横向和纵向滚轮一起反转。
- 触控板和 Magic Mouse 通常产生连续事件，不会被反转；某些鼠标驱动产生的连续事件也会原样通过。
- 无法识别应用时采用默认规则；沙盒未能发现的应用可以手动添加。
- 同时运行多个滚动修改工具可能造成双重反转。
- 重建后若权限失效，请移除旧辅助功能条目、添加新副本并重新打开。

欢迎提交问题、翻译和改进；测试步骤见[贡献指南](CONTRIBUTING.md)。如果这个小工具帮到了你，欢迎点个 Star，让更多人找到它。

作者：[Jony Wu](https://github.com/WoWJony)。使用 [MIT 许可证](LICENSE)。
