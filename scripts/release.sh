#!/usr/bin/env bash
#
# Cella 生产发布流水线：构建 → 签名 → 打包 DMG → 公证 → staple
#
# 凭据从仓库根目录的 .env 读取（已在 .gitignore 中排除）。
# 参考 .env.example 填写，或直接复用 Sentinel 的 Apple 开发者账号配置。
#
# 用法：
#   ./scripts/release.sh                 # 完整流程：构建 + 公证
#   ./scripts/release.sh --no-notarize   # 只构建出签名后的 .app / .dmg（本地自测）
#   ./scripts/release.sh --use-keychain  # 用 notarytool 钥匙串档案提交公证
#   ./scripts/release.sh --no-timestamp  # 签名不请求时间戳（TSA 不可达时的应急）
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build-signed"
RELEASE_DIR="$ROOT/release"
SCHEME="Cella"
PROJECT="Cella.xcodeproj"

NOTARIZE=1
USE_KEYCHAIN_PROFILE=0
NO_TIMESTAMP=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize)     NOTARIZE=0 ;;
    --no-timestamp)    NO_TIMESTAMP=1 ;;
    --use-keychain)    USE_KEYCHAIN_PROFILE=1 ;;
    -h|--help)         sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- 日志
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '\033[31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 读取 .env
ENV_FILE="$ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  fail "缺少 ${ENV_FILE}。请先执行：cp .env.example .env 并填入真实凭据。"
fi

