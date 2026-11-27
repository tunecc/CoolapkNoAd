# 酷安升级后如何重新适配

酷安大版本更新后，广告 SDK 的类名/方法名可能变化，插件会失效。按下面的顺序排查和修改。

## 0. 先确认是插件失效，还是服务端本来没下发

1. 打开酷安数据容器下的 `tmp/CAC_install_report.txt`（每次启动覆盖写入）：
   - 全是 `hooked` 但仍有广告 → 链路变了，去 §2 找新入口。
   - 有 `MISS class` / `MISS method` → 名字变了，按 §2 找新名字替换。
   - 没有报告文件 → 插件没注入：检查包是否安装、酷安进程里有没有 `KuAnNoAds.dylib`。
2. 开屏广告是否真的展示，可以看酷安自己的偏好键 `splashLastShowTime`（每次展示开屏都会刷新）：

   ```bash
   # 设备上（越狱环境）
   plutil -p /var/mobile/Containers/Data/Application/<容器UUID>/Library/Preferences/com.coolapk.app.plist | grep -i splash
   ```

   相关键：`splashAdTypeGroup`（如 `GM_SPLASH | <appid> | <slot>`）、`splashTTAppID`、`splashExpires`、`splashLastShowTime`。

## 1. 拿到新版二进制

- 用已解密的 IPA：`unzip 酷安_x.y.z.ipa`，目标为 `Payload/CoolMarket.app/CoolMarket`；
  广告 SDK 在 `Payload/CoolMarket.app/Frameworks/`（AnyThink/GDT/Smartdigimkt/Tanx 等）。
- 静态分析工具任选：Hopper / IDA / `otool` / `nm`。常用命令：

  ```bash
  otool -L Payload/CoolMarket.app/CoolMarket | head          # 链接了哪些 SDK
  otool -oV Payload/CoolMarket.app/CoolMarket | less         # ObjC 类与方法元数据
  strings -a Payload/CoolMarket.app/CoolMarket | grep -i splash
  ```

## 2. 定位新入口

| 广告类型 | 已知入口（16.7.3） | 变化时怎么找 |
| --- | --- | --- |
| 开屏（聚合） | `ABUSplashAdLoader -Pods_NODuan:mediaSlotConfig:` / `-NULL_ModBu_y:withMediaSlotConfig:` / `-Need_ThisIs:mediaSlotConfig:params:` | 在 `ABUSplashAdLoader` 的方法列表里找“参数个数相同、返回 BOOL”的方法；名字常被改写为无意义字符串 |
| 开屏（穿山甲） | `CSJADLoadSplashContext -splashFinalType`、`CSJSplashAdLoader` | 搜 `Splash` 类名前缀 `CSJ` |
| 开屏（自营） | `TXAdSplashManager -getSplashAdsWithAdsDataBlock:renderMode:`、`TXAdSplashModule`、`TXAdSplashCacheService` | 搜 `TXAdSplash` |
| 开屏（渲染） | `SplashAdvertisementViewController` 的 `viewDidLoad/viewWillAppear:/viewDidAppear:` | 搜 `SplashAdvertisement` |
| 信息流/详情页 | `GMNativeAdsManager -loadAdDataWithCount:`、`-loadAdDataWithMediaSlotConfigIDs:sign:`、`CSJNativeAdsManager -loadAdDataWithCount:` | 搜 `NativeAdsManager`，优先掐 `load…` 方法 |

**优先拦“加载”**：把负责向服务器拉广告的 `load…` 改成空实现（不调用原实现），广告不会到达渲染层，比拦渲染稳定、不会留布局空洞。

## 3. 用调试包在设备上验证

```bash
cd tweak
./build.sh debug        # 每次命中写日志（-DCAC_DEBUG）
./build.sh probe        # 开屏诊断：观测窗口/开屏 VC 层级（-DCAC_PROBE）
./build.sh feedprobe    # 信息流诊断：只观测 6 个关键入口（-DCAC_FEEDPROBE2）
```

安装 deb 后冷启动酷安，然后：

```bash
# 看安装报告（哪条 hook 没装）
tail -40 /var/mobile/Containers/Data/Application/<容器UUID>/tmp/CAC_install_report.txt
# 看命中（调试包才有）
grep HIT /var/mobile/Containers/Data/Application/<容器UUID>/tmp/CAC.log
```

## 4. 改 hook

`Tweak.xm` 按链路分组（`CACInstallSplashDecision` / `CACInstallSplashLoader` / `CACBlockFeedLoad` …），新增一条就是一行：

```c
CACHookReturnZero("CSJADLoadSplashContext", "isAdValid", "SPLASH.CSJ.isAdValid");   // 返回 0
CACHookReturnNil("SomeClass", "someObjectMethod", "TAG");                            // 返回 nil
CACHookDropArg("GMNativeAdsManager", "setAdslot:", "FEED.GM.setAdslot");             // 丢弃参数
CACHookBlockArg("TXAdSplashManager", "getSplashAdsWithAdsDataBlock:renderMode:", 1, "SPLASH.TX.getSplashAds");
CACHookObserve("Cls", "sel", "TAG");                                                 // 只观测
```

注意事项：

- block 的参数签名必须与真实方法一致（`void(id self, long n)`、`void(id self, id a, id b)`…），签名错会直接崩。
- 拿不准时先用 `CACHookObserve` 只观测，确认命中后再改成拦截。
- **不要一次挂几千个方法**（尤其不要挂 `NSBundle.mainBundle`、`gameapi_UIKit` 这类）——实测会让酷安立即 `EXC_BAD_ACCESS`。探针一次挂 ≤10 个入口。
- 类/方法先判断存在性（现有 `CACHook*` 内部已处理），缺了只记 `MISS`，不崩。

## 5. 验收

1. 装包后冷启动成功，无崩溃（看 `get_crash_logs` 里的 `CoolMarket-*.ips`）。
2. 冷启动 5 次：无开屏广告（`splashLastShowTime` 不变）。
3. 信息流下滑 ≥3 屏：无「广告」卡片。
4. 打开 ≥3 个帖子、评论区下滑 ≥2 屏：无广告。
5. 首页/帖子/评论/搜索/分享可用。

## 6. 发版

```bash
# 改 control 里的 Version，然后
./scripts/build_packages.sh roothide
# 产物在 out/，tag 与 GitHub Release 同步
git tag vX.Y.Z && git push --tags
```

版本号（Debian 规则）：发布版 `1.0.0`；预发布用 `~`，如 `1.1~beta1`（保证排在 `1.1` 之前）。

## 7. 已知坑

| 现象 | 原因 / 处理 |
| --- | --- |
| Frida 看不到前台界面 | 酷安启动早期会换进程，spawn/attach 的进程不是真正显示的进程；改用插件自身日志 |
| 批量 hook 后闪退 | hook 数量过多或挂到系统类；缩小到定向入口 |
| 截图全黑 | 设备锁屏；先唤醒（`wake_and_home`）再操作 |
| 改过 App 偏好后行为异常 | 记得备份并还原 `Library/Preferences/com.coolapk.app.plist` |
| 重装酷安后路径变了 | 数据容器 UUID 会变，重新查 `Library/Preferences` 所在目录 |
