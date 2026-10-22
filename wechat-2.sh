#!/bin/bash
# macOS WeChat Multi Instance Script
# Usage:
#   sudo ./wechat-2.sh auto --force
#   sudo ./wechat-2.sh multi 3 --force   # 多开3个副本
#   sudo ./wechat-2.sh rebuild --force   # 更新后自动重建所有副本（沿用原 Bundle ID，数据保留）
#   sudo ./wechat-2.sh icon              # 给已有副本补上 WORK 角标
#   ./wechat-2.sh status                 # 查看副本 / Bundle ID / 数据容器映射
#   ./wechat-2.sh orphans                # 查看有数据但没有副本在用的容器

set -euo pipefail

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 脚本所在目录 & 角标图标（可用 WECHAT_ICON=/path/to/xxx.icns 覆盖）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICON_FILE="${WECHAT_ICON:-$SCRIPT_DIR/AppIcon-work.icns}"

# 默认路径
WECHAT_APP="/Applications/WeChat.app"
DEST_DIR="/Applications"
BASE_APP_NAME="微信Work"
FORCE=0

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}缺少命令: $1${NC}"; exit 1; }
}
for cmd in ditto codesign xattr /usr/libexec/PlistBuddy; do require_cmd "$cmd"; done

check_wechat() {
    if [ ! -d "$WECHAT_APP" ]; then
        echo -e "${RED}未找到微信: $WECHAT_APP${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ 检测到微信已安装${NC}"
}

# 查找已存在的副本
list_existing_apps() {
    ls "$DEST_DIR" | grep "^$BASE_APP_NAME[0-9]*\.app$" || true
}

# ==================== Bundle ID 与数据容器 ====================
# 微信的数据按 Bundle ID 存在 ~/Library/Containers/<bundle-id>。
# 重建时沿用原 App 里的 Bundle ID，容器就能继续被使用，登录态和聊天记录不会丢。

containers_dir() {
    local user_home
    if [ -n "${SUDO_USER:-}" ]; then
        user_home=$(eval echo "~$SUDO_USER")
    else
        user_home="$HOME"
    fi
    printf '%s/Library/Containers\n' "$user_home"
}

current_bundle_id() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$DEST_DIR/$1/Contents/Info.plist" 2>/dev/null || true
}

is_id_used() {
    local id="$1" app
    for app in $(list_existing_apps); do
        [ "$(current_bundle_id "$app")" = "$id" ] && return 0
    done
    return 1
}

# 容器里是否有真实数据（只初始化过、没登录过的空壳不算）
container_has_data() {
    local cdir="$1" f
    for f in "$cdir/Data/Documents/xwechat_files"/wxid_*; do
        [ -e "$f" ] && return 0
    done
    [ -d "$cdir/Data/Documents/app_data/db_storage" ] && return 0
    return 1
}

# 有数据、但没有副本在用的容器（格式：BundleID|大小）
list_orphan_containers() {
    local cdir dir id
    cdir=$(containers_dir)
    [ -d "$cdir" ] || return 0
    for dir in "$cdir"/com.tencent.xinWeChat.dual.*; do
        [ -d "$dir" ] || continue
        id=$(basename "$dir")
        container_has_data "$dir" || continue
        is_id_used "$id" && continue
        printf '%s|%s\n' "$id" "$(du -sh "$dir" 2>/dev/null | cut -f1)"
    done
}

show_orphans() {
    local orphans id size
    orphans=$(list_orphan_containers)
    if [ -z "$orphans" ]; then
        echo -e "${GREEN}✓ 没有无主容器：所有有数据的容器都已被副本使用${NC}"
        return
    fi
    echo -e "${YELLOW}以下容器有数据，但没有副本在使用：${NC}"
    while IFS='|' read -r id size; do
        printf "  %-45s %s\n" "$id" "$size"
    done <<< "$orphans"
    echo -e "${YELLOW}确认不再需要后，可以手动删除对应目录释放空间。${NC}"
}

