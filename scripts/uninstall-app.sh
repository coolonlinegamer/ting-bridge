#!/bin/zsh

set -euo pipefail

label="com.bubblymagic.tingbridge"
launch_domain="gui/$(id -u)"
application_path="${HOME}/Applications/Ting Bridge.app"
launch_agent_path="${HOME}/Library/LaunchAgents/${label}.plist"

launchctl bootout "${launch_domain}/${label}" >/dev/null 2>&1 || true
pkill -x TingBridge >/dev/null 2>&1 || true

rm -rf "${application_path}"
rm -f "${launch_agent_path}"
rm -f "${HOME}/Library/Logs/TingBridge.log"
rm -f "${HOME}/Library/Logs/TingBridge-launchd.log"
rm -rf "${HOME}/Library/Application Support/TingBridge"
tccutil reset Accessibility "${label}" >/dev/null 2>&1 || true

printf 'Ting Bridge was removed.\n'
printf 'The local signing identity was kept for stable reinstalls.\n'
printf 'To remove the identity and its local trust setting too, run:\n'
printf '  security delete-identity -t -c %q %q\n' 'Ting Bridge Local Code Signing' "${HOME}/Library/Keychains/login.keychain-db"
