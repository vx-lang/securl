#!/bin/sh
# Refuse code that reads a password outside the files that must.
#
# A password goes out only through src/securl/auth.vx, which checks first that the request
# goes where the credentials may go (see `Credential` there). Vx has no private fields yet
# (docs/lang/visibility.md in Vx, section 7), so the compiler cannot stop another file from
# reading `password` and writing it into a request. Until it can, this check does: only these
# files may name a field whose name ends with `password`:
#
#   src/securl/auth.vx     makes the headers and the SOCKS messages that carry a password
#   src/securl/url.vx      parses the password of a URL, and writes it back for %{url}
#   src/securl/options.vx  parses `-E CERT:PASSWORD`
#   src/securl/netrc.vx    reads the entry of a `.netrc` file, for auth.vx
#
#   tools/check-secrets.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
if grep -rnE '\.[A-Za-z_]*password\b' src/securl src/cli src/disk src/main.vx \
    | grep -vE '^src/securl/(auth|url|options|netrc)\.vx:'; then
  echo "error: the lines above read a password outside src/securl/auth.vx." >&2
  echo "Send credentials with the functions of auth.vx, which check where they go." >&2
  exit 1
fi
