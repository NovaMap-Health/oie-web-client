# syntax=docker/dockerfile:1
#
# NetBird variant of the web administrator. Always joins the mesh at startup
# (no on/off flag). Build the vanilla image first, then:
#
#   docker build -f docker/netbird/Dockerfile \
#     --build-arg BASE_IMAGE=oie-web-client:local \
#     -t oie-web-client-netbird:local .
#
# Required at runtime (file or env): setup key, management URL.
# See docker/netbird/entrypoint.sh.

ARG BASE_IMAGE=oie-web-client:local
FROM ${BASE_IMAGE}

USER root
RUN apk add --no-cache bash curl jq ca-certificates \
 && (apk add --no-cache netbird \
     || apk add --no-cache --repository https://dl-cdn.alpinelinux.org/alpine/v3.23/community netbird) \
 && mkdir -p /config/netbird /config/urls /var/lib/netbird \
 && chown -R node:node /var/lib/netbird

COPY docker/netbird/entrypoint.sh /config/entrypoint.sh
RUN chmod 555 /config/entrypoint.sh

USER node

# NetBird connect + Node boot; companion uses ~40s of waits before the app.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.WEBADMIN_PORT||3030)+'/').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"

ENTRYPOINT ["/bin/bash", "/config/entrypoint.sh"]
