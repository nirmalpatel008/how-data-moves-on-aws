#!/usr/bin/env bash
# ------------------------------------------------------------------
#  How Data Moves on AWS: guided demo runner
#
#  ./demo.sh up     create everything (one CloudFormation stack)
#  ./demo.sh run    walk through the demo, one step at a time
#  ./demo.sh down   delete the stack (and every resource + file in it)
#  ./demo.sh all    up, run, then ask before down
#
#  Options (env vars):
#    AUTO=1   don't wait for Enter between steps
#    FAST=1   don't type commands out letter by letter
#    AWS_REGION=ap-south-1 (default)   STACK=how-data-moves (default)
#
#  Built for AWS CloudShell: needs the AWS CLI, jq and awk (all preinstalled there).
# ------------------------------------------------------------------
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
STACK="${STACK:-how-data-moves}"
WG="how-data-moves"
DB="canteen_db"
CRAWLER="canteen-raw-crawler"
JOB="clean-canteen-orders"
HERE="$(cd "$(dirname "$0")" && pwd)"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""

# ---------- look and feel ----------
B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'
OR=$'\e[38;5;214m'; PU=$'\e[38;5;141m'; GR=$'\e[38;5;114m'; CY=$'\e[38;5;117m'; RD=$'\e[38;5;203m'

banner() {   # banner "1" "Raw CSV files sitting in S3"
  local line; line=$(printf '%*s' 62 '' | tr ' ' '-')
  echo; echo "${PU}${line}${R}"
  printf "${PU}${B} STEP %s ${R}${B} %s${R}\n" "$1" "$2"
  echo "${PU}${line}${R}"
}
say()   { echo "${OR}> ${R}$*"; }
ok()    { echo "${GR}✔ ${R}$*"; }
pause() { [ "${AUTO:-0}" = "1" ] && return 0; read -rsp "${D}   (press Enter)${R}" _ </dev/tty; printf '\r\e[K'; }

show() {     # print a command like it's being typed, then run it
  local cmd="$*"
  printf "${CY}\$ ${R}"
  if [ "${FAST:-0}" = "1" ]; then printf "%s" "$cmd"
  else for ((i = 0; i < ${#cmd}; i++)); do printf "%s" "${cmd:i:1}"; sleep 0.012; done; fi
  echo; eval "$cmd"
}

spin() {     # spin "message" check_function  (check prints a status; DONE/FAILED end it)
  local msg="$1" check="$2" start=$SECONDS st i=0
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  while :; do
    st=$($check)
    case "$st" in DONE|SUCCEEDED|READY) printf '\r\e[K'; ok "$msg (${GR}$((SECONDS - start))s${R})"; return 0 ;;
      FAILED*|ERROR*|STOPPED|TIMEOUT|CANCELLED) printf '\r\e[K'; echo "${RD}✘ $msg: $st${R}"; return 1 ;; esac
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      printf "\r${OR}%s${R} %s ${D}[%s, %ss]${R}\e[K" "${frames[i++ % 10]}" "$msg" "$st" "$((SECONDS - start))"; sleep 0.3
    done
  done
}

out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

# ---------- Athena helper ----------
QID=""
athena() {   # athena "SQL"  -> runs it in our workgroup and prints a table
  QID=$(aws athena start-query-execution --work-group "$WG" \
        --query-execution-context Database="$DB" --query-string "$1" \
        --query QueryExecutionId --output text)
  spin "Athena query" athena_state
  aws athena get-query-results --query-execution-id "$QID" --output json \
    | jq -r '.ResultSet.Rows[] | [.Data[] | (.VarCharValue // "-")] | @tsv' \
    | awk -F'\t' -v h="$B$OR" -v r="$R" -v d="$D" '
        { for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } if (NF > n) n = NF }
        END { for (row = 1; row <= NR; row++) {
                line = ""
                for (i = 1; i <= n; i++) line = line sprintf("%-" w[i] "s", c[row, i]) (i < n ? "  " d "|" r "  " : "")
                print "   " (row == 1 ? h line r : line)
                if (row == 1) { u = ""; for (i = 1; i <= n; i++) u = u sprintf("%" w[i] "s", "") (i < n ? "-----" : ""); gsub(/ /, "-", u); print "   " d u r } } }'
}
athena_state() {
  local s; s=$(aws athena get-query-execution --query-execution-id "$QID" --query QueryExecution.Status.State --output text)
  [ "$s" = "SUCCEEDED" ] && echo DONE || echo "$s"
}
scanned() { aws athena get-query-execution --query-execution-id "$QID" --query QueryExecution.Statistics.DataScannedInBytes --output text; }

