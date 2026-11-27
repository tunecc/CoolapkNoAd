#!/bin/bash
# 正式打包入口（遵循《越狱插件打包规范 rootful / rootless / roothide》）
#
#   用法：
#     ./scripts/build_packages.sh                 # 默认只打 roothide（本项目已实测的产物线）
#     ./scripts/build_packages.sh roothide
#     ./scripts/build_packages.sh rootless        # 源码可编，未在设备实测
#     ./scripts/build_packages.sh rootful         # 源码可编，未在设备实测
#     ./scripts/build_packages.sh all             # 三条线依次构建
#
#   约定：
#     - THEOS 指向支持 roothide scheme 的 theos-roothide
#     - 不在 shell 里长期 export THEOS_PACKAGE_SCHEME，由本脚本逐条显式指定
#     - 每条产物线独立 make clean、独立 package 目录
#     - 最终 deb 收敛到 out/，命名 CoolapkNoAd_<Version>_<Scheme>_<ShortArch>.deb
#     - 打包兜底：清宿主元数据 + 权限位修正 + root:root 重打包
set -euo pipefail

# 兼容两种布局：
#   1) 私有总仓库：<repo>/tweak/scripts/build_packages.sh（产物放 <repo>/out）
#   2) 公开仓库（tweak 即项目根）：<repo>/scripts/build_packages.sh（产物放 <repo>/out）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TWEAK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$TWEAK_DIR/.." && pwd)"
if [ -d "$PARENT_DIR/.git" ] && [ "$(basename "$TWEAK_DIR")" = "tweak" ]; then
    ROOT="$PARENT_DIR"
else
    ROOT="$TWEAK_DIR"
fi
OUT_DIR="$ROOT/out"
export THEOS="${THEOS:-$HOME/theos-roothide}"
export COPYFILE_DISABLE=1
export PATH="$THEOS/bin:$PATH"

DISPLAY_NAME="CoolapkNoAd"

# ---- 构建锁：同一项目同一时间只允许一个正式打包流程 ----
LOCK_DIR="${TMPDIR:-/tmp}/$(basename "$ROOT").build.lock"
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -f "$LOCK_DIR/pid" ] && ! kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        continue
    fi
    echo "另一个打包流程正在运行（$LOCK_DIR），等待中…"
    sleep 2
done
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT

clean_host_metadata() {
    local p
    for p in "$@"; do
        [ -e "$p" ] || continue
        find "$p" -type f \( -name '.DS_Store' -o -name '._*' \) -exec rm -f {} +
        find "$p" -name '__MACOSX' -type d -prune -exec rm -rf {} +
    done
}

sanitize_permissions() {
    local d="$1"
    find "$d" -type f -name '*.plist' -exec chmod 644 {} +
    find "$d" -type f -name '*.dylib' -exec chmod 755 {} +
    [ -d "$d/DEBIAN" ] && find "$d/DEBIAN" -type f -exec chmod 644 {} +
    find "$d" -type d -exec chmod 755 {} +
}

