#!/bin/bash
set -e

# Creates a new MyPlugIn effect from Templates/NewPlugIn and adds it to
# Package.swift, MyPlugInCatalog and the host app (Hosts/MyPlugInHost).
#
#   Tools/new-plugin.sh MyChorus Chrs
#
# Name: "My" + a capital letter + letters/digits. Its part after "My"
# (Chorus) prefixes the effect's type names (ChorusKernel, ...), which keeps
# them apart inside MyDAW's single module.
# Subtype: four ASCII characters, unique among the effects (the AU
# component subtype; never change it once projects use the effect).

NAME="$1"
SUBTYPE="$2"
if [[ ! "$NAME" =~ ^My[A-Z][A-Za-z0-9]*$ ]] || [ ${#SUBTYPE} -ne 4 ]; then
    echo "Usage: $0 MyName Subt   (e.g. $0 MyChorus Chrs)" >&2
    exit 1
fi
PREFIX="${NAME#My}"

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
TEMPLATE="$ROOT/Templates/NewPlugIn"
cd "$ROOT"

if [ -e "Sources/$NAME" ]; then
    echo "Sources/$NAME already exists" >&2
    exit 1
fi
if grep -rq "MyFXFourCC(\"$SUBTYPE\")" Sources; then
    echo "Subtype '$SUBTYPE' is already used" >&2
    exit 1
fi

# Copy the template, renaming files and identifiers.
copy() {
    local from="$1" to="$2"
    mkdir -p "$to"
    for file in "$from"/*.swift; do
        local base
        base="$(basename "$file")"
        base="${base//MyTemplate/$NAME}"
        base="${base//Template/$PREFIX}"
        sed -e "s/MyFXFourCC(\"Tmpl\")/MyFXFourCC(\"$SUBTYPE\")/g" \
            -e "s/'Tmpl'/'$SUBTYPE'/g" \
            -e "s/MyTemplate/$NAME/g" \
            -e "s/Template/$PREFIX/g" \
            -e "s/TEMPLATE/$(echo "$PREFIX" | tr '[:lower:]' '[:upper:]')/g" \
            "$file" > "$to/$base"
    done
}
copy "$TEMPLATE/Sources/MyTemplate" "Sources/$NAME"
copy "$TEMPLATE/Tests/MyTemplateTests" "Tests/${NAME}Tests"

# Register it: Package.swift and the catalog.
sed -i '' "s|^    // new-plugin.sh: plug-ins|    \"$NAME\",\\
    // new-plugin.sh: plug-ins|" Package.swift
CATALOG="Sources/MyPlugInCatalog/MyPlugInCatalog.swift"
sed -i '' "s|^// new-plugin.sh: imports|#if canImport($NAME)\\
import $NAME\\
#endif\\
// new-plugin.sh: imports|" "$CATALOG"
sed -i '' "s|^        // new-plugin.sh: catalog|        ${NAME}AudioUnit.self,\\
        // new-plugin.sh: catalog|" "$CATALOG"

# The AUv3 extension for other hosts.
python3 -I "$ROOT/Tools/make-host-project.py"

echo "Created $NAME ('aufx' '$SUBTYPE'):"
echo "  Sources/$NAME, Tests/${NAME}Tests; added to Package.swift, $CATALOG and Hosts/MyPlugInHost"
echo "Next:"
echo "  1. ${PREFIX}Parameter.swift: the parameters (addresses are permanent)"
echo "  2. ${PREFIX}Kernel.swift: the signal path; ${NAME}Editor.swift: faders and tapers"
echo "  3. swift test; then MyDAW/scripts/sync-myplugin.sh and rebuild MyDAW"
