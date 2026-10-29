# syntax=docker/dockerfile:1

FROM cgr.dev/chainguard/python:latest-dev@sha256:e51f00c88b6dc695e822b75cb403e40ab9459bd66524ed0f476dfc8366de8794 AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN python -m venv --without-pip /app/venv
ENV PATH="/app/venv/bin:${PATH}"

COPY requirements.txt .
RUN --mount=type=secret,id=pkg_token,target=/run/secrets/pkg_token,mode=0400 \
    test -s /run/secrets/pkg_token

RUN --mount=type=cache,id=pip-cache,target=/home/nonroot/.cache/pip,uid=65532,gid=65532,sharing=locked \
    /usr/bin/pip --python /app/venv/bin/python install -r requirements.txt

# ===== Stage 2: test (builder + pytest, used by CI integration tests only) =====
FROM builder AS test

COPY requirements-dev.txt .
RUN --mount=type=cache,id=pip-cache,target=/home/nonroot/.cache/pip,uid=65532,gid=65532,sharing=locked \
    /usr/bin/pip --python /app/venv/bin/python install -r requirements-dev.txt

COPY pytest.ini app.py test_app.py ./

USER 65532:65532
ENTRYPOINT ["python", "-m", "pytest"]
CMD ["-v"]

FROM cgr.dev/chainguard/python:latest@sha256:012106301931c182063868dee31dc36a0d278267ec837176ba1774a320fa1bbb AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/venv/bin:${PATH}"

WORKDIR /app

COPY --from=builder /app/venv /app/venv
COPY app.py .

USER 65532:65532

EXPOSE 5000

ENTRYPOINT ["/app/venv/bin/gunicorn"]
CMD ["--bind", "0.0.0.0:5000", "--workers", "2", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "app:app"]
