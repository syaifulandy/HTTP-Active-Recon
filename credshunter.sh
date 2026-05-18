#!/bin/bash

INPUT_FILE="targets.txt"
OUTPUT_DIR="output"
THREADS=3

# ✅ arg

while getopts "i:t:e:" opt; do
  case $opt in
    i) INPUT_FILE="$OPTARG" ;;
    t) THREADS="$OPTARG" ;;
    e) EXCLUDE_FILE="$OPTARG" ;;
  esac
done

filter_exclude() {
    if [[ -n "$EXCLUDE_REGEX" ]]; then
        grep -Ev "$EXCLUDE_REGEX"
    else
        cat
    fi
}

export -f filter_exclude


EXCLUDE_REGEX=""

if [[ -f "$EXCLUDE_FILE" ]]; then
    echo "[INFO] loading exclude list: $EXCLUDE_FILE"
    EXCLUDE_REGEX=$(sed 's/^[ \t]*//;s/[ \t]*$//' "$EXCLUDE_FILE" | grep -v '^$' | tr '\n' '|' | sed 's/|$//')
fi

export EXCLUDE_REGEX


if [[ ! -f "$INPUT_FILE" ]]; then
  echo "[!] File tidak ditemukan: $INPUT_FILE"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "[START] CREDS HUNTER"

sanitize_filename() {
    echo "$1" | sed 's|https\?://||' | sed 's|[^a-zA-Z0-9]|_|g'
}

export -f sanitize_filename