show_status() {
    local apps app id c size orphans
    apps=$(list_existing_apps)
    if [ -z "$apps" ]; then
        echo "未找到副本（$DEST_DIR/$BASE_APP_NAME*.app）"
        return
    fi
    echo -e "${BLUE}副本 / Bundle ID / 数据容器：${NC}"
    for app in $apps; do
        id=$(current_bundle_id "$app")
        c="$(containers_dir)/$id"
        if [ -d "$c/Data/Documents" ]; then
            size=$(du -sh "$c" 2>/dev/null | cut -f1)
            printf "  %-18s %-45s 数据 %s\n" "$app" "$id" "$size"
        else
            printf "  %-18s %-45s 无容器\n" "$app" "$id"
        fi
    done
    orphans=$(list_orphan_containers)
    if [ -n "$orphans" ]; then
        echo
        echo -e "${YELLOW}无主容器（有数据但没有副本在用）：${NC}"
        while IFS='|' read -r id size; do
            printf "  %-45s %s\n" "$id" "$size"
        done <<< "$orphans"
    fi
}

# ==================== 创建 / 重建 ====================

remove_app() {
    local dest="$DEST_DIR/$1"
    if [ -d "$dest" ]; then
        if [ $FORCE -eq 1 ]; then
            sudo rm -rf "$dest"
        else
            if ! read -p "是否删除并重新创建 $1? (y/n): " yn; then
                return 1
            fi
            if [[ ! $yn =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}已取消${NC}"
                return 1
            fi
            sudo rm -rf "$dest"
        fi
    fi
    return 0
}

copy_wechat() {
    local app_name=$1
    sudo ditto "$WECHAT_APP" "$DEST_DIR/$app_name"
}

# 为新副本分配随机且未被占用的 Bundle ID
new_bundle_id() {
    local id cdir tries=0
    cdir=$(containers_dir)
    while [ "$tries" -lt 100 ]; do
        tries=$((tries + 1))
        id="com.tencent.xinWeChat.dual.$RANDOM"
        [ -d "$cdir/$id" ] && continue
        if ! is_id_used "$id"; then
            printf '%s\n' "$id"
            return 0
        fi
    done
    printf 'com.tencent.xinWeChat.dual.%s\n' "$$"
}

modify_bundle_id() {
    local app_name=$1
    local new_id="${2:-}"
    local info_plist="$DEST_DIR/$app_name/Contents/Info.plist"
    local display_name="${app_name%.app}"

    if [ -z "$new_id" ]; then
        new_id=$(new_bundle_id)
    fi
    sudo /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $new_id" "$info_plist"
    sudo /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $display_name" "$info_plist" || true
    echo -e "${GREEN}  Bundle ID = $new_id${NC}"
}

# 给副本换 WORK 角标。
# 微信 4.x 的 Info.plist 里有 CFBundleIconName=AppIcon，同时在 Assets.car 里
# 也有一份 AppIcon，系统会优先用 Assets.car，所以必须删掉这个键，
# 替换后的 AppIcon.icns 才会生效。改完资源后由 resign_app 统一重签。
apply_icon() {
    local app_name=$1
    local dest="$DEST_DIR/$app_name"
    local info_plist="$dest/Contents/Info.plist"

    if [ ! -f "$ICON_FILE" ]; then
        echo -e "${YELLOW}⚠ 未找到图标: $ICON_FILE，跳过角标${NC}"
        return 0
    fi

    sudo cp "$ICON_FILE" "$dest/Contents/Resources/AppIcon.icns"
    sudo chown root:wheel "$dest/Contents/Resources/AppIcon.icns"
    sudo chmod 644 "$dest/Contents/Resources/AppIcon.icns"
    sudo /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$info_plist" 2>/dev/null || true
}

resign_app() {
    local app_name=$1
    local dest="$DEST_DIR/$app_name"
    sudo rm -rf "$dest/Contents/_CodeSignature" || true
    sudo xattr -dr com.apple.quarantine "$dest" || true
    # 当前微信 4.1.x 用 --deep 正常；PR #4 提到 4.1.15+ 需要去掉 --deep，
    # 等实际升到 4.1.15+ 再调整。
    sudo codesign --force --deep --sign - --timestamp=none "$dest"
    # 更新 bundle 修改时间并刷新 LaunchServices 记录，帮助 Finder/Dock 刷新图标
    sudo touch "$dest"
    sudo /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" >/dev/null 2>&1 || true
}

# 统一的创建/重建流程：
#   已有副本 -> 先读旧 Bundle ID，重建后原样写回（数据容器复用）
#   全新副本 -> 分配未占用的随机 Bundle ID
recreate_app() {
    local app_name=$1 old_id=""

    if [ -d "$DEST_DIR/$app_name" ]; then
        old_id=$(current_bundle_id "$app_name")
        if [ -z "$old_id" ] || [[ "$old_id" != com.tencent.xinWeChat.dual.* ]]; then
            echo -e "${RED}错误：$app_name 已存在，但读不到合法的 Bundle ID（当前：'${old_id:-空}'）。${NC}" >&2
            echo -e "${YELLOW}若继续重建，数据容器会与副本失联，因此已中止。${NC}" >&2
            echo -e "${YELLOW}请先检查 $DEST_DIR/$app_name/Contents/Info.plist。${NC}" >&2
            exit 1
        fi
        echo -e "${BLUE}沿用原 Bundle ID: $old_id${NC}"
    fi

    if ! remove_app "$app_name"; then
        echo -e "${YELLOW}已取消重建 $app_name${NC}" >&2
        exit 1
    fi

    copy_wechat "$app_name"
    modify_bundle_id "$app_name" "$old_id"
    apply_icon "$app_name"
    resign_app "$app_name"
}

start_apps() {
    shift
    for app_name in "$@"; do open -n "$DEST_DIR/$app_name"; sleep 1; done
}

# 只终止副本，绝不动原生 /Applications/WeChat.app
kill_wechat() {
    local app_name
    for app_name in $(list_existing_apps); do
        pkill -f "$DEST_DIR/$app_name" 2>/dev/null || true
    done
}

main() {
    case "${1:-}" in
        setup)
            check_wechat
            recreate_app "${BASE_APP_NAME}.app"
            ;;
        start)
            start_apps "WeChat.app" "${BASE_APP_NAME}.app"
            ;;
        auto)
            check_wechat
            recreate_app "${BASE_APP_NAME}.app"
            start_apps "WeChat.app" "${BASE_APP_NAME}.app"
            ;;
        multi)
            local count=${2:-2}
            check_wechat
            for i in $(seq 1 "$count"); do
                recreate_app "${BASE_APP_NAME}${i}.app"
            done
            start_apps $(for i in $(seq 1 "$count"); do echo "${BASE_APP_NAME}${i}.app"; done)
            ;;
        rebuild)
            check_wechat
            echo -e "${BLUE}正在重建副本（沿用原 Bundle ID，数据自动保留）...${NC}"
            if pgrep -f "$DEST_DIR/$BASE_APP_NAME" >/dev/null 2>&1; then
                echo -e "${YELLOW}⚠ 检测到副本可能正在运行，建议先退出再重建，避免新旧进程共用同一个数据容器。${NC}"
            fi
            local apps=$(list_existing_apps)
            if [ -z "$apps" ]; then
                echo -e "${YELLOW}没有找到副本，请先运行 auto 或 setup${NC}"
                exit 0
            fi
            for app_name in $apps; do
                echo -e "${YELLOW}重建 $app_name ...${NC}"
                recreate_app "$app_name"
            done
            echo -e "${GREEN}✓ 所有副本已重新生成，Bundle ID 与数据容器保持不变${NC}"
            show_status
            ;;
        status)
            show_status
            ;;
        orphans)
            show_orphans
            ;;
        icon)
            local apps=$(list_existing_apps)
            if [ -z "$apps" ]; then
                echo -e "${YELLOW}未找到副本，请先运行 auto 或 multi${NC}"
                exit 0
            fi
            for app_name in $apps; do
                echo -e "${YELLOW}正在为 $app_name 应用 WORK 角标...${NC}"
                apply_icon "$app_name"
                resign_app "$app_name"
                echo -e "${GREEN}✓ $app_name 完成${NC}"
            done
            echo -e "${BLUE}提示: 如果副本正在运行，请退出后重新打开才能看到新图标${NC}"
            if [ -n "${SUDO_USER:-}" ]; then
                sudo -u "$SUDO_USER" killall Dock 2>/dev/null || true
            else
                killall Dock 2>/dev/null || true
            fi
            ;;
        -k|kill)
            kill_wechat
            ;;
        -h|--help|"")
            echo "用法: $0 {setup|start|auto|multi N|rebuild|status|orphans|icon|kill} [--force]"
            echo "  status  查看副本 / Bundle ID / 数据容器映射"
            echo "  orphans 查看有数据但没有副本在用的容器"
            ;;
        *)
            echo -e "${RED}未知参数: $1${NC}"
            exit 1
            ;;
    esac
}

for arg in "$@"; do [[ $arg == "--force" ]] && FORCE=1; done
main "$@"
