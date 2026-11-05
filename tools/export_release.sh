#!/usr/bin/env bash
# Copy the files for the public (MiSTer-devel) repository into DEST: an allow-list of committed files, with no
# ROMs, software or reference material. Then check that no file in DEST is one of the ROM images in rom/.
#   tools/export_release.sh DEST
set -eu
cd "$(dirname "$0")/.."
DEST=${1:?usage: tools/export_release.sh DEST}
[ -e "$DEST" ] && { echo "$DEST exists; give a new directory"; exit 1; }

# committed files under these paths, minus the exclusions below
KEEP='^(PC6001\.(sv|qpf|qsf|sdc|srf)|files\.qip|clean\.bat|LICENSE|Readme\.md|\.gitignore|sys/|rtl/|tools/|verilator/|docs/CASSETTE_STATUS\.md|docs/RELEASE_NOTES\.md)'
# test.d88 holds sectors of a third-party BASIC program; the tests that use it also need refs/ (TAPES=1)
DROP='^verilator/tests/disk/'

mkdir -p "$DEST"
git ls-files | grep -E "$KEEP" | grep -v -E "$DROP" | while IFS= read -r f; do
	mkdir -p "$DEST/$(dirname "$f")"; cp -p "$f" "$DEST/$f"
done

# the newest release build
rbf=$(git ls-files 'releases/PC6001_*.rbf' | sort | tail -1)
mkdir -p "$DEST/releases"; cp -p "$rbf" "$DEST/releases/"

# no ROM image may be in the export
bad=0
if [ -d rom ]; then
	roms=$(find rom -type f -exec shasum {} + | awk '{print $1}' | sort -u)
	while read -r h f; do
		if grep -qx "$h" <<< "$roms"; then echo "ROM image in export: $f"; bad=1; fi
	done < <(find "$DEST" -type f -exec shasum {} +)
fi
[ $bad = 0 ] || { echo "export has ROM images; not done"; exit 1; }
echo "exported $(find "$DEST" -type f | wc -l | tr -d ' ') files to $DEST (release build: $(basename "$rbf"))"
