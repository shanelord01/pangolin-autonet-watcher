FROM alpine:3.20

RUN apk add --no-cache bash jq docker-cli

COPY watcher.sh /watcher.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /watcher.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
