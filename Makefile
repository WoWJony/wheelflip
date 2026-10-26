PREFIX      := $(HOME)/.local
# Export paths as data. Never interpolate them into shell program text.
export BIN         := $(PREFIX)/bin/wheelflip
export PLIST_LABEL := com.jonywu.wheelflip
export PLIST       := $(HOME)/Library/LaunchAgents/$(PLIST_LABEL).plist

build:
	mkdir -p build
	swiftc -O Sources/main.swift -o build/wheelflip
	# swiftc 默认只做 linker-signed 临时签名,TCC 授权认不住;重签成完整 ad-hoc
	codesign -f -s - --identifier com.jonywu.wheelflip build/wheelflip

# 安装二进制 + LaunchAgent 并立即启动
install: build
	mkdir -p "$$(dirname "$$BIN")" "$$(dirname "$$PLIST")"
	-launchctl bootout "gui/$$(id -u)/$$PLIST_LABEL" 2>/dev/null
	cp build/wheelflip "$$BIN"
	/usr/bin/plutil -replace ProgramArguments -array -o "$$PLIST" "launchd/$$PLIST_LABEL.plist"
	/usr/bin/plutil -insert ProgramArguments.0 -string "$$BIN" "$$PLIST"
	launchctl bootstrap "gui/$$(id -u)" "$$PLIST"
	@echo "已安装并启动。首次运行需在 系统设置→隐私与安全性→辅助功能 里允许 wheelflip"

uninstall:
	-launchctl bootout "gui/$$(id -u)/$$PLIST_LABEL" 2>/dev/null
	rm -f -- "$$PLIST" "$$BIN"
	@echo "已卸载(辅助功能权限列表里的残留条目可手动移除)"

status:
	launchctl print "gui/$$(id -u)/$$PLIST_LABEL" | head -20

# 端到端自测: 发合成滚动事件,在 wheelflip 下游观察 delta 是否正确翻转
test:
	uv run --with pyobjc-framework-Quartz python test/selftest.py

# 两身份路由回归(§9.2):需要 exactly one active flipping instance 已退出,
# 脚本自行拉起/退出 headless 引擎;真实鼠标命中测试用 test 目标。
route-test:
	uv run --with pyobjc-framework-Quartz python test/route_test.py

.PHONY: build install uninstall status test route-test
