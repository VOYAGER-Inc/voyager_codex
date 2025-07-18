FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    curl git jq gh diffutils bash \
    && apt-get clean

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
