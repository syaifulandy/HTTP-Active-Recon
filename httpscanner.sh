#!/bin/bash

#################################
# DEFAULT
#################################
URL_FILE="urls.txt"
OUTPUT_DIR="output"
FINAL_DIR="$OUTPUT_DIR/final"
BULK_OUT="$FINAL_DIR/output_bulkurlchecker.txt"
ALIVE_FILE="$OUTPUT_DIR/alive_urls.txt"
NUCLEI_DIR="$OUTPUT_DIR/nuclei"
NUCLEI_OUT="$NUCLEI_DIR/output_nuclei.txt"
NUCLEI_LOG="$NUCLEI_DIR/nuclei.log"

FFUF_DIR="$OUTPUT_DIR/ffuf"
FFUF_RAW_DIR="$FFUF_DIR/raw"
FFUF_CLEAN_DIR="$FFUF_DIR/clean"
FFUF_LOG_DIR="$FFUF_DIR/logs"
THREAD_HTTP=40
THREAD_FFUF=10
INTERNET_MODE=true



#################################
# HELP
#################################
show_help() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -i, --input FILE       Input URL file (default: urls.txt)"
  echo "  -o, --output FILE      Output directory (default: output/)"
  echo "  --http-threads N       HTTP threads (default: 40)"
  echo "  --ffuf-threads N       FFUF threads (default: 10)"
  echo "  --no-report            Skip Excel report"
  echo "  -h, --help             Show this help"
  echo ""
  echo "Example:"
  echo "  $0 -i target.txt -o result.csv --http-threads 50"
  exit 0
}

RUN_REPORT=true

#################################
# ARG PARSER
#################################
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -i|--input) URL_FILE="$2"; shift 2 ;;
    -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
    --http-threads) THREAD_HTTP="$2"; shift 2 ;;
    --ffuf-threads) THREAD_FFUF="$2"; shift 2 ;;
    --no-report) RUN_REPORT=false; shift ;;
    -h|--help) show_help ;;
    *) echo "❌ Unknown option: $1"; show_help ;;
  esac
done


FINAL_DIR="$OUTPUT_DIR/final"
BULK_OUT="$FINAL_DIR/output_bulkurlchecker.txt"
ALIVE_FILE="$OUTPUT_DIR/alive_urls.txt"

NUCLEI_DIR="$OUTPUT_DIR/nuclei"
NUCLEI_OUT="$NUCLEI_DIR/output_nuclei.txt"
NUCLEI_LOG="$NUCLEI_DIR/nuclei.log"

FFUF_DIR="$OUTPUT_DIR/ffuf"
FFUF_RAW_DIR="$FFUF_DIR/raw"
FFUF_CLEAN_DIR="$FFUF_DIR/clean"
FFUF_LOG_DIR="$FFUF_DIR/logs"

#################################
# CHECK
#################################
[[ ! -f "$URL_FILE" ]] && { echo "❌ Input file not found: $URL_FILE"; exit 1; }

mkdir -p "$OUTPUT_DIR"
mkdir -p "$FINAL_DIR"
mkdir -p "$NUCLEI_DIR"
mkdir -p "$FFUF_RAW_DIR" "$FFUF_CLEAN_DIR" "$FFUF_LOG_DIR"

> "$BULK_OUT"
> "$ALIVE_FILE"


#################################
# DNS RESOLVER
#################################
resolve_internet_ip() {
  local host="$1"
  local ip=""

  [[ ! "$host" =~ ^[a-zA-Z0-9.-]+$ ]] && return 1

  # Cloudflare DoH
  ip=$(curl -s \
    --max-time 5 \
    --connect-timeout 3 \
    --retry 2 \
    --retry-delay 1 \
    --fail \
    "https://cloudflare-dns.com/dns-query?name=${host}&type=A" \
    -H "accept: application/dns-json" \
    | jq -r '.Answer[]? | select(.type == 1) | .data' \
    | head -n1)

  # Fallback ke resolver lokal (internet + intranet)
  if [[ -z "$ip" ]]; then
    ip=$(dig +short A "$host" 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      | head -n1)
  fi

  echo "$ip"
}

#################################
# CLEAN FIELD
#################################
clean_field() {
  echo "$1" | tr -d '\r\n' | sed 's/,/ /g' | xargs
}


#################################
# HTTP CHECK
#################################

