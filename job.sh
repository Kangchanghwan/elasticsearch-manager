#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/job.log"

log() {
  local log_message="$1"
  local timestamp=$(date +"%Y-%m-%d %T")
  echo "$timestamp - $log_message">>"$LOG_FILE"
}



# 들어온 인수값을 인덱스로 받는다.
ELASTICSEARCH_USER="$1"
ELASTICSEARCH_PASSWORD="$2"
ELASTICSEARCH_URL="$3"
KIBANA_URL="$4"
DAYS_TO_KEEP="$5" # 로그를 보관할 일수 (ex. 0 -> 당일것만 , 1 -> 전일까지 , 2 -> 이틀전까지 )

# 인덱스 패턴을 가변 배열로 받기
index_patterns=()
shift 5 # 이미 처리한 5개의 인수를 삭제

# 남은 인수를 가변 배열로 추가
for arg; do
  index_patterns+=("$arg")
done


echo "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD"
echo "$ELASTICSEARCH_URL"

# 등록된 저장소 중 첫번째 저장소 이름을 가져옴
response=$(curl -s -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" -XGET "$KIBANA_URL/api/snapshot_restore/repositories")
repository_name=$(echo "$response" | jq -r '.repositories[0].name')

# 삭제할 인덱스를 담을 배열선언
will_delete_indices_array=()


echo "=== $(date) ==="


# 인덱스들을 패턴 검색
for index_pattern in "${index_patterns[@]}"; do
  # getting all indices
  INDICES=$(curl -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" -s "$ELASTICSEARCH_URL"/_cat/indices 2>&1 | grep "$index_pattern" | awk '{print $3}') # 인덱스 패턴 검색 중 3번째 값만 추출
  log "INFO: Indices matching pattern $index_pattern: $INDICES"
  DATE=$(date -u +%Y-%m-%d -d "$DAYS_TO_KEEP day ago")
  log "INFO: Date to compare: $DATE"
  DATE_INT=$(date -d $DATE +%s)

  yearReg='(201[0-9]|202[0-9]|203[0-9])' # Allows a number between 2010 and 2039
  monthReg='(0[1-9]|1[0-2])'             # Allows a number between 00 and 12
  dayReg='(0[1-9]|1[0-9]|2[0-9]|3[0-1])' # Allows a number between 00 and 31
  regDate="($yearReg\\.$monthReg\\.$dayReg|$yearReg-$monthReg-$dayReg)"

  while read -r line; do
    log "-------------------------------------------"
    log "INFO: Index: $line"
    # Finding date in index name matching 20YY.MM.DD like 2016.09.19
    if [[ $line =~ $regDate ]]; then
      INDEX_DATE=${BASH_REMATCH[0]}
      INDEX_DATE="${INDEX_DATE//./-}"
      log "INFO: Found date: $INDEX_DATE"
    else
      log 'WARNING: No date found in index name - index ignored.'
    fi

    # if index date older than today minus $DAYS_TO_KEEP days ago then we delete
    if [[ $INDEX_DATE ]]; then
      INDEX_DATE_INT=$(date -d $INDEX_DATE +%s)

      if [ $DATE_INT -gt $INDEX_DATE_INT ]; then
        log "INFO: $line is about to be deleted."
        will_delete_indices_array+=("$line")
      else
        log "INFO: $line is less than $DAYS_TO_KEEP days old, doing nothing."
      fi
    fi
  done <<<"$INDICES"
done <<<"$index_pattern"




indices_to_snapshot=$(
  IFS=,
  echo "${will_delete_indices_array[*]}"
)

if [ -n "$indices_to_snapshot" ]; then
  log "INFO: Creating snapshot for all indices: $indices_to_snapshot"
  snapshot_name="snapshot_$(date +%Y%m%d%H%M%S)" # You can customize the snapshot name logic here.
  log "INFO: snapshot_name : $snapshot_name"
  snapshot_url="http://localhost:9200/_snapshot/$repository_name/$snapshot_name?wait_for_completion=true&pretty"
  log "INFO: snapshot_url : $snapshot_url"

  # JSON data generation
  snapshot_request='{
    "indices": "'"$indices_to_snapshot"'",
    "ignore_unavailable": true,
    "include_global_state": false,
    "metadata": {
      "taken_by": "system",
      "taken_because": "backup"
    }
  }'
  log "$snapshot_request"

  # API request to create a snapshot
  curl -X PUT -u elastic:dev2log1! "$snapshot_url" -H 'Content-Type: application/json' -d "$snapshot_request"
  log "INFO: * Snapshot creation completed *"
else
  log "WARNING: No indices to delete, skipping snapshot creation."
fi

for e in "${will_delete_indices_array[@]}"; do
  log "DELETE: $e index deletion..."
  curl -u "$ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD" -XDELETE "$ELASTICSEARCH_URL/$e"
  log "DELETE: $e index deletion completed!"
done

log " * Expired index deletion completed *"