# ================= UP =================
up() {
  banner 0 "One CloudFormation stack builds everything"
  say "S3 bucket + sample data, Glue database, crawler, ETL job, Athena workgroup + saved queries"
  pause
  show "aws cloudformation deploy --stack-name $STACK --template-file infra/template.yaml --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset"
  echo
  show "aws cloudformation describe-stack-resources --stack-name $STACK --query 'StackResources[].[ResourceType,LogicalResourceId,ResourceStatus]' --output table"
  ok "Stack ${B}$STACK${R} is ready in ${B}$REGION${R}"
}

# ================= RUN =================
crawler_state() {
  local st last
  st=$(aws glue get-crawler --name "$CRAWLER" --query Crawler.State --output text)
  last=$(aws glue get-crawler --name "$CRAWLER" --query Crawler.LastCrawl.Status --output text 2>/dev/null || true)
  if [ "$st" = "READY" ] && [ "$CRAWL_STARTED" = "1" ]; then
    [ "$last" = "SUCCEEDED" ] && echo DONE || echo "FAILED ($last)"
  else echo "$st"; fi
}
RUN_ID=""
job_state() { aws glue get-job-run --job-name "$JOB" --run-id "$RUN_ID" --query JobRun.JobRunState --output text; }

run() {
  cd "$HERE"
  BUCKET=$(out BucketName)
  [ -z "$BUCKET" ] || [ "$BUCKET" = "None" ] && { echo "${RD}Stack not found. Run ./demo.sh up first.${R}"; exit 1; }

  # 1 ---------------------------------------------------------
  banner 1 "Raw CSV files sitting in S3"
  pause
  show "aws s3 ls s3://$BUCKET/raw/orders/"
  pause
  say "Let's peek inside one day. Watch the item and payment columns."
  show "aws s3 cp s3://$BUCKET/raw/orders/orders_2026-11-18.csv - | grep -E 'order_id|DABELI|vada pav|,0,' | head -6"
  pause

  # 2 ---------------------------------------------------------
  banner 2 "Crawler creates the orders table"
  say "The crawler is our detective: it reads the files and works out the columns."
  pause
  CRAWL_STARTED=0
  show "aws glue start-crawler --name $CRAWLER"
  sleep 3; CRAWL_STARTED=1
  spin "Crawling s3://$BUCKET/raw/orders/" crawler_state
  echo
  show "aws glue get-table --database-name $DB --name orders --query 'Table.StorageDescriptor.Columns[].[Name,Type]' --output table"
  pause

  # 3 ---------------------------------------------------------
  banner 3 "Athena shows us the mess"
  say "SQL, straight on CSV files in S3. How many ways is each item spelled?"
  pause
  athena "SELECT COUNT(DISTINCT item) AS spellings, COUNT(DISTINCT lower(trim(item))) AS real_items FROM orders"
  pause
  say "Just Vada Pav, with quotes so you can see the spaces:"
  athena "SELECT '\"' || item || '\"' AS item_as_typed, COUNT(*) AS times_seen FROM orders WHERE lower(trim(item)) = 'vada pav' GROUP BY item ORDER BY times_seen DESC"
  pause
  athena "SELECT SUM(CASE WHEN trim(payment_mode) = '' OR payment_mode IS NULL THEN 1 ELSE 0 END) AS blank_payment, SUM(CASE WHEN quantity = 0 THEN 1 ELSE 0 END) AS cancelled, COUNT(*) - COUNT(DISTINCT order_id) AS duplicates FROM orders"
  pause

  # 4 ---------------------------------------------------------
  banner 4 "Glue job cleans it into Parquet"
  say "The chef: trim + Title Case, fill blanks, drop cancelled and duplicate orders, add totals."
  pause
  show "sed -n '/def clean_orders/,/^def main/p' glue/clean_orders_job.py | head -34"
  pause
  show "aws glue start-job-run --job-name $JOB --query JobRunId --output text"
  RUN_ID=$(aws glue get-job-runs --job-name "$JOB" --max-items 1 --query 'JobRuns[0].Id' --output text | head -1)
  spin "Glue job $JOB" job_state
  echo
  say "One folder per day, Parquet files inside:"
  show "aws s3 ls s3://$BUCKET/processed/orders_clean/ --recursive --human-readable | awk '{print \$3, \$4, \$5}'"
  pause
  athena "SELECT COUNT(*) AS clean_rows, COUNT(DISTINCT item) AS items FROM orders_clean"
  pause

  # 5 ---------------------------------------------------------
  banner 5 "Athena answers the 4 questions"
  say "${B}Q1. What sells the most?${R}"
  athena "SELECT item, SUM(quantity) AS sold FROM orders_clean GROUP BY item ORDER BY sold DESC LIMIT 5"
  pause
  say "${B}Q2. What makes the most money?${R}"
  athena "SELECT item, CAST(SUM(total_amount) AS BIGINT) AS revenue_inr FROM orders_clean GROUP BY item ORDER BY revenue_inr DESC LIMIT 5"
  pause
  say "${B}Q3. When is rush hour?${R}"
  athena "SELECT order_hour, COUNT(*) AS orders, rpad('', CAST(COUNT(*) / 12 AS INTEGER), '#') AS chart FROM orders_clean GROUP BY order_hour ORDER BY order_hour"
  pause
  say "${B}Q4. UPI vs cash, who wins?${R}"
  athena "SELECT payment_mode, COUNT(*) AS orders, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS percent FROM orders_clean GROUP BY payment_mode ORDER BY orders DESC"
  pause

  # 6 ---------------------------------------------------------
  banner 6 "CSV vs Parquet: data scanned"
  say "Same question, two tables. Athena bills by data scanned."
  pause
  athena "SELECT SUM(quantity * unit_price) AS revenue FROM orders"
  CSV=$(scanned)
  athena "SELECT CAST(SUM(total_amount) AS BIGINT) AS revenue FROM orders_clean"
  PQ=$(scanned)
  echo
  awk -v c="$CSV" -v p="$PQ" -v b="$B" -v g="$GR" -v d="$D" -v r="$R" 'BEGIN {
    printf "   %sCSV     %8.1f KB scanned%s\n", b, c/1024, r
    printf "   %s%sParquet %8.1f KB scanned%s  %s(%.1fx less)%s\n", g, b, p/1024, r, d, (p > 0 ? c/p : 0), r }'
  echo
  ok "Store it. Clean it. Ask it. 🎉"
  say "Everything is also in the console: Glue (crawler, job, tables) and Athena (workgroup ${B}$WG${R}, Saved queries)."
}

# ================= DOWN =================
stack_gone() {
  local s; s=$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo GONE)
  case "$s" in GONE) echo DONE ;; DELETE_FAILED) echo FAILED ;; *) echo "$s" ;; esac
}
down() {
  banner 7 "Clean up: delete the stack"
  say "Deleting the stack removes the bucket (and all files), Glue, Athena and IAM roles."
  pause
  show "aws cloudformation delete-stack --stack-name $STACK"
  spin "Deleting stack $STACK" stack_gone
  ok "All gone. Nothing left to bill you. 💸"
}

case "${1:-}" in
  up) cd "$HERE"; up ;;
  run) run ;;
  down) down ;;
  all) cd "$HERE"; up; run; echo; read -rp "Delete everything now? [y/N] " a </dev/tty; [[ "$a" =~ ^[Yy] ]] && down ;;
  *) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
