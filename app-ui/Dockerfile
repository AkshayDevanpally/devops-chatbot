# syntax=docker/dockerfile:1.7
# Static UI on unprivileged nginx (runs as uid 101, listens on 8080).
# Pin by digest before prod:  ./scripts/pin-digests.sh
ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:1.30-alpine

# Journal page data: docs/ (passed as the extra build context "docs") -> journal.json.
# Build-only stage: Python never reaches the final image.
FROM python:3.12-alpine AS journal
COPY journal/build_journal.py /build_journal.py
# "docs" is a named build context (--build-context docs=docs), not a stage: hadolint can't see it.
# hadolint ignore=DL3022
COPY --from=docs . /docs
RUN python3 -I /build_journal.py /docs /out/journal.json

FROM ${NGINX_IMAGE}
ARG GIT_SHA=dev
LABEL org.opencontainers.image.title="ui" \
      org.opencontainers.image.source="https://github.com/YOUR_USER/devops-chatbot" \
      org.opencontainers.image.revision="${GIT_SHA}"

USER 0
# Pull Alpine security fixes the base image hasn't been rebuilt with yet (keeps Trivy green).
# hadolint ignore=DL3017
RUN apk upgrade --no-cache
# Remove the default page and anything we don't serve; create the optional include dir.
RUN rm -rf /usr/share/nginx/html/* /etc/nginx/conf.d/default.conf && mkdir -p /etc/nginx/extra
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --chown=101:101 public/ /usr/share/nginx/html/
COPY --from=journal --chown=101:101 /out/journal.json /usr/share/nginx/html/journal/journal.json
# Default theme; Kubernetes overrides it per environment from a ConfigMap.
RUN printf '{"color":"teal","env":"local"}\n' > /usr/share/nginx/html/theme.json \
    && chown 101:101 /usr/share/nginx/html/theme.json
USER 101
EXPOSE 8080
