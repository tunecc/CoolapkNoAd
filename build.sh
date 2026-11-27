#!/bin/bash
# 构建脚本：release 为正式包（无命中日志、无诊断探针），debug 为排障包。
# 用法：
#   ./build.sh release          # 生成 com.tune.coolapk.noads_<version>_iphoneos-arm64e.deb
#   ./build.sh debug            # 生成带命中日志的包（+debug 后缀）
#   ./build.sh probe            # 生成开屏诊断包（只观测）
#   ./build.sh feedprobe        # 生成信息流诊断包（只观测，6 个入口）
set -e
cd "$(dirname "$0")"
MODE="${1:-release}"
export THEOS="${THEOS:-$HOME/theos-roothide}"
make clean >/dev/null 2>&1 || true
case "$MODE" in
  release)
    make package THEOS_PACKAGE_SCHEME=roothide DEBUG=0
    ;;
  debug)
    make package THEOS_PACKAGE_SCHEME=roothide EXTRA_CFLAGS=-DCAC_DEBUG
    ;;
  probe)
    make package THEOS_PACKAGE_SCHEME=roothide EXTRA_CFLAGS="-DCAC_PROBE"
    ;;
  feedprobe)
    make package THEOS_PACKAGE_SCHEME=roothide EXTRA_CFLAGS="-DCAC_FEEDPROBE2"
    ;;
  *)
    echo "usage: $0 [release|debug|probe|feedprobe]"; exit 2;;
esac
ls -1t packages/*.deb | head -1
