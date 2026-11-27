# Changelog

## 1.0.0 — 2026-11-27

首个正式版，适配酷安 16.7.3（`com.coolapk.app` build 2611121）。

- 开屏：拦截 CSJ/Pangle 开屏判定与 ABU 聚合加载入口，覆盖酷安自营 TXAd 开屏拉取
- 信息流 / 详情页：掐断 `GMNativeAdsManager` / `CSJNativeAdsManager` 的原生广告加载
- 兜底：原生广告数据灌入（`setAdslot:` / `setAdMarkup:` / `setAdData:`）参数丢弃
- 工程：安装报告 + 可选命中日志；release / debug / probe / feedprobe 四档构建
- 打包：按越狱插件打包规范提供统一入口 `scripts/build_packages.sh`（roothide 已实测，rootful/rootless 可编未实测）