# 只解析 KEY=VALUE，去掉行内注释与包裹的引号，不 eval（避免命令注入）。
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"        # 去前导空白
  [[ -z "$line" || "$line" == \#* ]] && continue # 跳过空行与注释
  [[ "$line" != *=* ]] && continue
  key="${line%%=*}"
  val="${line#*=}"
  val="${val%%[[:space:]]#*}"                    # 去行内注释
  val="${val%"${val##*[![:space:]]}"}"           # 去尾随空白
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  [[ -n "$key" ]] && export "$key=$val"
done < "$ENV_FILE"

: "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY 未在 .env 中设置}"

if (( NOTARIZE )); then
  if (( USE_KEYCHAIN_PROFILE )); then
    : "${NOTARY_KEYCHAIN_PROFILE:?使用 --use-keychain 时需在 .env 中设置 NOTARY_KEYCHAIN_PROFILE}"
    NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  else
    : "${APPLE_ID:?APPLE_ID 未在 .env 中设置}"
    : "${APPLE_PASSWORD:?APPLE_PASSWORD 未在 .env 中设置}"
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID 未在 .env 中设置}"
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
  fi
fi

# 签名时间戳服务，默认 Apple TSA。
#
# 之所以做成可配置：某些代理会让 codesign 报「The timestamp service is not
# available.」，此时可指向其它 RFC3161 服务。注意 codesign 只接受 HTTP URL
# （给 HTTPS 会报 "Only HTTP timestamp URLs are supported"，且并非任意第三方
# TSA 都会被接受）。完全绕不过去时用 --no-timestamp 出本地自测包，代价是无法公证，
# 因为公证要求签名带时间戳。
TIMESTAMP_URL="${APPLE_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"
if (( NO_TIMESTAMP )); then TIMESTAMP_URL="none"; fi

VERSION="$(grep -m1 'MARKETING_VERSION' "$PROJECT/project.pbxproj" \
  | sed -E 's/.*=[[:space:]]*([^;]+);.*/\1/')"
APP="$BUILD_DIR/Build/Products/Release/$SCHEME.app"
DMG="$RELEASE_DIR/Cella-$VERSION.dmg"

bold "Cella $VERSION 生产构建"
info "签名证书 : $APPLE_SIGNING_IDENTITY"
info "架构     : universal (arm64 + x86_64)"
if [[ "$TIMESTAMP_URL" == "none" ]]; then
  info "时间戳   : 已禁用（产物不可公证）"
else
  info "时间戳   : $TIMESTAMP_URL"
fi
info "公证     : $(( NOTARIZE )) $([[ $NOTARIZE == 1 ]] && echo '开启' || echo '跳过')"
echo

# ---------------------------------------------------------------- 证书检查
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$APPLE_SIGNING_IDENTITY"; then
  fail "钥匙串中找不到证书「${APPLE_SIGNING_IDENTITY}」。

  用以下命令查看可用证书，并把完整常用名写进 .env 的 APPLE_SIGNING_IDENTITY：
      security find-identity -v -p codesigning"
fi

# ---------------------------------------------------------------- 无需描述文件
# Cella 不再使用 iCloud 容器。跨设备同步交给系统：iCloud Drive 的「桌面与文档」
# 会复制整个 ~/Documents，而数据目录 ~/Documents/cella/task-note 正在其中。
# 因此这里没有任何受限 entitlement，Developer ID 证书直接签名即可发布，
# 不需要 provisioning profile，也不需要 Xcode 登录开发者账号。

# ---------------------------------------------------------------- 构建
bold "1/5 构建"
# 通用二进制：同时产出 arm64 与 x86_64，避免用户设备架构不匹配。
build_once() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CODE_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp=${TIMESTAMP_URL}" \
    build
}

# 时间戳服务会偶发不可用：同一个 TSA 可能前一次能签、下一次就返回 503，而签名阶段
# 失败会让整个构建以「The timestamp service is not available.」中止。构建是增量的，
# 直接重试即可，不必让用户手动重跑。
SIGN_ATTEMPTS=5
attempt=1
until build_once; do
  if (( attempt >= SIGN_ATTEMPTS )); then
    fail "构建失败：连续 ${SIGN_ATTEMPTS} 次都没能完成签名。

  若报错为「The timestamp service is not available.」，说明访问不到
  ${TIMESTAMP_URL}，通常是代理拦截了 Apple 域名。可用以下命令确认：
      curl -x <你的代理> -o /dev/null -w '%{http_code}\\n' http://timestamp.apple.com/ts01
  返回 503 即为此症状。

  应急：先出一个能本地安装自测的包（产物不可公证）
      ./scripts/release.sh --no-notarize --no-timestamp
  或在修好代理后重跑本脚本。"
  fi
  printf '  第 %d 次签名失败（时间戳服务抖动），重试…\n' "$attempt"
  attempt=$(( attempt + 1 ))
  sleep 3
done

[[ -d "$APP" ]] || fail "构建产物不存在：$APP"

# ---------------------------------------------------------------- 校验签名
bold "2/5 校验签名与权限"
# 公证要求硬运行时（--options runtime）与安全时间戳，缺一不可。
codesign --verify --deep --strict --verbose=2 "$APP"
info "签名校验通过"

echo "  实际生效的 entitlements："
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | plutil -convert xml1 -o - - 2>/dev/null \
  | grep -E '<key>|<string>|<true/>|<false/>' \
  | sed 's/^[[:space:]]*/    /' || true

# 签名结果里不应再出现 iCloud 受限 entitlement —— 一旦出现就说明仍需描述文件，
# 而 Cella 已改为依赖系统 iCloud Drive，出现即代表 Cella.entitlements 被改回了。
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'com.apple.developer.icloud'; then
  echo
  echo "  \033[33m警告：签名结果里出现 iCloud 容器权限。\033[0m"
  echo "  这是受限 entitlement，需要描述文件才能公证；请检查 Cella/Cella.entitlements。"
fi

# ---------------------------------------------------------------- 打包 DMG
bold "3/5 打包 DMG"
mkdir -p "$RELEASE_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Cella" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
codesign --force --timestamp="${TIMESTAMP_URL}" --sign "$APPLE_SIGNING_IDENTITY" "$DMG"
info "已生成 $DMG"

# ---------------------------------------------------------------- 公证
if (( NOTARIZE )); then
  bold "4/5 公证（上传给 Apple，可能需要几分钟）"
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait

  bold "5/5 staple 并验证"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type install --verbose=2 "$DMG"
  info "公证完成，可分发"
else
  bold "4/5 跳过公证（--no-notarize）"
  bold "5/5 跳过 staple"
  echo
  echo "  注意：未公证的 DMG 在其它 Mac 上首次打开会被 Gatekeeper 拦截。"
fi

echo
bold "完成"
info "$DMG"
