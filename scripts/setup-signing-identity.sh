#!/bin/zsh

set -euo pipefail

identity="Ting Bridge Local Code Signing"
keychain="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "${keychain}" 2>/dev/null | grep -Fq "\"${identity}\""; then
  printf 'Signing identity already available: %s\n' "${identity}"
  exit 0
fi

openssl_command="${OPENSSL_BIN:-}"
if [[ -z "${openssl_command}" ]] && command -v brew >/dev/null 2>&1; then
  brew_openssl="$(brew --prefix openssl@3 2>/dev/null || true)/bin/openssl"
  if [[ -x "${brew_openssl}" ]]; then
    openssl_command="${brew_openssl}"
  fi
fi
if [[ -z "${openssl_command}" ]]; then
  openssl_command="$(command -v openssl || true)"
fi
if [[ -z "${openssl_command}" ]] || ! "${openssl_command}" req -help 2>&1 | grep -q -- '-addext'; then
  printf 'A compatible OpenSSL with req -addext support is required.\n' >&2
  printf 'Install OpenSSL 3 with: brew install openssl@3\n' >&2
  exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/ting-bridge-signing.XXXXXX")"
trap 'rm -rf "${temporary_directory}"' EXIT

certificate="${temporary_directory}/certificate.pem"
private_key="${temporary_directory}/private-key.pem"
archive="${temporary_directory}/identity.p12"
archive_password="$("${openssl_command}" rand -hex 24)"

printf 'Creating local signing identity: %s\n' "${identity}"
"${openssl_command}" req \
  -x509 \
  -newkey rsa:3072 \
  -sha256 \
  -nodes \
  -days 3650 \
  -subj "/CN=${identity}/O=Ting Bridge" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout "${private_key}" \
  -out "${certificate}" \
  >/dev/null 2>&1

"${openssl_command}" pkcs12 \
  -export \
  -name "${identity}" \
  -inkey "${private_key}" \
  -in "${certificate}" \
  -out "${archive}" \
  -passout "pass:${archive_password}" \
  >/dev/null 2>&1

security import "${archive}" \
  -k "${keychain}" \
  -f pkcs12 \
  -x \
  -P "${archive_password}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  >/dev/null

security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "${keychain}" \
  "${certificate}" \
  >/dev/null

if ! security find-identity -v -p codesigning "${keychain}" | grep -Fq "\"${identity}\""; then
  printf 'The certificate was imported but is not a valid code-signing identity.\n' >&2
  exit 1
fi

printf 'Created stable signing identity: %s\n' "${identity}"
