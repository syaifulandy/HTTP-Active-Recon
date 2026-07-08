#!/bin/bash

INPUT_FILE="" # Dikosongkan untuk validasi wajib di getopts
OUTPUT_DIR="output"
THREADS=8
COOKIE=""

# ✅ Fungsi Help Menu (Menggunakan kutip satu agar contoh lebih bersih tanpa backslash)
usage() {
  echo "Usage: $0 -i <targets.txt> [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -i  Input file containing target URLs (Required)"
  echo "  -t  Number of concurrent threads (Default: 8)"
  echo "  -e  Exclude list file (Regex pattern)"
  echo "  -c  Cookie string for authenticated crawling"
  echo "  -h  Show this help message"
  echo ""
  echo "Example:"
  # Diubah menggunakan kutip dua agar $0 terbaca dinamis, cookie dibungkus kutip satu (')
  echo "  $0 -i targets.txt -t 10 -c 'PHPSESSID=ujm2n786gdb7vtt87s6; security=low'"
  exit 1
}

# ✅ Update getopts untuk menerima flag -c dan -h
while getopts "i:t:e:c:h" opt; do
  case $opt in
    i) INPUT_FILE="$OPTARG" ;;
    t) THREADS="$OPTARG" ;;
    e) EXCLUDE_FILE="$OPTARG" ;;
    c) COOKIE="$OPTARG" ;;
    h | *) usage ;;
  esac
done

# ✅ Validasi parameter wajib sebelum eksekusi lanjut
if [[ -z "$INPUT_FILE" ]]; then
  echo "[!] Error: Flag -i wajib diisi."
  usage
