# agents-in-docker-with-dind

Run coding agents over SSH with their own Docker daemon. This project extends [agents-in-docker](https://github.com/sigmalko/agents-in-docker) with Docker CLI, Docker Compose, and Docker-in-Docker (DinD). Agents can build images and start their own services, such as Redis or containerized MCP servers.

## Architecture and security

The agent image includes Python 3 (`python3`), Vim (`vim` and `vi`), Nano (`nano`), and ripgrep (`rg`) for editing and searching workspace files.

```text
Host Docker
├── agent (SSH, Codex, Claude, Docker CLI and Compose)
└── dind (a separate Docker daemon)
    └── its own images, networks, volumes and containers (e.g. Redis, MCP)

agent and dind share a network namespace
agent Docker CLI ── loopback TCP 127.0.0.1:2375 ──> dockerd in dind
```

The host Docker socket is not mounted. Host `docker ps` shows the outer agent and DinD containers, but not containers created by the inner daemon. `docker ps` inside the agent shows the inner containers, not the host's containers.

**This separates Docker resources; it is not a strong security boundary.** DinD runs with `privileged`, shares the host kernel, and can potentially compromise the host. A host administrator can access its processes and data. Use trusted agents and code; use a dedicated VM or another stronger isolation boundary for untrusted workloads. The daemon listens without TLS only on loopback in the network namespace shared by the agent and DinD. Processes in that namespace can control the inner daemon; the API is not published on the host. Explicit Docker host or context settings override the default connection.

## Install from a release

Requirements: Linux with Docker Engine, the Docker Compose v2 plugin and support for privileged containers; an SSH key pair; access to the GHCR image; and sufficient memory (and swap, if configured) for nested images. Restricted VPS containers and runtimes may not support the required cgroups, networking or filesystems.

On the Docker host, download the two release assets:

```bash
mkdir -p ~/agents-in-docker-with-dind/.ssh
cd ~/agents-in-docker-with-dind
curl -fsSLO https://github.com/sigmalko/agents-in-docker-with-dind/releases/latest/download/docker-compose.yml
curl -fsSL https://github.com/sigmalko/agents-in-docker-with-dind/releases/latest/download/env.example -o .env.example
cp .env.example .env
```

Copy your SSH **public** key into `.ssh/authorized_keys` on the host and restrict its permissions:

```bash
chmod 600 .ssh/authorized_keys
```

Keep the corresponding private key on your client computer. Edit `.env`, especially `GH_TOKEN` and `AGENT_REPOSITORY`, and change any occupied ports. Keep `.env` and private keys out of Git. Start the environment:

```bash
docker compose pull
docker compose up -d
docker compose ps
```

Wait until the `dind` service reports `healthy` before using Docker in the agent. Docker Engine may warn about the unencrypted loopback API; future Engine versions may require a configuration change.

Connect from the client computer:

```bash
ssh -i ~/.ssh/agents-in-docker -p 2222 agent@HOST_ADDRESS
```

The release includes a standalone Compose file generated from the pinned upstream configuration and this project's overlay. The environment template points to the matching versioned agent image. GitHub sanitizes leading dots in release asset names, so the template is uploaded as `env.example` and downloaded as `.env.example`.

`SSH_PORT` and `SERVICE_PORT` publish ports `2222` and `7777` on all host IPv4 interfaces by default, as in the upstream project. Configure your firewall and SSH access accordingly. `DIND_SERVICE_PORT` publishes the DinD service port on host loopback only. See the [upstream README](https://github.com/sigmalko/agents-in-docker#readme) for details on the agent environment and credentials.

A newly published GHCR package may be private. If the image cannot be pulled anonymously, an administrator can change its visibility in package settings, or an authorized user can log in to GHCR with a token that has `read:packages` and access to the package. A public package can be pulled anonymously. Alternatively, build the image locally as described below.

The image installs this project's English-language instructions in the agent's `~/.codex/AGENTS.md` and `~/.claude/CLAUDE.md`, so both CLIs receive the same default guidance across workspaces. The instructions are guidance, not an enforcement mechanism; an explicit user request can override them. These files are part of the agent image and are recreated with the container.

## Verify Docker and run Redis

On the host, `docker ps` lists the outer containers. After connecting over SSH as `agent`:

```bash
docker version                 # Server is the DinD daemon
docker compose version
mkdir -p /workspaces/redis-demo
cd /workspaces/redis-demo
cat > compose.yaml <<'YAML'
services:
  redis:
    image: redis:7-alpine
    ports:
      - "7778:6379"
YAML
docker compose up -d
docker compose exec redis redis-cli ping  # PONG
docker ps                                  # lists the inner Redis container
```

The agent can reach that port at `127.0.0.1:7778`, for example:

```bash
node -e 'const s=require("net").connect(7778,"127.0.0.1",()=>s.write("*1\r\n$4\r\nPING\r\n")); s.on("data",b=>{console.log(b.toString());s.end()})'
```

Inner container ports are published in the network namespace shared by the agent and DinD. The outer Compose file maps host `127.0.0.1:${DIND_SERVICE_PORT:-7778}` to port `7778` in that namespace. Therefore Redis is available on host loopback at `127.0.0.1:7778` by default. The inner port mapping must listen on `0.0.0.0`, as above. Other ports need additional outer Compose mappings; `docker run -p` inside the agent does not by itself publish them on the host. Remove the outer mapping if host access is not needed.

Inner bind mounts are resolved in the DinD container, and the agent workspace is not shared with it. A bind mount of `/workspaces` in an inner container therefore does not expose the agent workspace. A `docker build` context is sent to the daemon by the client. To transfer files into a running inner container, use `docker cp`; for persistent files during a DinD session, use an inner Docker volume and copy data into it.

For an MCP server using stdio, configure the MCP client to launch `docker run --rm -i ...`. For an HTTP MCP server, publish an inner port and configure the client with `http://127.0.0.1:PORT`. The image, arguments and authentication depend on the server. Services on the same inner Compose network can also reach each other by service name.

Clean up the example with `docker compose down` in `/workspaces/redis-demo`.

## Data and cleanup

As in the upstream project, `/workspaces` lives in the agent container's writable layer and is lost when that container is recreated or removed. Back up your work outside the container before recreating it. The only outer named volume stores SSH host keys; `docker compose down -v` deletes those keys.

DinD uses a temporary filesystem for `/var/lib/docker`, so its images, containers, build cache and inner volumes are lost whenever the DinD container stops, including during a restart. This storage consumes memory and potentially swap; large builds can exhaust available resources. Agent CLI configuration and authentication in the agent container also disappear when it is recreated.

Older versions of this project used named `workspace` and `dind-data` volumes. Upgrading and recreating the services leaves those old volumes on the host, but the new configuration no longer mounts them. Back up or migrate any needed data before upgrading, and remove old volumes only after verifying their contents are no longer needed.

## Development and upstream dependency

Clone with the submodule to develop or build locally:

```bash
git clone --recurse-submodules https://github.com/sigmalko/agents-in-docker-with-dind.git
cd agents-in-docker-with-dind
cp .env.example .env
mkdir -p .ssh
# Copy an SSH public key to .ssh/authorized_keys and edit .env.
./compose up -d --build
```

If the repository was cloned without submodules, run `git submodule update --init --recursive`. The `./compose` wrapper combines `upstream/docker-compose.yml` with `compose.dind.yml`, resolving `.env` and relative paths from this repository. For example, use `./compose logs dind`, `./compose restart` or `./compose down`.

`upstream/` is a [Git submodule](https://git-scm.com/docs/gitsubmodules) pinned to a specific commit. This reuses the upstream Compose file without maintaining a duplicate in the repository. `IMAGE` selects the base image during a local build and defaults to the SHA tag matching that upstream commit. `DIND_IMAGE` selects the resulting or published agent image. To update upstream, run `git submodule update --remote upstream`, review the change and update the base image tag in `.env.example`, `Dockerfile` and `compose.dind.yml` after checking compatibility. In particular, verify the `agent` service, `/workspaces`, SSH configuration, and the shared-network DinD connection. A submodule or README link alone does not guarantee an entry in GitHub's [dependency graph](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependency-graph).

## Images, tests and releases

### Reading business documents

The image includes Poppler (`pdftotext`, `pdftoppm`, `pdfimages`), Pandoc,
Tesseract with English and Polish language data, ImageMagick, Inkscape, ZIP tools,
DejaVu fonts, `jq`, and `file`. LibreOffice Writer and Core use Debian's `-nogui`
packages for headless conversion; Calc, Impress, Java and the full desktop suite
are not installed. Set `docker build --build-arg INSTALL_LIBREOFFICE=false .`
to omit LibreOffice; the default is `true` for ready-to-use DOCX rendering.

```bash
doc-to-text manual.pdf /tmp/manual-text
doc-to-text manual.docx /tmp/manual-docx  # Markdown plus extracted media
doc-extract-images manual.docx /tmp/manual-images
pdf-to-png manual.pdf 1 3 110 --outdir /tmp/manual-pages
soffice --headless '-env:UserInstallation=file:///tmp/lo-profile' --convert-to pdf --outdir /tmp/manual-pdf manual.docx
```

Each helper supports `--help`. Outputs default to `/tmp/doc-out/<basename>`;
use separate directories for unrelated files with the same basename. Sources
are never modified, and output directories containing the source are rejected.
PDF text preserves layout and falls back to English/Polish OCR separately for
each page without text. DOCX headings, tables and media use Pandoc; XLSX exports
cached cell values by sheet (formulas are not recalculated), and PPTX exports
slide text and tables. HTML converts to Markdown. Embedded Office/PDF images
become PNGs at most 1600 pixels per side; page renders retain the requested DPI
(110 by default, 600 maximum). Complex layouts and OCR still need visual review.

Python imports (`fitz`, `pypdf`, `pdfplumber`, `docx`, `openpyxl`, `pptx`, `PIL`,
`lxml`, `bs4`) work with `python3 -I` as `agent`, with no activation or installation.
Available Debian packages are reused; the two missing libraries are pinned in
`requirements-docs.txt` and installed in `/opt/docs-venv` with system-site-packages.
The pinned global `mammoth@1.13.0` CLI provides an alternative DOCX-to-HTML path.
Optional `pdfjs-dist` is omitted because Poppler and PyMuPDF cover PDF reading.
Inkscape is heavier than `libwmf-bin`, but supports both EMF and WMF; `libwmf-bin`
alone only covers WMF. The helper invokes Inkscape without a display server.

`tests/documents.sh` generates all sample documents at runtime and verifies text,
page-level OCR, images, EMF/WMF conversion and imports as `agent`. The full smoke
test also prints the uncompressed image size into the GitHub workflow summary.

Measured locally on Linux/AMD64 on 2026-10-27 (`docker image inspect`, decimal MB,
uncompressed; registry downloads are smaller):

| Build | Size | Change from the previous image |
| --- | ---: | ---: |
| Before document tooling | 2,625 MB | — |
| Document tooling, without LibreOffice | 3,605 MB | +981 MB |
| Document tooling, default LibreOffice enabled | 3,981 MB | +1,356 MB |

Headless Writer adds about 376 MB over the document-only build. It is enabled
because rendering DOCX to PDF lets agents inspect page layout and screenshots;
text and embedded-image extraction still work when it is disabled. The cost is
worthwhile for the default document-reading use case, while custom deployments
can omit it. Sizes vary with architecture and Debian security updates.

### Browser automation

The image includes the shared libraries required by Playwright's Chromium
(including `libgbm1` and `libasound2t64`), so `npx playwright install chromium`
as `agent` is enough to run headless browser tests. Browsers themselves are not
preinstalled; Playwright downloads them into `~/.cache/ms-playwright`, which is
lost when the container is recreated. Fonts, `xvfb` and headed mode are not
covered; use `npx playwright install-deps` as root if you need the full set.
`tests/browser.sh` installs `@playwright/test` and Chromium as `agent`, then
tests a page served from a DinD container, including a screenshot and a PDF.
Measured on 2026-10-28 like the table above, the default image grows from
3,981 MB to 4,253 MB (+272 MB), mostly Mesa and LLVM pulled in by `libgbm1`.

[GitHub Actions](.github/workflows/build-release.yml) runs real SSH and DinD integration tests for pull requests, pushes to `main` and version tags. It verifies Docker, Compose, Redis, networking, file transfer, mounts and separation of the host and inner container lists, including the standalone release configuration. Functional tests run on AMD64; ARM64 images are built using emulation.

A successful push to `main` publishes `ghcr.io/sigmalko/agents-in-docker-with-dind:latest` and a `sha-...` image tag for `linux/amd64` and `linux/arm64`. A successful push of a tag in the form `vMAJOR.MINOR.PATCH` pointing to a commit on `main` publishes the matching image tag without `v` and creates a GitHub Release with only `docker-compose.yml` and `env.example`. The generated Compose file contains the pinned upstream configuration and uses the published image; the template selects the release's image version. The release description contains installation instructions.

The image contains OCI labels for this project and its base image. Published images also receive version, revision and creation-time labels from GitHub Actions. Local builds use `dev` as the version and leave revision and creation time empty unless supplied with the `IMAGE_VERSION`, `IMAGE_REVISION` and `IMAGE_CREATED` build arguments.

To create a new release after verifying `main`:

```bash
git tag v1.2.3
git push origin v1.2.3
```

Choose an unused version for subsequent releases. The release job runs only after tests and image publication succeed. Jobs use the built-in `GITHUB_TOKEN` with the permissions each job needs.

For additional background, see [Docker Engine security](https://docs.docker.com/engine/security/) and the [official Docker image](https://hub.docker.com/_/docker).
