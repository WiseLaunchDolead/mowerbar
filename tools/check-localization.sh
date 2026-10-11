#!/bin/zsh
# Fails when a user-facing text in the sources has no French translation (or a translation is no longer used).
set -eu
ROOT="${0:A:h:h}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/core" "$WORK/app"
(cd "$WORK/core" && xcrun swiftc -parse-as-library -module-name MowerBarCore -emit-module -emit-module-path "$WORK/core/MowerBarCore.swiftmodule" \
    -emit-localized-strings -emit-localized-strings-path "$WORK/core" "$ROOT"/Sources/MowerBarCore/*.swift -c 2>/dev/null)
(cd "$WORK/app" && xcrun swiftc -parse-as-library -module-name MowerBar -I "$WORK/core" \
    -emit-localized-strings -emit-localized-strings-path "$WORK/app" "$ROOT"/Sources/MowerBar/*.swift -c 2>/dev/null)
python3 - "$WORK" "$ROOT/Resources/fr.lproj/Localizable.strings" <<'PY'
import glob, json, subprocess, sys
used = {e["key"] for f in glob.glob(sys.argv[1] + "/*/*.stringsdata")
        for entries in json.load(open(f)).get("tables", {}).values() for e in entries}
used -= {"MowerBar"}  # product name, never translated
translated = set(json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", sys.argv[2]], check=True, capture_output=True).stdout))
missing, unused = sorted(used - translated), sorted(translated - used)
for k in missing: print("missing:", k)
for k in unused: print("unused: ", k)
print(f"{len(used)} texts, {len(missing)} missing, {len(unused)} unused")
sys.exit(1 if missing or unused else 0)
PY
