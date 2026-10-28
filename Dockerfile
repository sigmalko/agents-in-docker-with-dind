ARG AGENT_BASE_IMAGE=ghcr.io/sigmalko/agents-in-docker:sha-8a5414950a08a3edb1702bf29455a6c6fec3f846
FROM docker:29-cli AS docker-cli
FROM ${AGENT_BASE_IMAGE}

ARG AGENT_BASE_IMAGE
# CI supplies version, revision and creation time through OCI labels.
# Clear the base image's build-specific values for local builds.
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=""
ARG IMAGE_CREATED=""
LABEL org.opencontainers.image.title="agents-in-docker-with-dind" \
      org.opencontainers.image.description="Run coding agents over SSH with their own Docker-in-Docker daemon." \
      org.opencontainers.image.url="https://github.com/sigmalko/agents-in-docker-with-dind" \
      org.opencontainers.image.documentation="https://github.com/sigmalko/agents-in-docker-with-dind#readme" \
      org.opencontainers.image.source="https://github.com/sigmalko/agents-in-docker-with-dind" \
      org.opencontainers.image.vendor="sigmalko" \
      org.opencontainers.image.base.name="${AGENT_BASE_IMAGE}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}"

COPY --from=docker-cli /usr/local/bin/docker /usr/local/libexec/dind/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/
COPY --chmod=755 docker-wrapper.sh /usr/local/bin/docker

ARG INSTALL_LIBREOFFICE=true
RUN apt-get update \
    && case "$INSTALL_LIBREOFFICE" in true|false) ;; *) exit 2 ;; esac \
    && apt-get install -y --no-install-recommends python3 vim nano ripgrep \
        poppler-utils pandoc tesseract-ocr tesseract-ocr-eng tesseract-ocr-pol \
        unzip zip imagemagick inkscape fonts-dejavu-core jq file \
        python3-pip python3-venv python3-fitz python3-pypdf python3-docx \
        python3-openpyxl python3-pil python3-lxml python3-bs4 \
        libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
        libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 \
        libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 \
        libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 \
        $(if [ "$INSTALL_LIBREOFFICE" = true ]; then echo libreoffice-writer-nogui libreoffice-core-nogui; fi) \
    && rm -rf /var/lib/apt/lists/*

COPY requirements-docs.txt /opt/requirements-docs.txt
# Reuse Debian libraries; pip supplies only packages absent from trixie.
RUN python3 -m venv --system-site-packages /opt/docs-venv \
    && /opt/docs-venv/bin/pip install --no-cache-dir -r /opt/requirements-docs.txt \
    && npm install -g mammoth@1.13.0 \
    && npm cache clean --force
ENV PATH="/opt/docs-venv/bin:${PATH}"
# SSH login shells reset PATH; select the same interpreter there as well.
RUN printf '#!/bin/sh\nexec /opt/docs-venv/bin/python3 "$@"\n' > /usr/local/bin/python3 \
    && chmod 755 /usr/local/bin/python3
COPY scripts/doc-tools.py /usr/local/lib/doc-tools.py
COPY --chmod=755 scripts/doc-to-text scripts/doc-extract-images scripts/pdf-to-png /usr/local/bin/

RUN install -d -o agent -g agent -m 0700 /home/agent/.codex /home/agent/.claude

# Both agent CLIs load these user-level instructions across workspaces.
COPY --chown=agent:agent AGENTS.md /home/agent/.codex/AGENTS.md
COPY --chown=agent:agent AGENTS.md /home/agent/.claude/CLAUDE.md
