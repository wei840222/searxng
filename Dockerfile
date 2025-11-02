FROM python:3.14.0-trixie AS builder

WORKDIR /usr/local/searxng

COPY . .

ENV UV_PYTHON_DOWNLOADS=0
ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=from=ghcr.io/astral-sh/uv:python3.14-trixie-slim,source=/usr/local/bin/uv,target=/usr/local/bin/uv \
    set -eux -o pipefail; \
    uv venv; \
    uv pip install --requirements ./requirements.txt --requirements ./requirements-server.txt; \
    uv cache prune --ci; \
    find ./.venv/lib/ -type f -exec strip --strip-unneeded {} + || true; \
    find ./.venv/lib/ -type d -name "__pycache__" -exec rm -rf {} +; \
    find ./.venv/lib/ -type f -name "*.pyc" -delete; \
    python -m compileall -q -f -j 0 --invalidation-mode=unchecked-hash ./.venv/lib/; \
    find ./.venv/lib/python*/site-packages/*.dist-info/ -type f -name "RECORD" -exec sort -t, -k1,1 -o {} {} \;;

FROM python:3.14.0-slim-trixie

RUN set -x && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates brotli && \
    rm -rf /var/lib/apt/lists/*

ARG user=searxng
ARG group=searxng
ARG uid=977
ARG gid=977

RUN set -eux; \
    groupadd -g ${gid} ${group} \
    && useradd -l -u ${uid} -g ${gid} -m -s /bin/bash ${user}

RUN set -eux; \
    install -dm0555 -o ${uid} -g ${gid} /usr/local/searxng/; \
    install -dm0755 -o ${uid} -g ${gid} /etc/searxng/; \
    install -dm0755 -o ${uid} -g ${gid} /var/cache/searxng/

USER ${user}

WORKDIR /usr/local/searxng

COPY --chown=${uid}:${gid} --from=builder /usr/local/searxng/.venv ./.venv
COPY --chown=${uid}:${gid} --from=builder /usr/local/searxng/searx ./searx

RUN set -eux -o pipefail; \
    python -m compileall -q -f -j 0 --invalidation-mode=unchecked-hash ./searx/; \
    find ./searx/static/ -type f \
    \( -name "*.html" -o -name "*.css" -o -name "*.js" -o -name "*.svg" \) \
    -exec gzip -9 -k {} + \
    -exec brotli -9 -k {} + \
    -exec sh -c 'gzip --test "$1.gz" && brotli --test "$1.br"' _ {} \;

COPY --chown=${uid}:${gid} ./searx/settings.yml /etc/searxng/settings.yml

ENV CONFIG_PATH="/etc/searxng"
ENV DATA_PATH="/var/cache/searxng"
ENV PATH="/usr/local/searxng/.venv/bin:$PATH"

EXPOSE 8888

ENTRYPOINT ["gunicorn"]
CMD ["--workers=2", "--worker-class=gevent", "--threads=8", "--bind=0.0.0.0:8888", "searx.webapp:app"]
