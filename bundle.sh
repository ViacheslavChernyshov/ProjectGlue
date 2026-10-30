#!/usr/bin/env bash
# ==============================================================================
# Codebase Bundler for AI Analysis (Linux / macOS / WSL)
# Splits codebase into atomic volumes <= limit (default 500 KB) without splitting files
#
# Usage:
#   ./bundle.sh                           (Current directory, 500 KB per volume)
#   ./bundle.sh [target_folder]           (Specified directory, 500 KB per volume)
#   ./bundle.sh [target_folder] [max_kb]  (Specified directory and custom KB limit)
# ==============================================================================
set -euo pipefail

# 1. Target Directory and Volume Size Configuration
TARGET="${1:-$(pwd)}"
if [ ! -d "$TARGET" ]; then
    echo -e "\033[0;31m[ERROR] Target directory does not exist: $TARGET\033[0m" >&2
    exit 1
fi

TARGET_DIR="$(cd "$TARGET" && pwd)"
PROJECT_NAME="$(basename "$TARGET_DIR")"

# Volume size limit (default: 500 KB)
MAX_KB="${2:-500}"
if ! [[ "$MAX_KB" =~ ^[0-9]+$ ]] || [ "$MAX_KB" -le 0 ]; then
    echo -e "\033[0;33m[WARN] Invalid max size '$MAX_KB'. Defaulting to 500 KB.\033[0m" >&2
    MAX_KB=500
fi
MAX_PART_BYTES=$((MAX_KB * 1024))

echo -e "\033[0;36m==========================================================\033[0m"
echo -e "\033[0;36m Codebase Bundler for AI Analysis (ProjectGlue)\033[0m"
echo -e "\033[1;37m Project:   ${PROJECT_NAME}\033[0m"
echo -e "\033[1;37m Directory: ${TARGET_DIR}\033[0m"
echo -e "\033[1;37m Part Max:  ${MAX_KB} KB (Atomic file mode: never splits files)\033[0m"
echo -e "\033[0;36m==========================================================\033[0m"

# 2. Ignored patterns
IGNORED_DIRS="(\.git|\.svn|\.hg|\.idea|\.vscode|\.eclipse|\.settings|node_modules|\.next|\.nuxt|\.turbo|dist|build|out|coverage|target|\.gradle|\.m2|bin|obj|Debug|Release|venv|\.venv|env|\.env|__pycache__|\.pytest_cache|\.mypy_cache|\.tox)"

IGNORED_EXTS="exe|dll|so|dylib|bin|obj|o|a|lib|class|jar|war|ear|pyc|pyo|pyd|zip|tar|gz|tgz|7z|rar|bz2|xz|png|jpg|jpeg|gif|ico|webp|bmp|tiff|psd|ai|mp3|mp4|wav|ogg|flac|avi|mov|wmv|mkv|webm|pdf|docx|xlsx|pptx|doc|xls|ppt|woff|woff2|ttf|eot|otf|db|sqlite|sqlite3|log|lock|lockb"

IGNORED_FILES="\.env|\.env\..*|package-lock\.json|yarn\.lock|poetry\.lock|Cargo\.lock|composer\.lock|pnpm-lock\.yaml|\.DS_Store|Thumbs\.db|bundle\.bat|bundle\.sh|.*_bundle.*\.txt|.*_bundle.*\.md|.*_part[0-9]+\.txt|.*_part[0-9]+\.md"

# Read custom .bundleignore if present
CUSTOM_IGNORE_PATTERNS=()
if [ -f "${TARGET_DIR}/.bundleignore" ]; then
    echo -e "\033[0;33m[INFO] Loading custom rules from .bundleignore\033[0m"
    while IFS= read -r line || [ -n "$line" ]; do
        line_clean="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -n "$line_clean" ] && [[ ! "$line_clean" =~ ^# ]]; then
            CUSTOM_IGNORE_PATTERNS+=("$line_clean")
        fi
    done < "${TARGET_DIR}/.bundleignore"
fi

