# syntax=docker/dockerfile:1.7
# Pin bases by digest before going to prod:  ./scripts/pin-digests.sh
ARG PYTHON_IMAGE=python:3.12-slim

# ---------- build stage: install deps into a venv ----------
FROM ${PYTHON_IMAGE} AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /venv
WORKDIR /build
COPY requirements.txt .
RUN /venv/bin/pip install -r requirements.txt

# ---------- runtime stage: only the venv + code, non-root ----------
FROM ${PYTHON_IMAGE}
ARG GIT_SHA=dev
LABEL org.opencontainers.image.title="chat-api" \
      org.opencontainers.image.source="https://github.com/YOUR_USER/devops-chatbot" \
      org.opencontainers.image.revision="${GIT_SHA}"
ENV PATH="/venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN groupadd -g 10001 app && useradd -u 10001 -g app -s /usr/sbin/nologin -M app
WORKDIR /srv
COPY --from=build /venv /venv
COPY --chown=10001:10001 app ./app
USER 10001:10001
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--forwarded-allow-ips", "*", "--no-server-header"]
