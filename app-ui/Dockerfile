# syntax=docker/dockerfile:1.7
# Static UI on unprivileged nginx (runs as uid 101, listens on 8080).
# Pin by digest before prod:  ./scripts/pin-digests.sh
ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:1.27-alpine
FROM ${NGINX_IMAGE}
ARG GIT_SHA=dev
LABEL org.opencontainers.image.title="ui" \
      org.opencontainers.image.source="https://github.com/YOUR_USER/devops-chatbot" \
      org.opencontainers.image.revision="${GIT_SHA}"

USER root
# Remove the default page and anything we don't serve; create the optional include dir.
RUN rm -rf /usr/share/nginx/html/* /etc/nginx/conf.d/default.conf && mkdir -p /etc/nginx/extra
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --chown=101:101 public/ /usr/share/nginx/html/
# Default theme; Kubernetes overrides it per environment from a ConfigMap.
RUN printf '{"color":"teal","env":"local"}\n' > /usr/share/nginx/html/theme.json \
    && chown 101:101 /usr/share/nginx/html/theme.json
USER 101
EXPOSE 8080