# 3. Helper Functions
is_binary() {
    local file="$1"
    if command -v file >/dev/null 2>&1; then
        local mime
        mime="$(file -b --mime-encoding "$file" 2>/dev/null || true)"
        if [ "$mime" = "binary" ]; then
            return 0
        fi
        return 1
    fi
    # Fallback if file command is missing: check null byte via tr
    local orig_bytes stripped_bytes
    orig_bytes=$(head -c 1024 "$file" 2>/dev/null | wc -c | tr -d ' ')
    stripped_bytes=$(head -c 1024 "$file" 2>/dev/null | tr -d '\000' | wc -c | tr -d ' ')
    if [ "$orig_bytes" -ne "$stripped_bytes" ]; then
        return 0
    fi
    return 1
}

get_file_size() {
    local file="$1"
    wc -c < "$file" 2>/dev/null | tr -d ' '
}

detect_language() {
    local ext="$1"
    case "$ext" in
        java) echo "java" ;;
        py) echo "python" ;;
        js|mjs|cjs) echo "javascript" ;;
        jsx) echo "javascript" ;;
        ts|mts|cts) echo "typescript" ;;
        tsx) echo "typescript" ;;
        html|htm) echo "html" ;;
        css|scss|sass) echo "css" ;;
        json) echo "json" ;;
        xml) echo "xml" ;;
        yml|yaml) echo "yaml" ;;
        sql) echo "sql" ;;
        sh|bash) echo "bash" ;;
        bat|cmd) echo "batch" ;;
        ps1) echo "powershell" ;;
        c|h) echo "c" ;;
        cpp|hpp|cc|cxx) echo "cpp" ;;
        cs) echo "csharp" ;;
        go) echo "go" ;;
        rs) echo "rust" ;;
        php) echo "php" ;;
        rb) echo "ruby" ;;
        kt|kts) echo "kotlin" ;;
        swift) echo "swift" ;;
        md) echo "markdown" ;;
        txt) echo "text" ;;
        *) echo "text" ;;
    esac
}

should_ignore() {
    local rel_path="$1"
    local file_name
    file_name="$(basename "$rel_path")"

    # Match ignored file names (and bundle outputs)
    if echo "$file_name" | grep -Eq "^($IGNORED_FILES)$"; then
        return 0
    fi

    # Match secret keys
    if [[ "$file_name" =~ \.(pem|key|pfx)$ ]] || [[ "$file_name" =~ ^id_rsa ]]; then
        return 0
    fi

    # Match ignored extensions
    local ext="${file_name##*.}"
    if [ "$ext" != "$file_name" ] && echo "$ext" | grep -Eqi "^($IGNORED_EXTS)$"; then
        return 0
    fi

    # Match directory components
    if echo "$rel_path" | grep -Eq "(^|/)(${IGNORED_DIRS})(/|$)"; then
        return 0
    fi

    # Match custom ignore patterns
    for pat in "${CUSTOM_IGNORE_PATTERNS[@]:-}"; do
        if [ -n "$pat" ] && [[ "$rel_path" == *"$pat"* || "$file_name" == *"$pat"* ]]; then
            return 0
        fi
    done

    return 1
}

# 4. Collect candidate relative paths
echo -e "\033[0;37m[*] Scanning project files...\033[0m"
cd "$TARGET_DIR"

CANDIDATES=()
IS_GIT=0

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    IS_GIT=1
    echo -e "\033[0;32m[+] Git repository detected: utilizing .gitignore\033[0m"
    while IFS= read -r file; do
        [ -n "$file" ] && CANDIDATES+=("$file")
    done < <(git ls-files -co --exclude-standard)
else
    echo -e "\033[0;33m[+] Standard traversal (Git not found or not a git repo)\033[0m"
    while IFS= read -r file; do
        clean_file="${file#./}"
        [ -n "$clean_file" ] && CANDIDATES+=("$clean_file")
    done < <(find . -type f | sed 's|^\./||')
fi

# 5. Filter candidates
INCLUDED_FILES=()
SKIPPED_COUNT=0

for rel in "${CANDIDATES[@]}"; do
    full_path="${TARGET_DIR}/${rel}"
    [ ! -f "$full_path" ] && continue

    if should_ignore "$rel"; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    if is_binary "$full_path"; then
        echo -e "\033[1;30m    [SKIP BINARY]  $rel\033[0m"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    INCLUDED_FILES+=("$rel")
done