verify_deb() {
    local deb="$1" want_scheme="$2"
    local pkg ver arch
    pkg="$(dpkg-deb -f "$deb" Package)"
    ver="$(dpkg-deb -f "$deb" Version)"
    arch="$(dpkg-deb -f "$deb" Architecture)"

    echo "== 验收 $deb"
    echo "   Package=$pkg Version=$ver Architecture=$arch"
    case "$want_scheme" in
        rootful)  [ "$arch" = "iphoneos-arm" ]    || { echo "!! rootful 架构应为 iphoneos-arm"; exit 1; } ;;
        rootless) [ "$arch" = "iphoneos-arm64" ]  || { echo "!! rootless 架构应为 iphoneos-arm64"; exit 1; } ;;
        roothide) [ "$arch" = "iphoneos-arm64e" ] || { echo "!! roothide 架构应为 iphoneos-arm64e"; exit 1; } ;;
    esac
    for f in Package Version Architecture Maintainer Description; do
        [ -n "$(dpkg-deb -f "$deb" "$f")" ] || { echo "!! control 缺少必填字段 $f"; exit 1; }
    done
    [ -n "$(dpkg-deb -f "$deb" Installed-Size)" ] || { echo "!! control 缺少 Installed-Size"; exit 1; }

    local unpack
    unpack="$(mktemp -d)"
    dpkg-deb -R "$deb" "$unpack"
    if find "$unpack" \( -name '.DS_Store' -o -name '._*' -o -name '__MACOSX' \) | grep -q .; then
        echo "!! 包内存在宿主元数据文件"; rm -rf "$unpack"; exit 1
    fi
    if dpkg-deb -c "$deb" | awk '{print $1, $2}' | grep -vE '^(-rw-r--r--|-rwxr-xr-x|drwxr-xr-x) root/root$'; then
        echo "!! 包内存在 644/755 之外的权限位或非 root 归属"; rm -rf "$unpack"; exit 1
    fi
    if [ "$want_scheme" = "rootful" ] && [ -d "$unpack/var/jb" ]; then
        echo "!! rootful 包不应包含 var/jb"; rm -rf "$unpack"; exit 1
    fi
    if [ "$want_scheme" = "rootless" ] && [ ! -d "$unpack/var/jb" ]; then
        echo "!! rootless 包应以 var/jb 为安装根"; rm -rf "$unpack"; exit 1
    fi
    rm -rf "$unpack"
}

build_scheme() {
    local scheme="$1" pkg_scheme arch short
    case "$scheme" in
        rootful)  pkg_scheme=""          arch="iphoneos-arm"    short="arm"   ;;
        rootless) pkg_scheme="rootless"  arch="iphoneos-arm64"  short="arm64" ;;
        roothide) pkg_scheme="roothide"  arch="iphoneos-arm64e" short="arm64e";;
        *) echo "未知 scheme: $scheme"; exit 2 ;;
    esac

    echo "================ build $scheme ================"
    cd "$TWEAK_DIR"
    rm -rf "packages/$scheme"
    mkdir -p "packages/$scheme"

    make clean >/dev/null 2>&1 || true
    # rootful 必须显式清空 scheme；其余显式指定
    THEOS_PACKAGE_SCHEME="$pkg_scheme" \
    THEOS_PACKAGE_DIR="$TWEAK_DIR/packages/$scheme" \
    FINALPACKAGE=1 \
    make package

    local count deb version
    count=$(find "packages/$scheme" -maxdepth 1 -name '*.deb' | wc -l | tr -d ' ')
    [ "$count" = "1" ] || { echo "!! packages/$scheme 下产物数量异常：$count"; exit 1; }
    deb=$(find "packages/$scheme" -maxdepth 1 -name '*.deb')
    version=$(dpkg-deb -f "$deb" Version)

    mkdir -p "$OUT_DIR"
    local unpack target
    unpack="$(mktemp -d)"
    target="$OUT_DIR/${DISPLAY_NAME}_${version}_${scheme}_${short}.deb"
    dpkg-deb -R "$deb" "$unpack"
    clean_host_metadata "$unpack"
    sanitize_permissions "$unpack"
    rm -f "$target"
    dpkg-deb -b --root-owner-group "$unpack" "$target"
    rm -rf "$unpack"

    verify_deb "$target" "$scheme"
    echo "== 产物：$target"
}

SCHEMES=("$@")
[ ${#SCHEMES[@]} -eq 0 ] && SCHEMES=("roothide")
if [ "${SCHEMES[0]}" = "all" ]; then
    SCHEMES=("rootful" "rootless" "roothide")
fi

mkdir -p "$OUT_DIR"
for s in "${SCHEMES[@]}"; do
    build_scheme "$s"
done
echo "全部完成。产物目录：$OUT_DIR"
