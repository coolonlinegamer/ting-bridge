#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
identity="${TING_BRIDGE_SIGNING_IDENTITY:-Ting Bridge Local Code Signing}"
application_directory="${HOME}/Applications"
application_path="${application_directory}/Ting Bridge.app"
executable_path="${application_path}/Contents/MacOS/TingBridge"
launch_agent_path="${HOME}/Library/LaunchAgents/com.bubblymagic.tingbridge.plist"
launch_log_path="${HOME}/Library/Logs/TingBridge-launchd.log"
launch_domain="gui/$(id -u)"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"${identity}\""; then
  printf 'Missing signing identity: %s\n' "${identity}" >&2
  printf 'Run scripts/setup-signing-identity.sh first.\n' >&2
  exit 1
fi

printf 'Building Ting Bridge in release mode...\n'
swift build --package-path "${project_directory}" -c release

mkdir -p "${application_directory}" "${HOME}/Library/LaunchAgents" "${HOME}/Library/Logs"
staging_directory="$(mktemp -d "${application_directory}/.ting-bridge-install.XXXXXX")"
staging_application="${staging_directory}/Ting Bridge.app"
trap 'rm -rf "${staging_directory}"' EXIT

mkdir -p "${staging_application}/Contents/MacOS"
cp "${project_directory}/macos/Info.plist" "${staging_application}/Contents/Info.plist"
cp "${project_directory}/.build/release/TingBridge" "${staging_application}/Contents/MacOS/TingBridge"
chmod 755 "${staging_application}/Contents/MacOS/TingBridge"

printf 'Signing with %s...\n' "${identity}"
codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp=none \
  --sign "${identity}" \
  "${staging_application}"
codesign --verify --deep --strict --verbose=2 "${staging_application}"

launchctl bootout "${launch_domain}/com.bubblymagic.tingbridge" >/dev/null 2>&1 || true
pkill -x TingBridge >/dev/null 2>&1 || true

backup_path="${application_path}.previous"
rm -rf "${backup_path}"
if [[ -e "${application_path}" ]]; then
  mv "${application_path}" "${backup_path}"
fi
if ! mv "${staging_application}" "${application_path}"; then
  if [[ -e "${backup_path}" ]]; then
    mv "${backup_path}" "${application_path}"
  fi
  printf 'Could not install Ting Bridge.app; the previous copy was restored.\n' >&2
  exit 1
fi
rm -rf "${backup_path}"

cp "${project_directory}/macos/com.bubblymagic.tingbridge.plist" "${launch_agent_path}"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 ${executable_path}" "${launch_agent_path}"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath ${launch_log_path}" "${launch_agent_path}"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath ${launch_log_path}" "${launch_agent_path}"
plutil -lint "${launch_agent_path}" >/dev/null

launchctl bootstrap "${launch_domain}" "${launch_agent_path}"
launchctl enable "${launch_domain}/com.bubblymagic.tingbridge"
launchctl kickstart -k "${launch_domain}/com.bubblymagic.tingbridge"

printf 'Installed and launched: %s\n' "${application_path}"
printf 'LaunchAgent: %s\n' "${launch_agent_path}"
