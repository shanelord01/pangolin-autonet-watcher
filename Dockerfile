FROM docker:cli
RUN apk add --no-cache bash jq

COPY watcher.sh /watcher.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /watcher.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
