#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
check_old_apps_closed() {
    local executable
    for executable in "$project_root"/dist/*.app/Contents/MacOS/typingRT; do
        if [ -f "$executable" ] && /usr/sbin/lsof -t "$executable" >/dev/null 2>&1; then
            printf 'typingRT bitte zuerst über das Menüleistensymbol beenden (Fenster schließen genügt nicht).\n' >&2
            exit 1
        fi
    done
}
check_old_apps_closed
if [ "${TYPINGRT_SIGNING_MODE:-adhoc}" = certificate ]; then
    printf 'Zertifikatsmodus: vorhandene Identität aus dem Benutzer-Schlüsselbund übernehmen.\n'
    python3 scripts/local-signing.py setup
fi
bash scripts/build-app.sh debug typingRT
printf '\nFester App-Pfad für diese und folgende Versionen:\n%s\n' "$project_root/dist/typingRT.app"
printf 'Falls erforderlich Bedienungshilfen für diese App freigeben.\n'
check_old_apps_closed
open -n "$project_root/dist/typingRT.app" --args --show-window
