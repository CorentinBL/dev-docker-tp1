# syntax=docker/dockerfile:1

FROM cgr.dev/chainguard/python:latest-dev@sha256:894aed3297d91283e1fc4c542f5374a4b5f3726134fda7c94eaa539342be1e05 AS builder

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
RUN --mount=type=cache,id=pip-cache,target=/root/.cache/pip,sharing=locked \
    /usr/bin/pip --python /app/venv/bin/python install -r requirements-dev.txt

COPY pytest.ini app.py test_app.py ./

USER 65532:65532
ENTRYPOINT ["python", "-m", "pytest"]
CMD ["-v"]

FROM cgr.dev/chainguard/python:latest@sha256:b6248c85ba9b97e1e61b30197f309cc4d21661f889fefa5268f0a7bc530dad46 AS runtime

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
