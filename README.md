# syncovery-container

Containerized build of [Syncovery](https://www.syncovery.com/), usable for a new deployment or to migrate an existing one.

This project provides Linux container tooling and is not affiliated with Syncovery, which is proprietary software licensed separately by Super Flexible Software GmbH.

## Components

- Syncovery
- rsyslog
- tini
- Supervisor
- Debian

### Image

The image is published to `ghcr.io/xenago/syncovery-container:latest` and is built for `amd64` & `arm64`.

[Supervisor](config/supervisor) is used as a basic service manager. It starts [`init.py`](app/init.py),
which performs startup tasks (timezone, machine-id, etc.) before starting Syncovery.

The container runs as `root` since Syncovery generally needs to read arbitrary source paths and preserve file ownership.

### Ports

- `8999` - Web UI
- `8943` - HTTPS Web UI (when enabled in Syncovery)
- `8889` - Cloud authentication
- `8949` - Remote

By default the compose stack publishes only the Web UI port (`8999`), bound to `127.0.0.1`.
The HTTPS, Cloud, and Remote ports are listed but commented out in [`docker-compose.yml`](docker-compose.yml).
Override the host binding with `SC_WEB_PORT` in `.env`
(for example `SC_WEB_PORT=192.168.1.50:8999` to expose on a specific LAN interface);
`SC_HTTPS_PORT` / `SC_CLOUD_PORT` / `SC_REMOTE_PORT` take effect if their compose lines are uncommented.
See [Configuration](#configuration) and [Proxy](#proxy) for details.

Syncovery's Guardian watchdog is a separate program intended for other deployment methods, and is not included.
Nothing listens on its port `8900` in this image.

## Deployment

These steps pull the prebuilt image and run Syncovery with persistent storage.
Docker Compose is required to follow these specific steps, but other methods are possible.

1. Download or clone the repository:

       git clone https://github.com/xenago/syncovery-container.git
       cd syncovery-container

2. Copy the environment template and modify if desired.
   Pay attention to the permanent data storage path!
   Locating it outside the cloned repo is a good idea to avoid accidental overwrites.

       cp .env.example .env

3. Create a persistent `machine-id` file.
   Syncovery requires it in some configurations, such as to encrypt stored credentials, so the container is configured to refuse to start without it:

       mkdir -p ./data && touch ./data/machine-id

   If `SC_DATA_DIR` is set, create the file under that path instead. See [Machine ID](#machine-id).

4. Start the stack, by default pulling the prebuilt image from GHCR:

       docker compose up -d

   To build the image locally instead of pulling, add `--build`:

       docker compose up -d --build

   Open the Syncovery web UI once the container reports healthy in `docker compose ps`.
   Syncovery's login page can misbehave over a loopback address (`localhost`/`127.0.0.1`), so reach it
   by a non-loopback address. Prefer binding the port to the host's specific LAN IP
   (e.g. `SC_WEB_PORT=192.168.1.50:8999`) and browsing to that address, or put a reverse proxy in front
   (see [Proxy](#proxy)). Binding a specific interface limits exposure; only use `0.0.0.0:8999`
   (all interfaces) if that exposure is acceptable, and change the default credentials first (next step).
   If the page doesn't load, monitor `docker compose logs -f`.

5. Log in with the Syncovery default credentials (username `default`, password `pass`) and change
   them immediately under `Settings > Misc, License > Change Login and Password...`.

Persistent data is stored under `./data` by default:
Syncovery's configuration and jobs in `./data/config`, and the machine-id in `./data/machine-id`.
Implement a backup strategy for both (see [Machine ID](#machine-id)).
`./data/tmp` is also mounted as Syncovery's temp scratch space (`/tmp`).

## Configuration

The compose stack reads variables from `.env` (see [`.env.example`](.env.example)):

- `SYNCOVERY_IMAGE`: optional, override the image reference, for example to pin a specific version
  tag or to build locally
- `SC_DATA_DIR`: optional, absolute path for persistent data (default `./data` beside the compose file)
- `TZ`: optional, timezone applied to the container and logs (default `Etc/UTC`)
- `SC_WEB_PORT` / `SC_HTTPS_PORT` / `SC_CLOUD_PORT` / `SC_REMOTE_PORT`: optional, host binding for each
  port (default `127.0.0.1:<port>`, localhost only). Only the web port is published by default;
  the other three take effect only once their lines are uncommented in [`docker-compose.yml`](docker-compose.yml).
  To reach a port from elsewhere, prefer a specific host interface (e.g. `192.168.1.50:<port>`).
  `0.0.0.0:<port>` or just `<port>` exposes on all interfaces and should be used only behind a proxy and after changing the default credentials.

By default the stack pulls the prebuilt image from `ghcr.io/xenago/syncovery-container`.
To refresh it later, run `docker compose pull` followed by `docker compose up -d`.
To pin a tag or SHA, set `SYNCOVERY_IMAGE` in `.env` (for example `ghcr.io/xenago/syncovery-container:11.16.4`).
To make local builds the persistent default so Compose never pulls, set
`SYNCOVERY_IMAGE=syncovery-container:local` in `.env` and use `--build`.

## Proxy

The container serves plain HTTP on port 8999, so put a reverse proxy in front of it and enable HTTPS.
The sample [`nginx-proxy.conf`](examples/nginx-proxy.conf) is a starting point; it also shows an IP allowlist,
since a backup admin UI should not be exposed to the public internet.
Customize it as needed for the individual setup.

## Syncovery commands

The image ships the `SyncoveryCL` binary, which also accepts commands directly.
One-shot commands that don't need the scheduler can run in a throwaway container with the same volumes mounted.
For example, to list the configured jobs:
```bash
docker compose run --rm syncovery-container /syncovery/SyncoveryCL /LIST
```

Commands that talk to the running scheduler should execute in the already-running container:
```bash
docker compose exec syncovery-container /syncovery/SyncoveryCL /STATUS
```

## Machine ID

Syncovery may use the host `/etc/machine-id` to encrypt stored credentials.
If the value changes, such stored credentials can no longer be decrypted.

The machine-id is supplied as a persistent file bind-mounted onto `/etc/machine-id`.
Create it before the first start with `touch ./data/machine-id`.
The container writes a fresh id into the empty file on first start, reuses it thereafter, and sets
it read-only (mode `0444`) to match a normal system's `/etc/machine-id`.
If the file is missing, unreadable, or malformed, the container refuses to start rather than
silently using a throwaway id.
Keep this file alongside `/config` and include both in your backups.

When migrating from an existing deployment, reuse that machine's id instead of letting a new one be generated. See the [migration steps](docs/README.md#migrating-an-existing-deployment) for details.

### Credential encryption mode

Whether the machine-id matters depends on Syncovery's credential encryption setting. Two modes work for a headless container:

- **Automatic Key Tied to This Computer**:
  The key is derived from the machine-id, so with the persistent `/etc/machine-id` above and the fixed `hostname` it works with no prompt.
- **Password Phrase**:
  The key comes from a separate passphrase then encrypted with the machine-id.
  To avoid typing it on every start, mount an empty file and point Syncovery at it in the settings - uncomment the mount in
  [`docker-compose.yml`](docker-compose.yml):

      - ${SC_DATA_DIR:-./data}/syncovery-password:/syncovery-password

  then set the passphrase and specify the file as `/syncovery-password` in the Syncovery UI.

Do not select "Password Phrase" without the mounted file.
It will prompt on every start, which a headless container cannot answer.
Syncovery would start up unable to decrypt the stored profile credentials.

## Updating Syncovery

Using the default prebuilt image, pull the newer release and redeploy:

    docker compose pull
    docker compose up -d

The published `latest` tag tracks the newest Syncovery release; pin a specific version with `SYNCOVERY_IMAGE` in `.env`.

To build a specific version locally instead:

1. Confirm no special upgrade steps are required for the jump:

   https://www.syncovery.com/detailed-version-history/

2. Update `SYNCOVERY_VERSION` in the [`Dockerfile`](Dockerfile) to the target release:

   https://www.syncovery.com/syncovery11linux/

3. Rebuild the image and redeploy:

       docker compose up -d --build

## Migrating an existing deployment

To use the container with an existing Syncovery install, see the [migration section](docs/README.md#migrating-an-existing-deployment) in the docs.

## License and redistribution

The tooling in this repository is licensed under the [MIT License](LICENSE).
This project is not affiliated with Syncovery.
Syncovery itself is downloaded at build time and has its own proprietary license.

There is no official Syncovery Docker image.
However, the Syncovery developer has publicly welcomed community images;
see the [References](#references) below and the full [archived forum thread](docs/references/syncovery-forum-docker-thread.html) for context.

## References

- [`ruepp-jenkins/docker-syncovery`](https://github.com/ruepp-jenkins/docker-syncovery) by [Stefan Ruepp](https://github.com/ruepp-jenkins)
  - MIT-licensed community project packaging Syncovery as a Docker container
  - Most successful and comprehensive project of this kind, and the recommended option
- [`Docker (unofficial) - Syncovery Support Forum`](https://www.syncovery.com/forum/viewtopic.php?t=13)
  - Thread started by Ruepp where the Syncovery developer Tobias welcomes community Docker images in the replies
  - The Syncovery forum is not captured by the Internet Archive's Wayback Machine,
    so a copy of the webpage HTML is archived here at
    [`docs/references/syncovery-forum-docker-thread.html`](docs/references/syncovery-forum-docker-thread.html)