crawl_target() {

    URL=$1
    DOMAIN=$(echo $URL | sed 's|https\?://||' | cut -d/ -f1)    
    TARGET_DIR="$OUTPUT_DIR/$DOMAIN"
    mkdir -p "$TARGET_DIR/files"

    FILE="$TARGET_DIR/katana.jsonl"


    echo "[RUNNING] $DOMAIN"

    # ✅ KATANA FULL
    katana -u "$URL" \
        -d 5 \
        -jc \
        -jsl \
        -kf all \
        -hl \
        -xhr \
        -system-chrome \
        -system-chrome-path /usr/bin/chromium \
        -no-sandbox \
        -j \
        -silent \
        -ob -or \
        -o "$FILE" \
        > /dev/null 2>&1

    mkdir -p "$OUTPUT_DIR/$DOMAIN"

    echo "[EXTRACT] $DOMAIN"

    # ✅ extract semua URL
    
    jq -r '
      .request.endpoint?,
      .url?,
      (.xhr[]?.url)
    ' "$FILE" 2>/dev/null \
    | grep -v '^null$' \
    | sort -u \
    | filter_exclude \
    > "$TARGET_DIR/urls.txt"

    # ✅ PARAMETER MINING 🔥
    grep -E "\?.*=" "$TARGET_DIR/urls.txt" \
     | filter_exclude \
     > "$TARGET_DIR/params.txt"

    sed -E 's/\?.*/?FUZZ=1/' "$TARGET_DIR/params.txt" \
     | filter_exclude \
     | sort -u > "$TARGET_DIR/fuzz.txt"

    echo "[PARAM] $(wc -l < "$TARGET_DIR/params.txt" 2>/dev/null || echo 0) param found"
    

    # ✅ DOWNLOAD CLEAN FILE 🔥
    echo "[DOWNLOAD] $DOMAIN"

    COUNT=0

    while read -r link; do
        echo "$link" | filter_exclude | grep -q . || continue

        [[ "$link" =~ \.(png|jpg|jpeg|gif|css|svg|woff|ico)$ ]] && continue

        NAME=$(echo "$link" | sed 's|https\?://||' | sed 's|[^a-zA-Z0-9]|_|g')

        if [[ "$link" =~ \.js($|\?) ]]; then
            EXT=".js"
        else
            EXT=".html"
        fi

        STATUS=$(curl -m 10 -s -o /dev/null -w "%{http_code}" "$link")

        if [[ "$STATUS" == "200" ]]; then
            curl -s "$link" -o "$TARGET_DIR/files/$NAME$EXT"
            ((COUNT++))
        fi

    done < "$TARGET_DIR/urls.txt"

    # ✅ ENDPOINT PARSING (UPGRADED REGEX)

    
    grep -rhoE "(https?://[^\"' ]+|/[a-zA-Z0-9/_-]{3,})" "$TARGET_DIR/files" "$TARGET_DIR"/*.html 2>/dev/null \
    | grep -vE "\.(png|jpg|css|svg)" \
    | filter_exclude \
    | sort -u > "$TARGET_DIR/endpoints.txt"



    # ✅ HIGH VALUE 🔥
    
    grep -Ei "create|update|delete|admin|login|auth|debug|api" \
    "$TARGET_DIR/endpoints.txt" \
    > "$TARGET_DIR/highvalue.txt"



    # ✅ REQUEST LIST (BURP/FFUF READY) 🔥
    
    > "$TARGET_DIR/requests.txt"

    while read -r url; do
        echo "$url" | filter_exclude | grep -q . || continue
        echo "GET $url" >> "$TARGET_DIR/requests.txt"
    done < "$TARGET_DIR/urls.txt"



    # ✅ SENSITIVE DATA 🔥

    # ✅ base secret extraction (key + value)

    grep -rHoEi "(api[_-]?key|token|secret|password|jwt|bearer)[\"'\s:=]+[a-zA-Z0-9_\-\.=#:+/@$]{6,}" \
    "$TARGET_DIR/files" "$TARGET_DIR"/*.html 2>/dev/null \
    > "$TARGET_DIR/secrets.txt"


    grep -rHoE "eyJ[a-zA-Z0-9_\-\.=]+" "$TARGET_DIR" 2>/dev/null \
     >> "$TARGET_DIR/secrets.txt"

    # ✅ Authorization header (ambil full token)
    grep -rHoEi "Authorization[\"' :]+Bearer[ ]+[^\"'[:space:]]+" \
    "$TARGET_DIR/files" "$TARGET_DIR"/*.html 2>/dev/null \
    >> "$TARGET_DIR/secrets.txt"


    sort -u "$TARGET_DIR/secrets.txt" \
     -o "$TARGET_DIR/secrets.txt"

    echo "[DONE] $DOMAIN"
    echo "  URLs        : $(wc -l < "$TARGET_DIR/urls.txt" 2>/dev/null || echo 0)"
    echo "  params      : $(wc -l < "$TARGET_DIR/params.txt" 2>/dev/null || echo 0)"
    echo "  endpoints   : $(wc -l < "$TARGET_DIR/endpoints.txt" 2>/dev/null || echo 0)"
    echo "  highvalue   : $(wc -l < "$TARGET_DIR/highvalue.txt" 2>/dev/null || echo 0)"
    echo "  files       : $COUNT"
    echo "-----------------------------"

}

export -f crawl_target
export OUTPUT_DIR sanitize_filename

cat "$INPUT_FILE" | xargs -P $THREADS -I {} bash -c 'crawl_target "$@"' _ {}


echo "[GLOBAL] merging all secrets"

> "$OUTPUT_DIR/ALL-SECRETS.txt"

find "$OUTPUT_DIR" -type f -name "secrets.txt" | while read -r file; do
    cat "$file" >> "$OUTPUT_DIR/ALL-SECRETS-RAW.txt"
done

sort -u "$OUTPUT_DIR/ALL-SECRETS-RAW.txt" > "$OUTPUT_DIR/ALL-SECRETS.txt"

rm "$OUTPUT_DIR/ALL-SECRETS-RAW.txt"

echo "[GLOBAL] done: $OUTPUT_DIR/ALL-SECRETS.txt"

echo "[GLOBAL] grouping secrets"

awk -F':' '
{
    file=$1

    # ✅ ambil semua setelah field pertama
    value=substr($0, index($0,$2))

    if (!seen[file,value]++) {
        data[file]=data[file]"\n  - "value
    }
}
END {
    for (f in data) {
        print "[Source] "f data[f]"\n"
    }
}
' "$OUTPUT_DIR/ALL-SECRETS.txt" \
> "$OUTPUT_DIR/ALL-SECRETS-GROUPED.txt"

echo "[GLOBAL] grouped output: ALL-SECRETS-GROUPED.txt"


echo "[✓] DONE - HUNT READY"

echo "[REPORT] generating INTERACTIVE dashboard..."

REPORT="$OUTPUT_DIR/report.html"

cat <<EOF > "$REPORT"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>CredsHunter Report</title>

<style>
body {
  background: #0d1117;
  color: #c9d1d9;
  font-family: monospace;
  padding: 20px;
}

h1 { color: #ff4d4d; }

input {
  width: 100%;
  padding: 10px;
  margin-bottom: 20px;
  background: #161b22;
  border: none;
  color: white;
  border-radius: 8px;
}

.card {
  background: #161b22;
  border-radius: 12px;
  padding: 15px;
  margin-bottom: 20px;
  transition: 0.3s;
}

.card:hover {
  transform: scale(1.01);
}

.badge {
  display: inline-block;
  padding: 4px 8px;
  border-radius: 6px;
  margin: 5px;
  font-size: 12px;
}

.good { background: #238636; }
.warn { background: #9e6a03; }
.bad  { background: #da3633; }

pre {
  background: #0d1117;
  padding: 10px;
  border-radius: 8px;
  max-height: 200px;
  overflow: auto;
}
</style>

<script>
function searchDomain() {
  let input = document.getElementById("search").value.toLowerCase();
  let cards = document.getElementsByClassName("card");

  for (let i = 0; i < cards.length; i++) {
    let text = cards[i].innerText.toLowerCase();
    cards[i].style.display = text.includes(input) ? "block" : "none";
  }
}
</script>

</head>

<body>

<h1>CredsHunter Interactive Report</h1>
<p>Generated: $(date)</p>

<input type="text" id="search" onkeyup="searchDomain()" placeholder="Search domain / endpoint / secret...">

EOF

for d in "$OUTPUT_DIR"/*; do

  [ ! -d "$d" ] && continue

  DOMAIN=$(basename "$d")

  URL_COUNT=$(wc -l < "$d/urls.txt" 2>/dev/null || echo 0)
  PARAM_COUNT=$(wc -l < "$d/params.txt" 2>/dev/null || echo 0)
  END_COUNT=$(wc -l < "$d/endpoints.txt" 2>/dev/null || echo 0)
  SECRET_COUNT=$(wc -l < "$d/secrets.txt" 2>/dev/null || echo 0)

  BADGE_CLASS="good"
  [ "$SECRET_COUNT" -gt 0 ] && BADGE_CLASS="bad"

  echo "<div class='card'>" >> "$REPORT"
  echo "<h2>$DOMAIN</h2>" >> "$REPORT"

  echo "<span class='badge good'>URLs: $URL_COUNT</span>" >> "$REPORT"
  echo "<span class='badge warn'>Params: $PARAM_COUNT</span>" >> "$REPORT"
  echo "<span class='badge good'>Endpoints: $END_COUNT</span>" >> "$REPORT"
  echo "<span class='badge $BADGE_CLASS'>Secrets: $SECRET_COUNT</span>" >> "$REPORT"

  echo "<h3>🔥 High Value</h3><pre>" >> "$REPORT"
  head -n 20 "$d/highvalue.txt" 2>/dev/null >> "$REPORT"
  echo "</pre>" >> "$REPORT"

  echo "<h3>🔑 Secrets</h3><pre>" >> "$REPORT"
  head -n 20 "$d/secrets.txt" 2>/dev/null >> "$REPORT"
  echo "</pre>" >> "$REPORT"

  echo "<h3>⚡ Endpoints</h3><pre>" >> "$REPORT"
  head -n 20 "$d/endpoints.txt" 2>/dev/null >> "$REPORT"
  echo "</pre>" >> "$REPORT"

  echo "</div>" >> "$REPORT"

done
cat <<EOF >> "$REPORT"
</body>
</html>
EOF

echo "[REPORT] done → $REPORT"