check_http() {
  raw_url="$1"
  echo "[HTTP] $raw_url"

  do_check() {
    local url="$1"
    local proto="$2"

    tmp_body=$(mktemp)
    tmp_header=$(mktemp)
    tmp_log=$(mktemp)

    url=$(echo "$url" | tr -d '\r' | xargs)
    host=$(echo "$url" | sed -E 's#https?://##' | cut -d/ -f1)

    curl_extra=""
    if $INTERNET_MODE && [[ "$proto" == "https" ]]; then
      ip=$(resolve_internet_ip "$host")
      [[ -n "$ip" ]] && curl_extra="--resolve $host:443:$ip"
    fi

    
    echo "[HTTP] Running command:"
    echo "curl -4 -k --max-time 20 -s $curl_extra -D \"$tmp_header\" -o \"$tmp_body\" -w \"%{http_code}|%{size_download}|%{remote_ip}|%{url_effective}\" -v \"$url\""

    
    curl_out=$(curl -4 -k --max-time 20 -s \
      $curl_extra \
      -D "$tmp_header" \
      -o "$tmp_body" \
      -w "%{http_code}|%{size_download}|%{remote_ip}|%{redirect_url}" \
      -v "$url" 2> "$tmp_log")

    IFS="|" read -r http_code size_download remote_ip redirect_url <<< "$curl_out"

    if [[ "$http_code" == "000" ]]; then
      rm -f "$tmp_body" "$tmp_header" "$tmp_log"
      echo "$url,http,000,-,-,FAILED,http" | tee -a "$BULK_OUT"

      return 1
    fi

    redirect_info="-"

    if [[ "$http_code" =~ ^30[12378]$ ]] && [[ -n "$redirect_url" ]]; then
      final_follow=$(curl -4 -k -L -s \
        -o /dev/null \
        -w "%{url_effective}|%{http_code}|%{size_download}" \
        --max-time 20 "$url")

      IFS="|" read -r final_url final_code final_size <<< "$final_follow"

      redirect_info="${final_url} [${final_code}|${final_size}]"
    fi


    #################################
    # TITLE
    #################################
    title=$(grep -i -o '<title[^>]*>.*</title>' "$tmp_body" | head -n1 \
      | sed -e 's/<title[^>]*>//I' -e 's#</title>##I')
    [[ -z "$title" ]] && title="-"

    #################################
    # SERVER INFO
    #################################
    server_info=$(grep -Ei '^(server|x-powered-by|via):' "$tmp_header" \
      | paste -sd ' | ' -)
    [[ -z "$server_info" ]] && server_info="-"

    #################################
    # SSL INFO
    #################################
    ssl_status="-"

    if [[ "$proto" == "http" ]]; then
      ssl_status="NO_TLS"
    else
      if grep -qi "self signed" "$tmp_log"; then
        ssl_status="SELF_SIGNED"
      elif grep -qi "expire date:" "$tmp_log"; then
        ssl_status="VALID"
      else
        ssl_status="NO_CERT"
      fi
    fi

    #################################
    # CLEAN FIELD
    #################################
    title=$(clean_field "$title")
    server_info=$(clean_field "$server_info")

    #################################
    # FINAL OUTPUT (PIPELINE FORMAT)
    #################################
    
    echo "$url,http,$http_code,$title,$ssl_status,$redirect_info,http" | tee -a "$BULK_OUT"

    # ✅ TAMBAHAN: filter alive
    if [[ "$http_code" != "000" ]]; then
      echo "$url" >> "$ALIVE_FILE"
    fi

    rm -f "$tmp_body" "$tmp_header" "$tmp_log"
    return 0
  }

  if [[ "$raw_url" =~ ^https?:// ]]; then
    proto=$(echo "$raw_url" | cut -d':' -f1)
    do_check "$raw_url" "$proto"
  else
    do_check "https://$raw_url" "https" || \
    do_check "http://$raw_url" "http"
  fi
}


#################################
# FFUF FILTER
#################################
should_run_ffuf() {
  local url
  url=$(echo "$1" | tr -d '\r' | xargs)

  [[ -z "$url" ]] && return 1
  [[ "$url" == *\?* ]] && return 1
  [[ "$url" =~ \.(jsp|jspx|php|asp|aspx|json|xml|txt)$ ]] && return 1

  local path depth
  path=$(echo "$url" | sed -E 's#https?://[^/]+##')
  depth=$(echo "$path" | tr -cd '/' | wc -c)

  [[ "$depth" -ge 5 ]] && return 1
  [[ "$url" =~ (login|logout|api|auth|signin|callback) ]] && return 1

  return 0
}

#################################
# BUILD WORDLIST COMBINED
#################################
build_ffuf_wordlist() {
  local wl_dir="/usr/share/seclists/Discovery/Web-Content"
  local wl_combined="$wl_dir/wordlist_combined.txt"

  if [ ! -f "$wl_combined" ]; then
    echo "[FFUF] build wordlist..."
    cat "$wl_dir/quickhits.txt" \
        "$wl_dir/common.txt" \
        "$wl_dir/raft-small-directories.txt" \
    | sort -u > "$wl_combined"
  fi

  echo "$wl_combined"
}

#################################
# FFUF PATH ONLY
#################################
run_ffuf() {
  local FULL_URL
  FULL_URL=$(echo "$1" | tr -d '\r' | xargs)

  should_run_ffuf "$FULL_URL" || {
    echo "[FFUF][SKIP] $FULL_URL"
    return 0
  }

  echo "[FFUF] $FULL_URL"

  local RAW_URL SAFE_NAME TMP_RAW TMP_CLEAN TMP_LOG USER_AGENT WORDLIST URL HTTP_STATUS

  RAW_URL=$(echo "$FULL_URL" | sed -E 's#(https?://[^/]+).*#\1#')
  SAFE_NAME=$(echo "$FULL_URL" | sed -E 's#https?://##; s#[/?]#_#g; s#[^a-zA-Z0-9._-]#_#g')

  TMP_RAW="$FFUF_RAW_DIR/${SAFE_NAME}_output.csv"
  TMP_CLEAN="$FFUF_CLEAN_DIR/${SAFE_NAME}_output_bersih.csv"
  TMP_LOG="$FFUF_LOG_DIR/${SAFE_NAME}_live.log"

  USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126 Safari/537.36"
  WORDLIST=$(build_ffuf_wordlist)

  # penting: hindari double slash
  URL="${FULL_URL%/}/FUZZ"

  #################################
  # SERVER CHECK
  #################################
  echo "[FFUF] Checking server: $RAW_URL"
  HTTP_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" "$RAW_URL")

  if [[ "$HTTP_STATUS" == "000" ]]; then
    echo "[FFUF][ERROR] Server down: $RAW_URL" | tee -a "$TMP_LOG"
    return 1
  fi

  echo "[FFUF][INFO] Server OK: HTTP $HTTP_STATUS" | tee -a "$TMP_LOG"

  #################################
  # RUN FFUF
  #################################
  echo "[FFUF] Running command:"
  echo " -w \"$WORDLIST:FUZZ\" \
-u \"$URL\" \
-t 150 \
-ic -ac -maxtime 1500 \
-of csv -o \"$TMP_RAW\" \
-H \"User-Agent: $USER_AGENT\""

  ffuf -w "$WORDLIST:FUZZ" \
       -u "$URL" \
       -t 150 \
       -ic -ac -maxtime 1500 \
       -of csv -o "$TMP_RAW" \
       -H "User-Agent: $USER_AGENT" \
       2>&1 | tee -a "$TMP_LOG"

  if [ ! -f "$TMP_RAW" ]; then
    echo "[FFUF][ERROR] FFUF gagal menghasilkan output: $TMP_RAW" | tee -a "$TMP_LOG"
    return 1
  fi

  #################################
  # CLEANING -> FORMAT REFERENSI LU (FIXED)
  #################################
  echo "[FFUF] Cleaning output -> $TMP_CLEAN"
  # Tambahkan baris ini untuk memastikan variabel mode terisi "path"
  local mode="path"

  awk -F',' -v OFS=',' -v mode="$mode" '
  function abs(x){ return x<0?-x:x }

  NR==1 {
    print "target_found","status","size","redirect_to","final_destination_info"
    next
  }

  {
    fuzz=$1
    url=$2
    rloc=$3
    status=$5
    clen=$6
    words=$7
    lines=$8

    gsub(/^ +| +$/, "", status)

    display=url
    if (rloc == "") rloc="-"

    # ========================================================
    # FILTER DUPLIKAT ABSOLUT (Paling Atas!)
    # Jika status, size, words, dan lines sama persis, langsung skip.
    # ========================================================
    exact_key = status "|" clen "|" words "|" lines
    if (seen_exact[exact_key]++) {
      next
    }

    # 1. Keep 403 (Penting buat Pentest)
    if (status == "403") {
      print display, status, clen, rloc, "DIRECT_403"
      next
    }

    # 2. Redirect Grouping via CURL + handling code 403 Forbidden (PENTING!)
    if (status ~ /^30[12378]$/) {
      cmd = "curl -k -s -L -o /dev/null --max-time 2 -w \"%{http_code}_%{size_download}\" \"" url "\""
      cmd | getline res
      close(cmd)

      if (res == "") res = "TIMEOUT_0"

      # PERBAIKAN: Jika hasil akhirnya ternyata 403, LANGSUNG LOLOSKAN tanpa grouping!
      if (res ~ /^403_/) {
        print display, status, clen, rloc, "FINAL_" res
        next
      }

      # Sisa status lainnya (seperti berakhir di 200/404) tetap masuk ke logika grouping semula
      group_key = "REDIR_TO_" res
      if (!(seen[group_key]++)) {
        print display, status, clen, rloc, "FINAL_" res
      }
      next
    }

    # 3. Status 200 Deduplication
    if (status == "200") {
      base = words "|" lines
      found = 0
      for (k in oklen) {
        if (k == base && abs(clen - oklen[k]) <= 10) {
          found = 1
          break
        }
      }
      if (!found) {
        oklen[base] = clen
        print display, status, clen, rloc, "UNIQUE_200"
      }
      next
    }

    # 4. Others
    gen_key = "GEN|" status "|" clen
    if (!(seen[gen_key]++)) {
      print display, status, clen, rloc, "OTHER"
    }
  }
  ' "$TMP_RAW" | tee "$TMP_CLEAN"

  echo "[FFUF] DONE"
  echo "[FFUF] RAW   : $TMP_RAW"
  echo "[FFUF] CLEAN : $TMP_CLEAN"
  echo "[FFUF] LOG   : $TMP_LOG"
}


#################################
# EXPORTS
#################################
declare -F check_http
declare -F resolve_internet_ip
declare -F clean_field
declare -F should_run_ffuf
declare -F run_ffuf

export -f check_http
export -f resolve_internet_ip
export -f clean_field


export -f should_run_ffuf
export -f build_ffuf_wordlist
export -f run_ffuf

export FFUF_RAW_DIR
export FFUF_CLEAN_DIR
export FFUF_LOG_DIR


export BULK_OUT
export ALIVE_FILE
export INTERNET_MODE
export URL_FILE
export THREAD_HTTP
export THREAD_FFUF


#################################
# RUN
#################################
echo "=== HTTP ==="
cat "$URL_FILE" | sort -u | xargs -P $THREAD_HTTP -I{} bash -c 'check_http "$@"' _ {}

echo "=== HTTP DONE ==="

sort -u "$ALIVE_FILE" -o "$ALIVE_FILE"

echo "[DEBUG] Alive targets:"
cat "$ALIVE_FILE"



#################################
# NUCLEI
#################################
echo "=== NUCLEI ==="

if [ ! -s "$ALIVE_FILE" ]; then
  echo "[NUCLEI] No alive targets, skip"
else
  NUCLEI_TIMEOUT=10000

  echo "[NUCLEI] Running command:"
  echo "timeout \"$NUCLEI_TIMEOUT\" nuclei \
  -s critical,high,medium \
  -l \"$ALIVE_FILE\" \
  -o \"$NUCLEI_OUT\" \
  -nh -ni -mhe 25 -duc -pt http"

  timeout "$NUCLEI_TIMEOUT" nuclei \
    -s critical,high,medium \
    -l "$ALIVE_FILE" \
    -o "$NUCLEI_OUT" \
    -nh -ni -mhe 25 -duc -pt http \
    2>&1 | tee "$NUCLEI_LOG"

  # ✅ simple validation
  if [ ! -f "$NUCLEI_OUT" ]; then
    echo "[NUCLEI] No output generated"
  fi
fi


echo "=== FFUF ==="
if [ -s "$ALIVE_FILE" ]; then
  cat "$ALIVE_FILE" | xargs -P $THREAD_FFUF -I{} bash -c 'run_ffuf "$@"' _ {}
else
  echo "[FFUF] No alive targets, skip"
fi


#################################
# REPORT --> Perlu python
#################################
if $RUN_REPORT; then
  echo "=== REPORT ==="
  python3 report.py -i "$FINAL_DIR"
fi


echo "=== FINAL MERGE ==="

# bulk → final (rename aja)
cp "$BULK_OUT" "$FINAL_DIR/output_bulkurlchecker.txt"

# nuclei → final
[ -f "$NUCLEI_OUT" ] && cp "$NUCLEI_OUT" "$FINAL_DIR/output_nuclei.txt"


# ffuf clean → merge
FFUF_FINAL="$FINAL_DIR/output_ffuf.txt"
> "$FFUF_FINAL"

if compgen -G "$FFUF_CLEAN_DIR/*.csv" > /dev/null; then
  for f in "$FFUF_CLEAN_DIR"/*.csv; do
    tail -n +2 "$f" >> "$FFUF_FINAL"
  done
else
  echo "[FINAL] No FFUF results" >> "$FFUF_FINAL"
fi


echo "[FINAL] FFUF merged -> $FFUF_FINAL"


echo "✅ DONE -> $OUTPUT_DIR"
