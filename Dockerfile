# syntax=docker/dockerfile:1

# ===== Stage 1: builder (Chainguard Python -dev: pip + shell, never shipped) =====
FROM cgr.dev/chainguard/python:latest-dev@sha256:894aed3297d91283e1fc4c542f5374a4b5f3726134fda7c94eaa539342be1e05 AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# venv without pip: the installer stays in the builder and never reaches the runtime
RUN python -m venv --without-pip /app/venv
ENV PATH="/app/venv/bin:${PATH}"

# Dependency manifest first: code changes don't invalidate the pip layer
COPY requirements.txt .
RUN /usr/bin/pip --python /app/venv/bin/python install --no-cache-dir -r requirements.txt

# ===== Stage 2: test (builder + pytest, used by CI integration tests only) =====
FROM builder AS test

COPY requirements-dev.txt .
RUN /usr/bin/pip --python /app/venv/bin/python install --no-cache-dir -r requirements-dev.txt

COPY pytest.ini app.py test_app.py ./

USER 65532:65532
ENTRYPOINT ["python", "-m", "pytest"]
CMD ["-v"]

# ===== Stage 3: runtime (Chainguard Python: no shell, no pip, no compiler) =====
FROM cgr.dev/chainguard/python:latest@sha256:b6248c85ba9b97e1e61b30197f309cc4d21661f889fefa5268f0a7bc530dad46 AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/venv/bin:${PATH}"

WORKDIR /app

COPY --from=builder /app/venv /app/venv
COPY app.py .

# Dedicated unprivileged account (nonroot) provided by the Chainguard image
USER 65532:65532

EXPOSE 5000

ENTRYPOINT ["/app/venv/bin/gunicorn"]
CMD ["--bind", "0.0.0.0:5000", "--workers", "2", "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "app:app"]
