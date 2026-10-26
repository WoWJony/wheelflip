# Share WheelFlip

Copy below the relevant **Title** and **Body** into your own post. These are launch drafts, not records of posts already published. No personal desktop recording or private app data is included in the media.

## Media

| Asset | English | 简体中文 |
| --- | --- | --- |
| 15-second MP4, 1280 × 720 | [Download](https://github.com/WoWJony/wheelflip/releases/download/v1.0.0/wheelflip-demo-en.mp4) | [下载](https://github.com/WoWJony/wheelflip/releases/download/v1.0.0/wheelflip-demo-zh.mp4) |
| Animated README demo | [GIF](assets/demo-en.gif) | [GIF](assets/demo-zh.gif) |
| Share image, 1280 × 640 | [PNG](assets/social-preview-en.png) | [PNG](assets/social-preview-zh.png) |

The tour is an **illustration of behavior**, paired with real app UI rendered from sample data. Arrow directions come from WheelFlip's actual `FlipPolicy` and `ScrollFlip` functions. It is not a recording of physical mouse or trackpad input. The current release is ad-hoc signed and has not been notarized by Apple.

## 中文首发帖 · V2EX 分享创造

**标题**

开源了一个 Mac 小工具：鼠标滚轮反转，触控板不变，还能按应用设置方向

**正文**

分享一下刚开源的 WheelFlip，一个 macOS 菜单栏小工具。

它处理的是一个很具体的使用习惯：鼠标滚轮想用传统方向，触控板想保留自然滚动。有些应用又希望采用不同的滚轮方向。

WheelFlip 可以反转普通鼠标滚轮，同时让触控板的连续滚动事件保持原样；每个应用还能选择「跟随默认 / 反转 / 保持原方向」。规则会跟随实际接收滚动事件的应用，包括鼠标下方的非前台窗口。

几个使用细节：

- macOS 14+，Apple 芯片和 Intel 都有通用安装包，不需要 Xcode。
- 原生 SwiftUI / AppKit 菜单栏界面，中英文可用。
- 无账号、无广告、无使用统计，设置保存在本机。
- MIT 开源，也保留了测试和构建方法。

仓库和 15 秒功能示意：https://github.com/WoWJony/wheelflip

安装包：https://github.com/WoWJony/wheelflip/releases/latest

首版还没有 Apple 公证，首次打开可能需要在系统设置中确认，并手动打开辅助功能权限。README 写了逐步指引，也放了一段可以复制给 Claude Code、Codex 等本机 Agent 的提示词，让它下载、校验并打开相应授权页面。

它只处理方向，不做平滑滚动、速度或鼠标加速度调整。某些驱动会把鼠标事件变成连续事件，这类事件也会原样通过。

欢迎试用；如果遇到方向不对、应用规则没有生效或安装卡住，告诉我 macOS 版本、鼠标型号和复现步骤就很有帮助。

## English launch · Show HN

**Title**

Show HN: WheelFlip – per-app mouse wheel direction for macOS

**Body**

I’ve open-sourced WheelFlip, a small macOS menu bar app for people who prefer traditional mouse-wheel direction while keeping natural trackpad scrolling.

Each app can reverse the wheel, keep its direction, or inherit the default. The rule follows the app receiving the scroll event, including an unfocused window under the pointer.

It uses a scroll-wheel-only Core Graphics event tap. Discrete events can be reversed; continuous events pass through. The UI is native SwiftUI/AppKit, settings stay local, and there are no accounts or analytics. The code is MIT-licensed.

The release is a universal binary for macOS 14+, so trying it does not require Xcode. It is currently ad-hoc signed, not Apple-notarized, and needs Accessibility permission. The README includes manual setup steps and a copyable prompt for a local coding agent to handle the download and guide authorization.

It adjusts direction only: no smoothing, speed, or pointer acceleration changes. Mouse drivers that produce continuous events can bypass reversal.

Code and a 15-second illustrated tour: https://github.com/WoWJony/wheelflip

Downloads: https://github.com/WoWJony/wheelflip/releases/latest

I’d appreciate reports about installation friction, mouse-driver behavior, and apps where target detection falls back to the default.

## Short posts

**中文**

开源了 WheelFlip：Mac 鼠标滚轮反转，触控板保持自然滚动，还能按应用设方向。免费、MIT、无需账号，支持 macOS 14+ 和两种芯片。安装包和 Agent 安装向导已备好；首版尚未公证，需要系统确认与辅助功能授权。欢迎试用反馈：
https://github.com/WoWJony/wheelflip

**English**

WheelFlip: per-app mouse wheel direction for Mac. Trackpad scrolling stays natural.
MIT · macOS 14+ · Apple silicon + Intel.
First release is not notarized; guided setup included.
https://github.com/WoWJony/wheelflip

## Publishing and feedback

For a Chinese first post, [V2EX 分享创造](https://www.v2ex.com/go/create) is a place for sharing your work. For an English submission, read the [Show HN guidelines](https://news.ycombinator.com/showhn.html); be available to answer questions, offer a usable project, and do not ask people to vote for it.

Use one clear clip or cover image, explain the specific problem, and link the repository and release. Keep the signing limitation visible. Publish follow-ups when there is a meaningful fix or improvement.

Maintainers can use **Insights → Traffic** to review the past 14 days of repository visits and referring sites. Release asset download counts include repeat downloads and maintainer checks, so they are not a count of active users. Compare traffic with concrete installation reports and useful feedback before deciding where to spend more effort. [GitHub traffic documentation](https://docs.github.com/en/repositories/viewing-activity-and-data-for-your-repository/viewing-traffic-to-a-repository)

To regenerate the illustrations on macOS, run `./scripts/render-promo.sh` with Swift and ffmpeg installed. It writes to ignored `output/promo/`; review the output before copying GIFs and covers into `docs/assets/`. The renderer uses fixture screenshots and pure rule functions, without creating an event tap or reading live settings.