fi

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
export COOKIE # ✅ WAJIB diexport agar bisa dibaca fungsi crawl_target di dalam xargs


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
    THREADS=${THREADS:-8}

    URL=$1
    DOMAIN=$(echo $URL | sed 's|https\?://||' | cut -d/ -f1)    
    TARGET_DIR="$OUTPUT_DIR/$DOMAIN"
    mkdir -p "$TARGET_DIR/files"
    FINAL_FILE="$TARGET_DIR/katana.jsonl"
    FILE_STD="$TARGET_DIR/katana_std.jsonl"
    FILE_HL="$TARGET_DIR/katana_hl.jsonl"

    echo "[RUNNING] $DOMAIN (Dual-Engine Mode)"

    # ✅ 1. Siapkan argumen kuki dinamis
    KATANA_AUTH_ARGS=()
    if [[ -n "$COOKIE" ]]; then
        KATANA_AUTH_ARGS=("-H" "Cookie: $COOKIE")
    fi

    # ✅ 2. AMBIL LOCAL DNS DARI OS SECARA OTOMATIS 🔥
    # Ini akan mengambil IP seperti 10.2.1.5 atau DNS default target lab Anda
    LOCAL_DNS=$(grep -m 1 "nameserver" /etc/resolv.conf | awk '{print $2}')
    
    # Gabungkan Local DNS dengan DNS Publik sebagai fallback cadangan
    if [[ -n "$LOCAL_DNS" ]]; then
        DNS_ARGS=("-r" "$LOCAL_DNS,1.1.1.1,8.8.8.8")
    else
        DNS_ARGS=("-r" "1.1.1.1,8.8.8.8")
    fi

    # 🚀 ENGINE 1: Standard Mode
    # Cetak debug command dengan memunculkan tanda kutip kuki secara visual agar siap copas
    if [[ -n "$COOKIE" ]]; then
        echo "[DEBUG CMD] Engine 1 (Standard): katana -u \"$URL\" -H \"Cookie: $COOKIE\" ${DNS_ARGS[@]}  -d 5 -jc -aff -jsl -kf all -j -silent -ob -or"
    else
        echo "[DEBUG CMD] Engine 1 (Standard): katana -u \"$URL\" ${DNS_ARGS[@]}  -d 5 -jc -aff -jsl -kf all -j -silent -ob -or"
    fi
    timeout 3m katana -u "$URL" \
        "${KATANA_AUTH_ARGS[@]}" \
        "${DNS_ARGS[@]}" \
        -d 5 \
        -jc -aff \
        -jsl \
        -kf all \
        -j \
        -silent \
        -ob -or \
        -o "$FILE_STD" \
        > /dev/null 2>&1

    # 🚀 ENGINE 2: Headless Mode
    echo "[DEBUG CMD] Engine 2 (Headless): katana -u \"$URL\" ${DNS_ARGS[@]} -ns -d 5 -jc -aff -jsl -kf all -hl -xhr -system-chrome -system-chrome-path /usr/bin/chromium -no-sandbox -j -silent -ob -or"
    timeout 3m katana -u "$URL" \
        "${KATANA_AUTH_ARGS[@]}" \
        "${DNS_ARGS[@]}" \
        -d 5 \
        -jc -aff \
        -jsl \
        -kf all \
        -hl -pls domcontentloaded \
        -xhr \
        -system-chrome \
        -system-chrome-path /usr/bin/chromium \
        -no-sandbox \
        -j \
        -silent \
        -ob -or \
        -o "$FILE_HL" \
        > /dev/null 2>&1

    # 🤝 PROSES MERGE & DE-DUPLICATE LEVEL JSON (Bebas Duplikat Struktural)
    echo "[MERGE] Combining Standard and Headless results for $DOMAIN"
    cat "$FILE_STD" "$FILE_HL" \
        | jq -c -s 'unique_by(
            .request.method,
            .request.endpoint,
            (.request.body // "")
        )' \
        | jq -c '.[]' \
        > "$FINAL_FILE" 2>/dev/null

    # Bersihkan file sampah instansi agar disk lab tidak penuh
    rm -f "$FILE_STD" "$FILE_HL"

    # Alihkan variabel asal ke file final yang sudah bersih
    FILE="$FINAL_FILE"


    
    mkdir -p "$OUTPUT_DIR/$DOMAIN"

    echo "[EXTRACT] $DOMAIN"

    # ✅ extract semua URL
    jq -r '
    .request.endpoint
    ' "$FILE" 2>/dev/null |
    grep -v '^null$' |
    sort -u |
    filter_exclude \
    > "$TARGET_DIR/urls.txt"



    
    
    grep -E "\?.*=" "$TARGET_DIR/urls.txt" \
    | filter_exclude \
    > "$TARGET_DIR/params.txt"

    sed -E 's/\?.*/?FUZZ=1/' "$TARGET_DIR/params.txt" \
    | filter_exclude \
    | sort -u \
    > "$TARGET_DIR/fuzz.txt"



    echo "[PARAM] $(wc -l < "$TARGET_DIR/params.txt" 2>/dev/null || echo 0) param found"

    # ✅ DOWNLOAD CLEAN FILE 🔥
    echo "[DOWNLOAD] $DOMAIN"

    COUNT=0

    # ✅ Buat argumen dinamis Curl
    CURL_AUTH_ARGS=()
    if [[ -n "$COOKIE" ]]; then
        CURL_AUTH_ARGS=(-H "Cookie: $COOKIE")
    fi

    while read -r link; do
        echo "$link" | filter_exclude | grep -q . || continue

        [[ "$link" =~ \.(png|jpg|jpeg|gif|css|svg|woff|ico)$ ]] && continue

        NAME=$(echo "$link" | sed 's|https\?://||' | sed 's|[^a-zA-Z0-9]|_|g')

        if [[ "$link" =~ \.js($|\?) ]]; then
            EXT=".js"
        elif [[ "$link" =~ \.map($|\?) ]]; then
            EXT=".map"
        elif [[ "$link" =~ \.json($|\?) ]]; then
            EXT=".json"
        elif [[ "$link" =~ \.(php|asp|aspx|jsp)($|\?) ]]; then
            EXT=".html"
        else
            EXT=".html"
        fi

        # ✅ Sisipkan ${CURL_AUTH_ARGS[@]} pada pengecekan status code
        STATUS=$(curl "${CURL_AUTH_ARGS[@]}" -m 10 -s -o /dev/null -w "%{http_code}" "$link")

        if [[ "$STATUS" == "200" ]]; then
            # ✅ Sisipkan ${CURL_AUTH_ARGS[@]} pada proses download file
            curl "${CURL_AUTH_ARGS[@]}" -s "$link" -o "$TARGET_DIR/files/$NAME$EXT"
            ((COUNT++))
        fi

    done < "$TARGET_DIR/urls.txt"

    # FORM ACTION DISCOVERY
    echo "[FORM] Extracting forms from downloaded files"
    > "$TARGET_DIR/form_actions.txt"

    
    grep -rhoEi '<form[^>]*>' "$TARGET_DIR/files" 2>/dev/null |
    while read -r form; do

        ACTION=$(echo "$form" |
            grep -oiE 'action=["'\''][^"'\'']+' |
            sed -E 's/action=["'\'']//I')

        METHOD=$(echo "$form" |
            grep -oiE 'method=["'\''][^"'\'']+' |
            sed -E 's/method=["'\'']//I')

        [[ -z "$METHOD" ]] && METHOD="GET"
        [[ -z "$ACTION" ]] && continue

        echo "${METHOD^^}|$ACTION"
    done >> "$TARGET_DIR/form_actions.txt"

    sort -u "$TARGET_DIR/urls.txt" -o "$TARGET_DIR/urls.txt"

    
    jq -r '
    .request
    | select(
        .method != null and
        .endpoint != null
    )
    | "\(.method) \(
          .endpoint
          | sub("^https?://[^/]+";"")
          | if . == "" then "/" else . end
      )"
    ' "$FILE" |
    sort -u \
    > "$TARGET_DIR/endpoint_methods.txt"



    # ✅ NORMAL ENDPOINT
    grep -rhoE "(https?://[^\"' ]+|/[a-zA-Z0-9/_\.\-]+(\?[^\"' ]+)?)" \
    "$TARGET_DIR/files" "$TARGET_DIR"/*.html 2>/dev/null > "$TARGET_DIR/.ep1"

    # ✅ JS FETCH / AJAX ENDPOINT
    grep -rhoE "fetch\([^)]+|axios\.[a-z]+\([^)]+|\$.ajax\([^)]+\)" \
    "$TARGET_DIR/files" 2>/dev/null \
    | grep -oE "(https?://[^\"']+|/[a-zA-Z0-9/_\.\-]+(\?[^\"']+)?)" > "$TARGET_DIR/.ep2"

    # ✅ MERGE SEMUA
    cat "$TARGET_DIR/.ep1" "$TARGET_DIR/.ep2" \
    | grep -vE '^/(html|head|body|div|span|form|table|tbody|thead|tr|td|th|script|style|label|button|h1|h2|h3|h4|h5|h6|p|strong|i|a|ul|ol|li|input|select|option|textarea|nav|footer|header|main|section|article)$' \
    | grep -vE '\.(png|jpg|css|svg)$' \
    | filter_exclude \
    | sort -u \
    > "$TARGET_DIR/endpoints.txt"


    rm -f "$TARGET_DIR/.ep1" "$TARGET_DIR/.ep2"



    # ✅ HIGH VALUE 🔥
    grep -Ei "create|update|delete|admin|login|auth|debug|api" \
    "$TARGET_DIR/endpoints.txt" \
    > "$TARGET_DIR/highvalue.txt"


    # ✅ REQUEST LIST (BURP/FFUF READY) 🔥
   
    > "$TARGET_DIR/requests.txt"

    
    jq -r '
    .request
    | select(
        .method != null and
        .endpoint != null
    )
    | [
        .method,
        (
          .endpoint
          | sub("^https?://[^/]+";"")
          | if . == "" then "/" else . end
        ),
        (.body // "")
      ]
    | @tsv
    ' "$FILE" |
    sort -u |
    while IFS=$'\t' read -r METHOD PATH BODY
    do

        echo "$METHOD $PATH HTTP/1.1"
        echo "Host: $DOMAIN"

        if [[ -n "$BODY" ]]; then
            echo "Content-Type: application/json"
            echo
            echo "$BODY"
        fi

        echo
        echo "################################"
        echo

    done > "$TARGET_DIR/requests.txt"




    # ✅ SENSITIVE DATA 🔥
    # ─── 1. EKSTRAKSI AWAL (SERAKAH) ───────────────────────────────────────
    # Menangkap semua kandidat termasuk format JSON blob dan parameter URL
    > "$TARGET_DIR/secrets_raw.txt"

    grep -rHoEi "(api[_-]?key|token|secret|password|jwt|bearer)[\"'\s:=]+[a-zA-Z0-9_\-\.=#:+/@\${}\"']{3,}" \
    "$TARGET_DIR/files" "$TARGET_DIR"/*.html 2>/dev/null \
    >> "$TARGET_DIR/secrets_raw.txt"

    grep -rHoEi "(token|password|secret|key)=[a-zA-Z0-9_\-\.]+" \
    "$TARGET_DIR/files" "$TARGET_DIR"/*.html 2>/dev/null \
    >> "$TARGET_DIR/secrets_raw.txt"

    grep -rHoE "eyJ[a-zA-Z0-9_\-\.=]+" "$TARGET_DIR" 2>/dev/null \
    >> "$TARGET_DIR/secrets_raw.txt"

    grep -rHoEi "Authorization[\"' :]+Bearer[ ]+[^\"'[:space:]]+" \
    "$TARGET_DIR/files" "$TARGET_DIR"/*.html 2>/dev/null \
    >> "$TARGET_DIR/secrets_raw.txt"

    # Rapikan file RAW (urutkan dan hilangkan duplikat teks mentah)
    if [[ -s "$TARGET_DIR/secrets_raw.txt" ]]; then
        sort -u "$TARGET_DIR/secrets_raw.txt" -o "$TARGET_DIR/secrets_raw.txt"
    fi

    # ✅ API HEADER EXTRACTION 🔥
    grep -rHoEi "(api[_-]?key|api[_-]?id|authorization)['\" ]*[:=]['\" ]*[a-zA-Z0-9\-]{10,}" \
    "$TARGET_DIR/files" "$TARGET_DIR"/*.html 2>/dev/null \
    >> "$TARGET_DIR/secrets_raw.txt"



    # ─── 2. FILTERING UNTUK LAPORAN UTAMA (BERSIH & TAJAM) ─────────────────
    # Memisahkan data bersih ke file secrets.txt tanpa menghapus file RAW
    if [[ -s "$TARGET_DIR/secrets_raw.txt" ]]; then
        grep -viE "(password['\"]?\s*[:=]\s*['\"]?['\"]?$)" "$TARGET_DIR/secrets_raw.txt" \
        | grep -viE "[:=][\"'\s]*(null|true|false|undefined|void|placeholder|example|xxxxxx)[\"'\s]*$" \
        | grep -viE "[\"'](text|password|email|number)[\"']" \
        | sort -u \
        > "$TARGET_DIR/secrets.txt"
    else
        > "$TARGET_DIR/secrets.txt"
    fi
    # ─── 3. GENERIC IDENTITY & ROLES MAPPER (DUAL-TRACK) ──────────────────
    echo "[MINING] Scanning for generic user profiles and authorization maps in $DOMAIN"
    > "$TARGET_DIR/identities.txt"
    > "$TARGET_DIR/roles_policy.txt"

    find "$TARGET_DIR/files" -type f 2>/dev/null | while read -r file; do
        
        # Jalur 1: Mengendus Profil Pengguna (High Accuracy)
        grep -E "[\"'](username|email|user_id)[\"']\s*:" "$file" 2>/dev/null | while read -r raw_line; do
            [[ ${#raw_line} -gt 2000 ]] && continue
            clean_line=$(echo "$raw_line" | sed 's/^[ \t]*//;s/[ \t]*$//')
            if echo "$clean_line" | grep -qE "\{.*\}"; then
                json_part=$(echo "$clean_line" | grep -oE "\{.*\}")
                if echo "$json_part" | jq . >/dev/null 2>&1; then
                    echo "=== Profile Struct Found in $(basename "$file") ===" >> "$TARGET_DIR/identities.txt"
                    echo "$json_part" | jq . >> "$TARGET_DIR/identities.txt"
                    echo "" >> "$TARGET_DIR/identities.txt"
                fi
            fi
        done

        # Jalur 2: Mengendus Hak Akses & Kebijakan Otorisasi (Potensi Noise)
        grep -E "[\"'](role|privilege|access_level)[\"']\s*:" "$file" 2>/dev/null | while read -r raw_line; do
            [[ ${#raw_line} -gt 2000 ]] && continue
            clean_line=$(echo "$raw_line" | sed 's/^[ \t]*//;s/[ \t]*$//')
            if echo "$clean_line" | grep -qE "\{.*\}"; then
                json_part=$(echo "$clean_line" | grep -oE "\{.*\}")
                if echo "$json_part" | jq . >/dev/null 2>&1; then
                    echo "=== Auth/Role Map Found in $(basename "$file") ===" >> "$TARGET_DIR/roles_policy.txt"
                    echo "$json_part" | jq . >> "$TARGET_DIR/roles_policy.txt"
                    echo "" >> "$TARGET_DIR/roles_policy.txt"
                fi
            fi
        done

    done

    # 🤝 PROSES DEDUPLIKASI KEDUA BERKAS SECARA INDEPENDEN
    for txt_file in "identities.txt" "roles_policy.txt"; do
        if [[ -s "$TARGET_DIR/$txt_file" ]]; then
            awk 'BEGIN{RS="";ORS="\n\n"} !seen[$0]++' "$TARGET_DIR/$txt_file" > "$TARGET_DIR/${txt_file}_clean" 2>/dev/null
            mv "$TARGET_DIR/${txt_file}_clean" "$TARGET_DIR/$txt_file"
        fi
    done

    # ✅ BUILD RAW REQUEST 🔥
    echo "[BUILD] Generating API request templates for $DOMAIN"

    > "$TARGET_DIR/api_requests.txt"

    while read -r ep; do

        [[ "$ep" != /* ]] && continue

        # ❌ skip noise
        [[ "$ep" =~ ^/\.$ ]] && continue
        [[ "$ep" =~ ^/-$ ]] && continue
        [[ "$ep" =~ ^/\.[a-z]+$ ]] && continue
        [[ "$ep" =~ \.(js|css|png|jpg|svg|ico)$ ]] && continue


        echo "GET $ep HTTP/1.1" >> "$TARGET_DIR/api_requests.txt"
        echo "Host: $DOMAIN" >> "$TARGET_DIR/api_requests.txt"

        # hanya inject kalau endpoint API
        if echo "$ep" | grep -qiE "api|auth|login|token"; then
            grep -E "(api[_-]?key|api[_-]?id)" "$TARGET_DIR/secrets.txt" 2>/dev/null | while read -r h; do
                key=$(echo "$h" | sed 's/.*\(api[_-]*[a-z]*\)[\"'\'']*[:=].*/\1/I')
                val=$(echo "$h" | sed 's/.*[:=][\"'\'']*//')
                echo "$key: $val" >> "$TARGET_DIR/api_requests.txt"
            done
        fi


        echo "" >> "$TARGET_DIR/api_requests.txt"
    done < "$TARGET_DIR/endpoints.txt"

    # ==========================================================
    # RECON VALIDATION LAYER
    # Tidak mengubah pipeline lama
    # ==========================================================

    echo "[VALIDATE] Building request inventory for $DOMAIN"

    MASTER="$TARGET_DIR/requests_master.txt"
    RAWRESP="$TARGET_DIR/responses_raw.csv"
    CLEANRESP="$TARGET_DIR/responses_clean.csv"
    ALIVE="$TARGET_DIR/alive_urls.txt"
    INTERESTING="$TARGET_DIR/interesting.txt"

    > "$MASTER"
    > "$RAWRESP"
    > "$CLEANRESP"
    > "$ALIVE"
    > "$INTERESTING"

    normalize_url() {

        local p="$1"

        [[ -z "$p" ]] && return

        if [[ "$p" =~ ^https?:// ]]; then
            echo "$p"
            return
        fi

        [[ "$p" != /* ]] && p="/$p"

        echo "https://$DOMAIN$p"
    }

    # --------------------------------------------------
    # urls.txt  -> GET
    # --------------------------------------------------
    if [[ -f "$TARGET_DIR/urls.txt" ]]; then
        while read -r u; do
            [[ -z "$u" ]] && continue
            echo "GET|$u"
        done < "$TARGET_DIR/urls.txt" >> "$MASTER"
    fi

    # --------------------------------------------------
    # endpoints.txt -> GET
    # --------------------------------------------------
    if [[ -f "$TARGET_DIR/endpoints.txt" ]]; then
        while read -r ep; do

            [[ -z "$ep" ]] && continue

            URLN=$(normalize_url "$ep")

            # terlalu panjang = minified js
            [[ ${#URLN} -gt 300 ]] && continue

            # regex/js junk
            echo "$URLN" | grep -qE '[{}[\]\\]' && continue

            # js syntax junk
            echo "$URLN" | grep -qiE \
            'function|return|prototype|Math\.|parse:|NaN|getUTC|rgba|centroid=' \
            && continue

            echo "GET|$URLN"



        done < "$TARGET_DIR/endpoints.txt" >> "$MASTER"
    fi

    # --------------------------------------------------
    # highvalue.txt -> GET
    # --------------------------------------------------
    if [[ -f "$TARGET_DIR/highvalue.txt" ]]; then
        while read -r ep; do

            [[ -z "$ep" ]] && continue

            URLN=$(normalize_url "$ep")

            # terlalu panjang = minified js
            [[ ${#URLN} -gt 300 ]] && continue

            # regex/js junk
            echo "$URLN" | grep -qE '[{}[\]\\]' && continue

            # js syntax junk
            echo "$URLN" | grep -qiE \
            'function|return|prototype|Math\.|parse:|NaN|getUTC|rgba|centroid=' \
            && continue

            echo "GET|$URLN"

        done < "$TARGET_DIR/highvalue.txt" >> "$MASTER"
    fi

    # --------------------------------------------------
    # fuzz.txt -> GET
    # --------------------------------------------------
    if [[ -f "$TARGET_DIR/fuzz.txt" ]]; then
        while read -r fu; do

            [[ -z "$fu" ]] && continue

            echo "GET|$fu"

        done < "$TARGET_DIR/fuzz.txt" >> "$MASTER"
    fi

    # --------------------------------------------------
    # endpoint_methods.txt
    # --------------------------------------------------
    if [[ -f "$TARGET_DIR/endpoint_methods.txt" ]]; then
        while read -r METHOD PATHX; do

            [[ -z "$METHOD" ]] && continue
            [[ -z "$PATHX" ]] && continue

            URLN=$(normalize_url "$PATHX")

            echo "$METHOD|$URLN"

        done < "$TARGET_DIR/endpoint_methods.txt" >> "$MASTER"
    fi

    # --------------------------------------------------
    # form_actions.txt
    # --------------------------------------------------
    if [[ -f "$TARGET_DIR/form_actions.txt" ]]; then
        while IFS='|' read -r METHOD ACTION; do

            [[ -z "$METHOD" ]] && continue
            [[ -z "$ACTION" ]] && continue

            URLN=$(normalize_url "$ACTION")

            echo "${METHOD^^}|$URLN"

        done < "$TARGET_DIR/form_actions.txt" >> "$MASTER"
    fi

    # --------------------------------------------------
    # deduplicate
    # --------------------------------------------------
    
    sort -u "$MASTER" -o "$MASTER"

    # skip asset statis
    grep -viE '\.(js|css|png|jpg|jpeg|gif|svg|ico|woff|woff2|ttf|eot|otf|map)(\?|$)' \
    "$MASTER" > "$MASTER.tmp"
    mv "$MASTER.tmp" "$MASTER"


    # skip obvious javascript/minified noise
    grep -viE '(function\(|return\{|prototype|Math\.|parse:|NaN|rgba\?\\\(|\\d\\d)' \
    "$MASTER" > "$MASTER.tmp"
    mv "$MASTER.tmp" "$MASTER"

    echo "method|url|status|size|words|lines|redirect" > "$RAWRESP"


    TMPRESP="$TARGET_DIR/.responses.tmp"
    > "$TMPRESP"

    export TMPRESP

    echo "[VALIDATE] Curl fingerprinting..."
    echo "[DBG] THREADS=$THREADS"
    echo "[DBG] MASTER_LINES=$(wc -l < "$MASTER")"



    echo "[VALIDATE] Curl fingerprinting..."

    

    xargs -a "$MASTER" \
    -P "$THREADS" \
    -d '\n' \
    -I {} bash -c '

    LINE="$1"

    METHOD=$(echo "$LINE" | cut -d"|" -f1)
    URL=$(echo "$LINE" | cut -d"|" -f2)

    [[ -z "$URL" ]] && exit 0

    TMPBODY=$(mktemp)

    RESPONSE=$(curl -k \
        -L \
        -H "User-Agent: Mozilla/5.0" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.9" \
        -X "$METHOD" \
        --connect-timeout 1 \
        --max-time 3 \
        -s \
        -o "$TMPBODY" \
        -w "%{http_code}|%{size_download}|%{redirect_url}" \
        "$URL")

    STATUS=$(echo "$RESPONSE" | cut -d"|" -f1)
    SIZE=$(echo "$RESPONSE" | cut -d"|" -f2)
    REDIR=$(echo "$RESPONSE" | cut -d"|" -f3)

    WORDS=$(wc -w < "$TMPBODY" 2>/dev/null || echo 0)
    LINES=$(wc -l < "$TMPBODY" 2>/dev/null || echo 0)

    echo "$METHOD|$URL|$STATUS|$SIZE|$WORDS|$LINES|$REDIR" >> "$TMPRESP"

    rm -f "$TMPBODY"

    ' _ {}


    
    echo "[DBG] TMPRESP lines: $(wc -l < "$TMPRESP")"
    head -5 "$TMPRESP"

    sort -u "$TMPRESP" >> "$RAWRESP"



    # ==========================================================
    # SMART DEDUP
    # ==========================================================

    awk -F'|' '

    BEGIN{
        OFS=","
        print "method,url,status,size,words,lines,redirect"
    }

    NR==1 { next }

    {
        method=$1
        url=$2
        status=$3
        size=$4
        words=$5
        lines=$6
        redir=$7

        # skip noise / gagal resolve
        if (status=="000")
            next

        # skip response kosong
        if (size==0 && words==0 && lines==0)
            next

        exact=status "|" size "|" words "|" lines

        if (status=="403") {
            print
            next
        }

        if (status ~ /^30/) {

            r="REDIR|" status "|" redir

            if (!(seen[r]++))
                print

            next
        }

        if (status=="200") {

            k=words "|" lines

            if (!(seen200[k]++))
                print

            next
        }

        g=status "|" size

        if (!(seen[g]++))
            print
    }

    ' "$RAWRESP" > "$CLEANRESP"

    # ==========================================================
    # alive urls
    # ==========================================================

    awk -F'|' '
    NR>1 && ($3=="200" || $3=="401" || $3=="403")
    {
        print $2
    }
    ' "$CLEANRESP" \
    | sort -u \
    > "$ALIVE"

    # ==========================================================
    # interesting
    # ==========================================================
    awk -F'|' '
    NR>1 && ($3=="401" || $3=="403" || $3=="500" || $3 ~ /^30/)
    {
        print $3" "$1" "$2
    }
    ' "$CLEANRESP" \
    > "$INTERESTING"


    echo "[VALIDATE] requests : $(wc -l < "$MASTER" 2>/dev/null)"    
    RESP_COUNT=$(wc -l < "$CLEANRESP" 2>/dev/null || echo 0)

    [[ "$RESP_COUNT" -gt 0 ]] && RESP_COUNT=$((RESP_COUNT-1))

    echo "[VALIDATE] responses: $RESP_COUNT"




    # ─── 4. SUMMARY GENERATION & STATS ────────────────────────────────────
    # Ambil total objek unik yang berhasil di-mining berdasarkan header penanda    
    STRUCT_COUNT=$(grep -c "=== Profile Struct" "$TARGET_DIR/identities.txt" 2>/dev/null || true)
    ROLE_COUNT=$(grep -c "=== Auth/Role Map" "$TARGET_DIR/roles_policy.txt" 2>/dev/null || true)


    echo "[DONE] $DOMAIN"
    echo "  URLs        : $(wc -l < "$TARGET_DIR/urls.txt" 2>/dev/null || echo 0)"
    echo "  params      : $(wc -l < "$TARGET_DIR/params.txt" 2>/dev/null || echo 0)"
    echo "  endpoints   : $(wc -l < "$TARGET_DIR/endpoints.txt" 2>/dev/null || echo 0)"
    echo "  highvalue   : $(wc -l < "$TARGET_DIR/highvalue.txt" 2>/dev/null || echo 0)"
    echo "  Profiles    : $STRUCT_COUNT JSON objects (High-Signal) 👤"
    echo "  Auth Maps   : $ROLE_COUNT JSON objects (Low-Signal/Roles) 🔑"
    echo "  secrets (HQ): $(wc -l < "$TARGET_DIR/secrets.txt" 2>/dev/null || echo 0)"
    echo "  secrets(RAW): $(wc -l < "$TARGET_DIR/secrets_raw.txt" 2>/dev/null || echo 0)"
    echo "  files       : $COUNT"
    echo "-----------------------------"

}

export -f crawl_target
export OUTPUT_DIR sanitize_filename
export THREADS

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

echo "[REPORT] done check $REPORT"
