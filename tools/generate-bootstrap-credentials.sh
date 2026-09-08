#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${1:-$ROOT/Config/BootstrapCredentials.plist}"

umask 077
mkdir -p "$(dirname "$DESTINATION")"

/usr/bin/python3 - "$DESTINATION" <<'PY'
import os
import plistlib
import sys
import tempfile

destination = sys.argv[1]

def value(primary: str, simulator: str) -> str:
    return (os.environ.get(primary) or os.environ.get(simulator) or "").strip()

base_url = value("OFFICEADMIN_BASE_URL", "SIMCTL_CHILD_OFFICEADMIN_BASE_URL")
organization_id = value("OFFICEADMIN_ORGANIZATION_ID", "SIMCTL_CHILD_OFFICEADMIN_ORGANIZATION_ID")
api_key = value("OFFICEADMIN_API_KEY", "SIMCTL_CHILD_OFFICEADMIN_API_KEY")

missing = [
    name for name, current in (
        ("base URL", base_url),
        ("organization id", organization_id),
        ("API key", api_key),
    )
    if not current
]
if missing:
    print("ABORT: missing bootstrap credential input: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)

payload = {
    "baseURL": base_url,
    "organizationId": organization_id,
    "apiKey": api_key,
}

directory = os.path.dirname(destination)
fd, temporary = tempfile.mkstemp(prefix=".BootstrapCredentials.", suffix=".plist", dir=directory)
try:
    with os.fdopen(fd, "wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=True)
    os.chmod(temporary, 0o600)
    os.replace(temporary, destination)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY

printf 'Generated bootstrap credential plist at %s\n' "$DESTINATION"
