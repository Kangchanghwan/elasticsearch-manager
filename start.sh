#!/bin/bash

# 환 경 변 수 설 정
################################
export AWS_ACCESS_KEY="-"
export AWS_SECRET_KEY="-"
export S3_BUCKET_NAME="wingchat-public-s3-dev"
export S3_BASE_PATH="back-up"

export ELASTICSEARCH_USER="elastic"
export ELASTICSEARCH_PASSWORD="-"
export ELASTICSEARCH_URL="http://localhost:9200"
export KIBANA_URL="http://localhost:5601"

export CRON="10 0 * * *" # 매일 0시 10분에 실행
export DAYS_TO_KEEP="0" # 로그를 보관할 일수 (ex. 0 -> 당일것만 , 1 -> 전일까지 , 2 -> 이틀전까지 )
JOB_ARGS=("$ELASTICSEARCH_USER" "$ELASTICSEARCH_PASSWORD" "$ELASTICSEARCH_URL" "$KIBANA_URL" "$DAYS_TO_KEEP" "zipkin-span-" "logstash-")
 # 5번째 이후는 인덱스 패턴 배열 ex) zipkin-span-2023-09-03 -> zipkin-span-
################################


####################
sudo yum install -y jq  # aws linux JSON 파싱 라이브러리
sudo yum install -y cronie # aws linux cron 라이브러리
####################

# docker image 받기전에 로그인
####################
aws configure set aws_access_key_id $AWS_ACCESS_KEY
aws configure set aws_secret_access_key $AWS_SECRET_KEY
aws configure set default.region ap-northeast-2
aws configure set default.output json

aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin 025229172592.dkr.ecr.ap-northeast-2.amazonaws.com
####################

# Docker Compose 파일 경로
COMPOSE_FILE="docker-compose.yml"

# Docker Compose를 사용하여 컨테이너 시작
docker-compose -f $COMPOSE_FILE up -d

echo "waiting for docker 30s"
sleep 30


script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
parse_to_arg=$(IFS=' ' && echo "${JOB_ARGS[*]}")

# docker에 접근하여 access key 와 secret key 를 설정합니다.
elasticsearch_command="\
  echo 's3 access_key setting'; \
  bin/elasticsearch-keystore remove s3.client.default.access_key; \
  echo '$AWS_ACCESS_KEY' | /usr/share/elasticsearch/bin/elasticsearch-keystore add --stdin s3.client.default.access_key; \
  echo 's3 secret_key setting'; \
  bin/elasticsearch-keystore remove s3.client.default.secret_key; \
  echo '$AWS_SECRET_KEY' | /usr/share/elasticsearch/bin/elasticsearch-keystore add --stdin s3.client.default.secret_key;"

# Elasticsearch 컨테이너 내에서 명령어 실행
docker exec -it elasticsearch /bin/bash -c "$elasticsearch_command"

# 설정을 적용
curl -X POST -u $ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD "$ELASTICSEARCH_URL/_nodes/reload_secure_settings?pretty"


# Elasticsearch 스냅샷 저장소 설정
snapshot_settings="\
  { \
    \"type\": \"s3\", \
    \"settings\": { \
      \"bucket\": \"$S3_BUCKET_NAME\", \
      \"client\": \"default\", \
      \"base_path\": \"$S3_BASE_PATH\" \
    } \
  }"
curl -X PUT -u $ELASTICSEARCH_USER:$ELASTICSEARCH_PASSWORD "$ELASTICSEARCH_URL/_snapshot/my_s3_repository?pretty" -H 'Content-Type: application/json' -d "$snapshot_settings"

echo "S3 스냅샷 저장소 생성 완료"

echo "job 설정"

# cron 시작
chmod +x "$script_dir/job.sh"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
(crontab -l ; echo "$CRON sh $script_dir/job.sh $parse_to_arg") | crontab -

echo "job 설정 완료"
