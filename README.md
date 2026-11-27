# 酷安 NoAd

越狱设备上的酷安（`com.coolapk.app`）去广告 tweak：**开屏广告**、**帖子/信息流广告**、**评论区/详情页广告**。

- 适配版本：酷安 **16.7.3（build 2611121）**
- 包标识：`com.tune.coolapk.noads`（作者 Tune）
- 已实测产物线：**roothide**（`iphoneos-arm64e`）；rootful / rootless 源码可编但未在设备实测

## 构建

前置：Theos（roothide 版）+ iOS SDK。

```bash
export THEOS=~/theos-roothide
./scripts/build_packages.sh roothide
# 产物：out/CoolapkNoAd_<版本>_roothide_arm64e.deb
```

脚本遵循《越狱插件打包规范》：显式 scheme、`make clean`、`FINALPACKAGE=1`、
打包兜底清理宿主元数据并修正权限位（644/755、root:root），并对产物做架构/字段/权限验收。

需要其它产物线：`./scripts/build_packages.sh all`（rootful / rootless / roothide）。

## 其他产物线

```bash
./scripts/build_packages.sh all
# out/CoolapkNoAd_<版本>_rootful_arm.deb     （iphoneos-arm，安装根 Applications/Library/usr）
# out/CoolapkNoAd_<版本>_rootless_arm64.deb （iphoneos-arm64，安装根 var/jb）
# out/CoolapkNoAd_<版本>_roothide_arm64e.deb（iphoneos-arm64e，@loader_path/.jbroot）
```

> 目前只有 roothide 线在真机上实测；rootful / rootless 包结构与链接语义已按规范验收，但未做设备安装验证。

## 正式版不产生日志

正式构建（`-DCAC_DEBUG` 未开启）里所有日志能力在编译期消除：不建日志文件、不写 `NSLog`、
拦截函数内不做任何字符串处理，只有 `return 0` / 丢弃参数等必要动作。
需要排障时用 `./build.sh debug`，它会额外写 `<容器>/tmp/CAC.log` 与安装报告。

## 安装

用 Sileo / Zebra / Filza 安装 `out/` 里的 deb，安装后重启酷安（或重启 SpringBoard）。

## 文件

| 文件 | 作用 |
| --- | --- |
| `Tweak.xm` | 全部 hook 逻辑（C 运行时 API，无 Logos） |
| `KuAnNoAds.plist` | MobileSubstrate 过滤：`Bundles = [com.coolapk.app]` |
| `control` | 包信息 |
| `Makefile` | Theos 工程（按 scheme 区分部署目标） |
| `scripts/build_packages.sh` | 正式打包入口 |
| `build.sh` | 开发联调：`debug` / `probe` / `feedprobe` |

## 日志

| 位置（酷安数据容器 `tmp/` 下） | 内容 |
| --- | --- |
| `CAC_install_report.txt` | 每次启动覆盖写入：每条 hook 的 `hooked` / `MISS class` / `MISS method` |
| `CAC.log` | 运行日志（正式版只有拦截动作，调试版每次命中都写） |

统一日志里也可搜 `[CoolapkADFree]`：

```bash
log stream --predicate 'eventMessage CONTAINS "[CoolapkADFree]"'
```

## 覆盖点（16.7.3 实测）

- **开屏**：`CSJADLoadSplashContext -splashFinalType`、`ABUSplashAdLoader` 的三个加载入口、`TXAdSplashManager` / `TXAdSplashModule` / `TXAdSplashCacheService` 的拉取入口、`SplashAdvertisementViewController` 生命周期（观测）。
- **信息流 / 详情页**：`GMNativeAdsManager -loadAdDataWithCount:`、`-loadAdDataWithMediaSlotConfigIDs:sign:`、`CSJNativeAdsManager -loadAdDataWithCount:` 直接不加载。
- **兜底**：`setAdslot:` / `setAdMarkup:` / `setAdData:` 丢弃参数。

## 酷安升级后广告又出现？

看 `CAC_install_report.txt`：出现 `MISS` 的条目就是需要重新适配的链路。
方法见 [`docs/UPDATE-GUIDE.md`](docs/UPDATE-GUIDE.md)。

## 许可

[MIT](LICENSE)。仅用于个人设备上的学习与自用，不修改酷安服务端、不上传任何数据。
