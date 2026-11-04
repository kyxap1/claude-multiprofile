# 3.2 matches macOS /bin/bash; run with 5 as well.
ARG BASH_VERSION=5
FROM bash:${BASH_VERSION}
RUN apk add --no-cache jq perl-utils
COPY . /repo
CMD ["bash", "/repo/test/test.sh"]
