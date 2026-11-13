#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) printf 'Konfiguration muss debug oder release sein.\n' >&2; exit 1 ;; esac
output_name="${2:-typingRT}"
case "$output_name" in ''|*[!a-zA-Z0-9_-]*) printf 'Ungültiger Bundle-Name.\n' >&2; exit 1 ;; esac
destination_path="$project_root/dist/$output_name.app"
worker_mode="${3:-required}"
case "$worker_mode" in required|preview|development) ;; *) printf 'Build-Modus muss required, preview oder development sein.\n' >&2; exit 1 ;; esac
if [ "$worker_mode" = development ] && [ "$output_name" != typingRT-development ]; then
    printf 'Entwicklungsbuild ausschließlich als typingRT-development erstellen; Alltagspfad bleibt geschützt.\n' >&2
    exit 1
fi
if [ "$output_name" = typingRT-development ] && [ "$worker_mode" != development ]; then
    printf 'typingRT-development ist dem isolierten Entwicklungsbuild vorbehalten.\n' >&2
    exit 1
fi
check_not_running() {
if [ -d "$destination_path" ] && [ -x /usr/sbin/lsof ]; then
    for executable in "$destination_path/Contents/MacOS/typingRT" \
        "$destination_path"/Contents/XPCServices/*.xpc/Contents/MacOS/TranscriptionWorker; do
        if [ -f "$executable" ] && /usr/sbin/lsof -t "$executable" >/dev/null 2>&1; then
            printf 'Dieses App-Bundle läuft noch. Bitte beenden oder einen anderen Ausgabenamen wählen.\n' >&2
            exit 1
        fi
    done
fi
}
check_not_running
signing_identity="-"
signing_keychain=""
app_identifier="dev.typingrt.mac"
signing_mode="${TYPINGRT_SIGNING_MODE:-adhoc}"
case "$signing_mode" in adhoc|certificate) ;; *) printf 'Signaturmodus muss adhoc oder certificate sein.\n' >&2; exit 1 ;; esac
if [ "$worker_mode" = preview ]; then app_identifier="dev.typingrt.mac.preview"; fi
if [ "$worker_mode" = development ]; then app_identifier="dev.typingrt.mac.development"; fi
worker_identifier="$app_identifier.TranscriptionWorker"
if [ "${TYPINGRT_ADHOC_PREVIEW:-0}" = 1 ]; then
    if [ "$worker_mode" != preview ]; then
        printf 'Ad-hoc ist nur für eine ausdrücklich Worker-lose Vorschau zulässig.\n' >&2
        exit 1
    fi
    signing_mode=adhoc
fi
if [ "$signing_mode" = certificate ]; then
    signing_settings="$(python3 scripts/local-signing.py settings)"
    signing_identity="$(printf '%s\n' "$signing_settings" | sed -n '1p')"
    signing_keychain="$(printf '%s\n' "$signing_settings" | sed -n '2p')"
else
    printf 'Lokaler Ad-hoc-Build ohne eigenes Zertifikat; neue Builds können erneute Bedienungshilfenfreigabe benötigen.\n'
fi
# Do not touch the previous bundle until all builds and signatures have passed.
mkdir -p "$project_root/dist"
lock_directory="$project_root/dist/.$output_name.build-lock"
if ! mkdir "$lock_directory" 2>/dev/null; then
    printf 'Build-Ziel gesperrt: paralleler oder abgebrochener Build. Sperre vor erneutem Start prüfen: %s\n' "$lock_directory" >&2
    exit 1
fi
staging_directory=""
cleanup() {
    if [ -n "$staging_directory" ]; then
        if [ -d "$staging_directory/previous.app" ] && [ ! -e "$destination_path" ]; then
            mv "$staging_directory/previous.app" "$destination_path"
        fi
        rm -rf "$staging_directory"
    fi
    rmdir "$lock_directory"
}
trap cleanup EXIT
staging_directory="$(mktemp -d "$project_root/dist/.typingrt-bundle.XXXXXX")"
app_path="$staging_directory/$output_name.app"
sign_bundle() {
    local identifier="$1" bundle="$2"
    if [ "$signing_identity" = - ]; then
        /usr/bin/codesign --force --sign - --identifier "$identifier" "$bundle"
    else
        /usr/bin/codesign --force --sign "$signing_identity" --keychain "$signing_keychain" \
            --timestamp=none --identifier "$identifier" "$bundle"
        python3 scripts/local-signing.py verify "$bundle"
    fi
    /usr/bin/codesign --verify --strict "$bundle"
}
if [ "$worker_mode" != preview ]; then
    bash scripts/swift-tool.sh build --package-path Workers/TranscriptionWorker \
        --scratch-path "$project_root/.build/worker" -c "$configuration" --product TranscriptionWorker
    worker_binary_directory="$(bash scripts/swift-tool.sh build --package-path Workers/TranscriptionWorker \
        --scratch-path "$project_root/.build/worker" -c "$configuration" --show-bin-path)"
fi
bash scripts/swift-tool.sh build -c "$configuration" --product typingRT
binary_directory="$(bash scripts/swift-tool.sh build -c "$configuration" --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_directory/typingRT" "$app_path/Contents/MacOS/typingRT"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
if [ "$app_identifier" != dev.typingrt.mac ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $app_identifier" "$app_path/Contents/Info.plist"
fi
if [ "$worker_mode" = development ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName typingRT Development" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName typingRT Development" "$app_path/Contents/Info.plist"
fi
# Upstream license files may be read-only; force replaces those generated copies.
cp -Rf Resources/ThirdParty "$app_path/Contents/Resources/"
# Generated by scripts/make-icon.swift; see scripts/README.md.
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
worker_path="$app_path/Contents/XPCServices/$worker_identifier.xpc"
if [ "$worker_mode" != preview ]; then
    mkdir -p "$worker_path/Contents/MacOS" "$worker_path/Contents/Resources"
    cp "$worker_binary_directory/TranscriptionWorker" "$worker_path/Contents/MacOS/TranscriptionWorker"
    cp Workers/TranscriptionWorker/Resources/Info.plist "$worker_path/Contents/Info.plist"
    # SwiftPM resources belong beside the executable, preserving Bundle.module.
    shopt -s nullglob
    for resource in "$worker_binary_directory"/*.bundle; do cp -R "$resource" "$worker_path/Contents/MacOS/"; done
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $worker_identifier" "$worker_path/Contents/Info.plist"
    sign_bundle "$worker_identifier" "$worker_path"
else
    rm -rf "$worker_path"
    printf 'Vorschau ohne WhisperKit-Worker: Diktate bleiben gesperrt.\n'
fi
sign_bundle "$app_identifier" "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
check_not_running
if [ -e "$destination_path" ]; then mv "$destination_path" "$staging_directory/previous.app"; fi
mv "$app_path" "$destination_path"
printf '\nLokale App: %s\n' "$destination_path"
