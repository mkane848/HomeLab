#!/usr/bin/env bash
# catalog.sh — Model catalog library (source me, don't execute)
#
# Single source of truth for the models we can run across the fleet.
# Data lives in catalog.tsv (tab-separated, so bash AND PowerShell can parse it):
#
#   tag  size_gb  class  ctx  groups  hosts  desc
#
#   class  -> fit | edge | offload   (VRAM fit on a 16GB host)
#   groups -> comma-separated install groups (autocomplete, coder, reasoner,
#             general, creative, embed)
#   hosts  -> comma-separated eligible machines (server, desktop, node3)
#
# Usage from bash:
#   source models/catalog.sh
#   catalog_list                       # full table
#   catalog_list coder                 # only the coder group
#   catalog_match "qwen"               # tags containing a pattern
#   catalog_field <tag> <col>          # e.g. catalog_field qwen2.5-coder:7b ctx

CATALOG_TSV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/catalog.tsv"

CATALOG_COLS=(tag size_gb class ctx groups hosts desc)

catalog_line() {
    # catalog_line <tag>  -> the raw TSV record for a tag (or empty)
    awk -F '\t' -v t="$1" '$1 == t { print }' "$CATALOG_TSV"
}

catalog_field() {
    # catalog_field <tag> <col>  -> value of a column for a tag
    local idx
    idx=$(catalog_col_index "$2") || return 1
    catalog_line "$1" | awk -F '\t' -v i="$idx" '{ print $i }'
}

catalog_col_index() {
    local i
    for i in "${!CATALOG_COLS[@]}"; do
        [[ "${CATALOG_COLS[$i]}" == "$1" ]] && { echo $((i + 1)); return 0; }
    done
    return 1
}

catalog_has_tag() {
    [[ -n "$(catalog_line "$1")" ]]
}

catalog_group_exists() {
    # Any row whose groups column contains the given group
    awk -F '\t' -v g="$1" 'NR>1 { n=split($5,a,","); for (i=1;i<=n;i++) if (a[i]==g) found=1 } END { exit !found }' "$CATALOG_TSV"
}

catalog_match() {
    # catalog_match <pattern>  -> rows whose tag contains the pattern
    awk -F '\t' -v p="$1" 'NR>1 && $1 ~ p { print }' "$CATALOG_TSV"
}

catalog_group_rows() {
    # catalog_group_rows <group>  -> rows that belong to an install group
    awk -F '\t' -v g="$1" 'NR>1 { n=split($5,a,","); for (i=1;i<=n;i++) if (a[i]==g) { print; break } }' "$CATALOG_TSV"
}

catalog_host_rows() {
    # catalog_host_rows <host>  -> rows eligible for a machine
    awk -F '\t' -v h="$1" 'NR>1 { n=split($6,a,","); for (i=1;i<=n;i++) if (a[i]==h) { print; break } }' "$CATALOG_TSV"
}

catalog_print_rows() {
    # catalog_print_rows (rows on stdin)  -> aligned, human-readable table
    printf "%-24s %-8s %-10s %-7s %-32s %s\n" \
        "TAG" "SIZE" "CLASS" "CTX" "GROUPS" "DESCRIPTION"
    printf "%-24s %-8s %-10s %-7s %-32s %s\n" \
        "------------------------" "--------" "----------" "-------" "--------------------------------" "-----------"
    while IFS=$'\t' read -r tag size_gb class ctx groups hosts desc; do
        printf "%-24s %-8s %-10s %-7s %-32s %s\n" \
            "$tag" "${size_gb}G" "$class" "${ctx}k" "$groups" "$desc"
    done
}

catalog_list() {
    # catalog_list [group]  -> list all models, or a single group
    local group="${1:-}"
    if [[ -n "$group" ]]; then
        if ! catalog_group_exists "$group"; then
            echo "No catalog group named: $group" >&2
            echo "Available groups: autocomplete coder reasoner general creative embed" >&2
            return 1
        fi
        catalog_group_rows "$group" | catalog_print_rows
    else
        awk -F '\t' 'NR>1 { print }' "$CATALOG_TSV" | catalog_print_rows
    fi
}

catalog_groups() {
    # All distinct group names in the catalog
    awk -F '\t' 'NR>1 { n=split($5,a,","); for (i=1;i<=n;i++) if (!seen[a[i]]++) printf "%s ", a[i] }' "$CATALOG_TSV"
    echo ""
}