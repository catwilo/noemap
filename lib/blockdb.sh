#!/bin/sh
# blockdb.sh -- pure block-format key/value database helpers.
#
# Format: one block per record, fields as "key: value" lines, blocks
# separated by exactly one blank line. Example:
#
#   alias: tx1
#   ip: 10.43.185.144
#   user: u
#   port: 8022
#   hostkey: SHA256:...
#
#   alias: tx2
#   ip: 10.43.185.193
#   user: u
#   port: 8022
#   hostkey:
#
# No knowledge of domain concepts (node_id, alias, devices vs registry)
# lives here -- callers pass field names and values explicitly.

# blockdb_get db_path match_key match_value -- prints the full matching
# block (all its "key: value" lines), or nothing if not found.
blockdb_get() {
    _bg_db="$1"; _bg_key="$2"; _bg_val="$3"
    [ -f "$_bg_db" ] || return 0
    awk -v k="$_bg_key" -v v="$_bg_val" '
        BEGIN { RS=""; FS="\n" }
        {
            match_found = 0
            for (i = 1; i <= NF; i++) {
                line = $i
                colon = index(line, ":")
                if (colon == 0) continue
                fk = substr(line, 1, colon - 1)
                fv = substr(line, colon + 2)
                if (fk == k && fv == v) { match_found = 1 }
            }
            if (match_found) { print; exit }
        }
    ' "$_bg_db" 2>/dev/null
}

# blockdb_field block_text field_name -- extracts a field value from an
# already-fetched block (as returned by blockdb_get).
blockdb_field() {
    _bf_block="$1"; _bf_field="$2"
    printf '%s\n' "$_bf_block" | awk -v f="$_bf_field" '
        {
            colon = index($0, ":")
            if (colon == 0) next
            fk = substr($0, 1, colon - 1)
            fv = substr($0, colon + 2)
            if (fk == f) { print fv; exit }
        }
    '
}

# blockdb_upsert db_path match_key match_value block_text -- replaces the
# matching block if found, else appends block_text as a new block.
# Atomic: writes to a temp file, then mv.
blockdb_upsert() {
    _bu_db="$1"; _bu_key="$2"; _bu_val="$3"; _bu_block="$4"
    _bu_tmp="$(mktemp "${TMPDIR:-/tmp}/blockdb.XXXXXX")"

    if [ -f "$_bu_db" ] && [ -s "$_bu_db" ]; then
        awk -v k="$_bu_key" -v v="$_bu_val" '
            BEGIN { RS=""; FS="\n"; first=1 }
            {
                match_found = 0
                for (i = 1; i <= NF; i++) {
                    line = $i
                    colon = index(line, ":")
                    if (colon == 0) continue
                    fk = substr(line, 1, colon - 1)
                    fv = substr(line, colon + 2)
                    if (fk == k && fv == v) { match_found = 1 }
                }
                if (!match_found) {
                    if (!first) print ""
                    print
                    first = 0
                }
            }
        ' "$_bu_db" > "$_bu_tmp" 2>/dev/null
    fi

    if [ -s "$_bu_tmp" ]; then
        printf '\n%s\n' "$_bu_block" >> "$_bu_tmp"
    else
        printf '%s\n' "$_bu_block" >> "$_bu_tmp"
    fi

    mv -f "$_bu_tmp" "$_bu_db"
}

# blockdb_remove db_path match_key match_value -- removes the matching
# block entirely. Atomic.
blockdb_remove() {
    _br_db="$1"; _br_key="$2"; _br_val="$3"
    [ -f "$_br_db" ] || return 0
    _br_tmp="$(mktemp "${TMPDIR:-/tmp}/blockdb.XXXXXX")"
    awk -v k="$_br_key" -v v="$_br_val" '
        BEGIN { RS=""; FS="\n"; first=1 }
        {
            match_found = 0
            for (i = 1; i <= NF; i++) {
                line = $i
                colon = index(line, ":")
                if (colon == 0) continue
                fk = substr(line, 1, colon - 1)
                fv = substr(line, colon + 2)
                if (fk == k && fv == v) { match_found = 1 }
            }
            if (!match_found) {
                if (!first) print ""
                print
                first = 0
            }
        }
    ' "$_br_db" > "$_br_tmp" 2>/dev/null
    mv -f "$_br_tmp" "$_br_db"
}

# blockdb_max_field db_path field_name -- max NUMERIC value of field_name
# across all blocks. Non-numeric or missing values are ignored. Prints 0
# if the db is empty/missing or no block has a numeric value for the field.
blockdb_max_field() {
    _bm_db="$1"; _bm_field="$2"
    [ -f "$_bm_db" ] || { printf '0\n'; return 0; }
    awk -v f="$_bm_field" '
        BEGIN { RS=""; FS="\n"; mx=0 }
        {
            for (i = 1; i <= NF; i++) {
                line = $i
                colon = index(line, ":")
                if (colon == 0) continue
                fk = substr(line, 1, colon - 1)
                fv = substr(line, colon + 2)
                if (fk == f && fv ~ /^[0-9]+$/) {
                    if (fv + 0 > mx) mx = fv + 0
                }
            }
        }
        END { print mx }
    ' "$_bm_db" 2>/dev/null
}

# blockdb_list db_path -- prints all blocks verbatim (for display/listing).
blockdb_list() {
    _bl_db="$1"
    [ -f "$_bl_db" ] || return 0
    cat "$_bl_db"
}