TOTAL_FILES=${#INCLUDED_FILES[@]}
echo -e "\033[0;32m[+] Found ${TOTAL_FILES} source files (Skipped: ${SKIPPED_COUNT} non-project/binary/ignored files)\033[0m"

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo -e "\033[0;33m[WARN] No files matched for bundling. Exiting.\033[0m"
    exit 0
fi

# Sort files alphabetically (preserves spaces safely)
SORTED_FILES=()
while IFS= read -r line; do
    [ -n "$line" ] && SORTED_FILES+=("$line")
done < <(printf '%s\n' "${INCLUDED_FILES[@]}" | sort)

# 6. Generate Full ASCII Directory Tree
generate_tree() {
    printf '%s/\n' "$PROJECT_NAME"
    printf '%s\n' "${SORTED_FILES[@]}" | awk '
    BEGIN { FS="/" }
    {
        depth = NF
        for (i = 1; i <= depth; i++) {
            path = ""
            for (j = 1; j <= i; j++) path = path (j > 1 ? "/" : "") $j
            if (!seen[path]++) {
                indent = ""
                for (k = 1; k < i; k++) indent = indent "|   "
                prefix = (i == depth) ? "+-- " : "|-- "
                suffix = (i < depth) ? "/" : ""
                print indent prefix $i suffix
            }
        }
    }'
}

TREE_OUTPUT="$(generate_tree)"

# 7. Pre-calculate Part Allocations (Chunk Planning without splitting files)
echo -e "\033[0;37m[*] Planning bundle volumes (Limit: ${MAX_KB} KB, Atomic file mode)...\033[0m"

TREE_BYTES=$(printf '%s\n' "$TREE_OUTPUT" | wc -c | tr -d ' ')
BASE_HEADER_BYTES=$((TREE_BYTES + 1200))

CURRENT_PART=1
CURRENT_PART_BYTES=$BASE_HEADER_BYTES
PART_COUNT_FILES=0
declare -a FILE_PART=()

for idx in "${!SORTED_FILES[@]}"; do
    rel="${SORTED_FILES[$idx]}"
    fsize="$(get_file_size "${TARGET_DIR}/${rel}")"
    block_bytes=$((fsize + 450))

    if [ $((CURRENT_PART_BYTES + block_bytes)) -gt "$MAX_PART_BYTES" ] && [ "$PART_COUNT_FILES" -gt 0 ]; then
        CURRENT_PART=$((CURRENT_PART + 1))
        CURRENT_PART_BYTES=$BASE_HEADER_BYTES
        PART_COUNT_FILES=0
    fi

    FILE_PART[$idx]=$CURRENT_PART
    CURRENT_PART_BYTES=$((CURRENT_PART_BYTES + block_bytes))
    PART_COUNT_FILES=$((PART_COUNT_FILES + 1))

    # If this single file was larger than MAX_PART_BYTES, isolate it in this volume
    if [ "$fsize" -gt "$MAX_PART_BYTES" ]; then
        fsize_kb=$(awk -v b="$fsize" 'BEGIN { printf "%.2f", b / 1024 }')
        echo -e "\033[0;33m    [NOTICE] Large file '$rel' (${fsize_kb} KB > ${MAX_KB} KB) allocated to standalone volume.\033[0m"
        CURRENT_PART=$((CURRENT_PART + 1))
        CURRENT_PART_BYTES=$BASE_HEADER_BYTES
        PART_COUNT_FILES=0
    fi
done

TOTAL_PARTS=$CURRENT_PART
if [ "$PART_COUNT_FILES" -eq 0 ] && [ "$TOTAL_PARTS" -gt 1 ]; then
    TOTAL_PARTS=$((TOTAL_PARTS - 1))
fi

echo -e "\033[0;32m[+] Codebase grouped into ${TOTAL_PARTS} volume(s).\033[0m"

# 8. Clean up past bundles for this project safely
find "$TARGET_DIR" -maxdepth 1 -type f \( -name "${PROJECT_NAME}_part*.txt" -o -name "${PROJECT_NAME}_bundle*.txt" \) -delete 2>/dev/null || true

# 9. Write Bundle Volumes
echo -e "\033[0;37m[*] Writing bundle files...\033[0m"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
CREATED_FILES=()
GLOBAL_FILE_INDEX=0

for (( p=1; p<=TOTAL_PARTS; p++ )); do
    PART_FILE="${TARGET_DIR}/${PROJECT_NAME}_part${p}.txt"
    TEMP_OUTPUT="${PART_FILE}.tmp"
    rm -f "$TEMP_OUTPUT"

    # Identify files for this part
    PART_FILES=()
    for idx in "${!SORTED_FILES[@]}"; do
        if [ "${FILE_PART[$idx]}" -eq "$p" ]; then
            PART_FILES+=("${SORTED_FILES[$idx]}")
        fi
    done

    PART_FILES_COUNT=${#PART_FILES[@]}

    # Write Volume Header
    cat <<EOF > "$TEMP_OUTPUT"
================================================================================
CODEBASE BUNDLE FOR AI ANALYSIS
Project:     ${PROJECT_NAME}
Volume:      Part ${p} of ${TOTAL_PARTS}
Date:        ${NOW}
Files Here:  ${PART_FILES_COUNT} in this volume (Total project files: ${TOTAL_FILES})
Max Limit:   ${MAX_KB} KB per volume (Atomic file mode: files are never split)
================================================================================

================================================================================
1. FULL PROJECT DIRECTORY STRUCTURE
================================================================================
${TREE_OUTPUT}

================================================================================
2. FILES IN THIS VOLUME (Part ${p} of ${TOTAL_PARTS})
================================================================================
EOF

    for (( i=0; i<PART_FILES_COUNT; i++ )); do
        pf="${PART_FILES[$i]}"
        fsize="$(get_file_size "${TARGET_DIR}/${pf}")"
        fsize_kb="$(awk -v bytes="$fsize" 'BEGIN { printf "%.2f", bytes / 1024 }')"
        printf "%3d. %s (%s KB)\n" "$((i + 1))" "$pf" "$fsize_kb" >> "$TEMP_OUTPUT"
    done

    cat <<EOF >> "$TEMP_OUTPUT"

================================================================================
3. SOURCE CODE FILES
================================================================================

EOF

    for (( local_idx=0; local_idx<PART_FILES_COUNT; local_idx++ )); do
        GLOBAL_FILE_INDEX=$((GLOBAL_FILE_INDEX + 1))
        rel="${PART_FILES[$local_idx]}"
        full_path="${TARGET_DIR}/${rel}"
        fname="$(basename "$rel")"
        ext="${fname##*.}"
        [ "$ext" = "$fname" ] && ext=""
        lang="$(detect_language "$ext")"
        fsize="$(get_file_size "$full_path")"
        fsize_kb="$(awk -v bytes="$fsize" 'BEGIN { printf "%.2f", bytes / 1024 }')"

        cat <<EOF >> "$TEMP_OUTPUT"
================================================================================
FILE [$((local_idx + 1))/${PART_FILES_COUNT} in Part ${p} | Overall ${GLOBAL_FILE_INDEX}/${TOTAL_FILES}]: ${rel}
LANGUAGE: ${lang} | SIZE: ${fsize_kb} KB
================================================================================
<file path="${rel}">
EOF

        if ! cat "$full_path" >> "$TEMP_OUTPUT" 2>/dev/null; then
            echo "/* [ERROR: Could not read file content: ${rel}] */" >> "$TEMP_OUTPUT"
        fi

        cat <<EOF >> "$TEMP_OUTPUT"
</file>

EOF
    done

    mv -f "$TEMP_OUTPUT" "$PART_FILE"

    ACTUAL_BYTES="$(get_file_size "$PART_FILE")"
    ACTUAL_KB="$(awk -v bytes="$ACTUAL_BYTES" 'BEGIN { printf "%.2f", bytes / 1024 }')"
    CREATED_FILES+=("${PROJECT_NAME}_part${p}.txt (${ACTUAL_KB} KB)")
done

echo ""
echo -e "\033[0;32m[SUCCESS] Bundle creation finished successfully!\033[0m"
echo -e "\033[0;36mGenerated ${#CREATED_FILES[@]} volume(s):\033[0m"
for cf in "${CREATED_FILES[@]}"; do
    echo -e "\033[1;37m  -> ${cf}\033[0m"
done
echo -e "\033[0;37mAll files were included atomically without splitting.\033[0m"
echo -e "\033[0;37mReady to feed into LLM (Gemini, Claude, GPT, DeepSeek, etc.)\033[0m"
