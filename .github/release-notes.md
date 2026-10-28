## Installation

This image adds ready-to-use document reading: PDF rendering and English/Polish
OCR, DOCX/HTML Markdown conversion, XLSX/PPTX text extraction, and embedded image
extraction including EMF/WMF. Use `doc-to-text`, `doc-extract-images` and
`pdf-to-png` (each supports `--help`). Python document libraries, Mammoth and
headless LibreOffice Writer are included. Custom builds can omit LibreOffice
with `--build-arg INSTALL_LIBREOFFICE=false`; see the README for size measurements
and conversion examples. Shared libraries for Playwright's headless Chromium are
also included (+272 MB); run `npx playwright install chromium` as `agent` to
download the browser.
The measured Linux/AMD64 image grows from 2.62 GB to 3.98 GB uncompressed
(+1.36 GB); omitting LibreOffice reduces it to 3.61 GB. Sizes vary with updates.

On a Linux host with Docker Engine and Docker Compose installed:

```bash
mkdir -p ~/agents-in-docker-with-dind/.ssh
cd ~/agents-in-docker-with-dind
curl -fsSLO https://github.com/sigmalko/agents-in-docker-with-dind/releases/download/RELEASE_TAG/docker-compose.yml
curl -fsSL https://github.com/sigmalko/agents-in-docker-with-dind/releases/download/RELEASE_TAG/env.example -o .env.example
cp .env.example .env
```

Copy your SSH **public** key to `.ssh/authorized_keys`, then run `chmod 600 .ssh/authorized_keys`. Edit `.env`, especially `GH_TOKEN`, `AGENT_REPOSITORY` and any ports you need to change. Keep the private key on your client computer.

```bash
docker compose pull
docker compose up -d
docker compose ps
ssh -i ~/.ssh/agents-in-docker -p 2222 agent@HOST_ADDRESS
```

The environment template selects this release's published image. If GHCR denies an anonymous pull, log in with an authorized token or ask the package administrator to configure visibility. The SSH and agent service ports bind all host IPv4 interfaces by default; configure your firewall.

DinD uses a privileged container and shares the host kernel. It separates the Docker daemons but is not a strong security boundary for untrusted code. See the [README](https://github.com/sigmalko/agents-in-docker-with-dind#readme) for security, persistence, networking and Redis examples.

The agent workspace is ephemeral, and DinD images, containers and volumes are stored in memory-backed temporary storage and are lost when DinD stops. The only outer named volume stores SSH host keys. Back up data before upgrading from older releases or recreating containers.
