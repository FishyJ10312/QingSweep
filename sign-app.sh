#!/bin/zsh
set -euo pipefail
app_path="$1"
# A supplied Developer ID identity takes precedence. Never silently replace an existing identity.
if [[ -n "${QINGSWEEP_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$QINGSWEEP_SIGNING_IDENTITY" "$app_path"
  codesign --verify --deep --strict "$app_path"
  exit 0
fi
signing_dir="$HOME/Library/Application Support/QingSweep Signing"
keychain_path="$signing_dir/signing.keychain-db"
password_path="$signing_dir/keychain-password"
certificate_path="$signing_dir/signing.cer"
mkdir -p "$signing_dir"
chmod 700 "$signing_dir"
if [[ ! -f "$keychain_path" ]]; then
  umask 077
  openssl rand -hex 32 > "$password_path"
  signing_password="$(cat "$password_path")"
  signing_tmp="$(mktemp -d "$signing_dir/bootstrap.XXXXXX")"
  trap 'rm -rf "$signing_tmp"' EXIT
  cat > "$signing_tmp/extensions.cnf" <<'CONF'
[req]
distinguished_name=dn
x509_extensions=signing
prompt=no
[dn]
CN=QingSweep Local Signing
O=Personal Local Build
[signing]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONF
  openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -config "$signing_tmp/extensions.cnf" -keyout "$signing_tmp/key.pem" -out "$signing_tmp/cert.pem" >/dev/null 2>&1
  openssl x509 -in "$signing_tmp/cert.pem" -outform der -out "$certificate_path"
  /usr/bin/openssl pkcs12 -export -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -inkey "$signing_tmp/key.pem" -in "$signing_tmp/cert.pem" -name 'QingSweep Local Signing' -out "$signing_tmp/identity.p12" -passout "file:$password_path" >/dev/null 2>&1
  security create-keychain -p "$signing_password" "$keychain_path" >/dev/null
  security unlock-keychain -p "$signing_password" "$keychain_path"
  security import "$signing_tmp/identity.p12" -k "$keychain_path" -P "$signing_password" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$signing_password" "$keychain_path" >/dev/null 2>&1
fi
[[ -f "$password_path" && -f "$certificate_path" ]] || { print -u2 'Signing identity incomplete; refusing to generate a different identity.'; exit 1; }
signing_password="$(cat "$password_path")"
security unlock-keychain -p "$signing_password" "$keychain_path"
certificate_hash="$(openssl x509 -inform der -in "$certificate_path" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Contents/Info.plist")"
codesign --force --options runtime --timestamp=none --keychain "$keychain_path" --sign "$certificate_hash" --requirements "=designated => identifier \"$bundle_identifier\" and certificate leaf = H\"$certificate_hash\"" "$app_path"
codesign --verify --deep --strict "$app_path"
print 'Signed with the persistent local identity. This is not Apple notarization.'
