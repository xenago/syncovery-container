import copy
import logging
import os
import re
import socket
import subprocess
import sys
import time
import uuid
from datetime import datetime

import statics

"""Prepare and launch the container
"""

# Container hostname, used to match rsyslog's stdout log format
HOSTNAME = socket.gethostname()

# Module logger; handlers are attached by configure_logging()
log = logging.getLogger("init")


class _InitFormatter(logging.Formatter):
    """Format records as `<ISO8601 timestamp> <hostname> init: <msg>`, matching rsyslog's stdout format.
    Warnings and errors carry a lowercase level tag (e.g. `init: error:`) so severity remains visible when Docker interleaves stdout and stderr in `docker logs`.
    """

    def format(self, record):
        timestamp = datetime.now().astimezone().isoformat(timespec="microseconds")
        tag = "init:" if record.levelno <= logging.INFO else f"init: {record.levelname.lower()}:"
        return f"{timestamp} {HOSTNAME} {tag} {record.getMessage()}"


class _BelowLevelFilter(logging.Filter):
    """Pass only records below `level`, so the stdout and stderr handlers never both emit a record."""

    def __init__(self, level):
        super().__init__()
        self.level = level

    def filter(self, record):
        return record.levelno < self.level


def configure_logging():
    """Split init logging across stdout and stderr by severity, mirroring the `*.err -/dev/stderr`
    routing rsyslog applies to the rest of the container's logs (see config/rsyslog).

    Done in-process rather than by logging to /dev/log, because init starts rsyslog itself and
    several fatal paths (e.g. machine-id validation) run before rsyslog exists; routing here keeps
    those errors on stderr regardless.
    """
    root = logging.getLogger()
    if root.handlers:
        return
    root.setLevel(logging.INFO)
    formatter = _InitFormatter()

    stdout_handler = logging.StreamHandler(sys.stdout)
    stdout_handler.addFilter(_BelowLevelFilter(logging.ERROR))
    stdout_handler.setFormatter(formatter)

    stderr_handler = logging.StreamHandler(sys.stderr)
    stderr_handler.setLevel(logging.ERROR)
    stderr_handler.setFormatter(formatter)

    root.addHandler(stdout_handler)
    root.addHandler(stderr_handler)


def is_value_true(value: str):
    """Determine if the given value is true. Case and whitespace-insensitive.
    True values: 1, t, true, y, yes
    All other values are interpreted as False.
    """
    # Strips all whitespace by splitting the lowercased string and rejoining it
    return "".join(value.lower().split()) in ("1", "t", "true", "y", "yes")


def short_circuit():
    """Stop the container with an error code
    """
    try:
        # Send SIGKILL (9) to PID 1 (tini) so the container exits immediately with code 137
        # https://github.com/PyCQA/bandit/issues/333
        process = subprocess.Popen(["kill", "-9", "1"])  # nosec
        process.wait()
    except Exception as e:
        log.error(f"Fatal error on exit: {str(e)}")
    exit(1)


def run_or_warn(cmd, description):
    """Run a command, warning (but not aborting) if it exits non-zero."""
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        log.warning(f"{description} failed (rc={result.returncode}): {result.stderr.strip()}")
    return result


def ensure_machine_id():
    """Validate and populate the persistent machine-id, refusing to start if it is not set up.

    Syncovery derives its credential-encryption key from /etc/machine-id, so it must be stable.
    The user provides it as a bind-mounted file.
    - An empty file is populated with a fresh id on first start
    - A valid file is reused untouched (it may be mounted read-only)
    - Anything else aborts startup (e.g. missing mount, unreadable, malformed, empty and unwritable)
    """
    path = statics.MACHINE_ID_PATH
    if not os.path.isfile(path):
        log.error(f"{path} is not a file. Mount a persistent file there in the container before starting "
                  f"(create it first with `touch`); see the README.")
        short_circuit()
    try:
        with open(path) as handle:
            current = handle.read().strip()
    except OSError as error:
        log.error(f"could not read {path}: {error}")
        short_circuit()
    # A machine-id is 32 lowercase hex characters with no separators
    if re.fullmatch(r"[0-9a-f]{32}", current):
        # Existing valid id: use it untouched, so a pre-populated file can be bind-mounted read-only
        log.info(f"Using persisted machine-id: {current}")
    elif current:
        log.error(f"{path} does not contain a valid machine-id (expected 32 hex characters).")
        short_circuit()
    else:
        # Empty file: generate a new id and persist it into the mounted file
        machine_id = uuid.uuid4().hex
        try:
            with open(path, "w") as handle:
                handle.write(machine_id + "\n")
        except OSError as error:
            log.error(f"could not populate {path} (is it mounted read-only?): {error}")
            short_circuit()
        # Match a normal system's read-only /etc/machine-id (0444). Only applied to a file we just
        # created (necessarily writable); a pre-existing id is left untouched so it can be mounted
        # read-only. Ownership is left as-is, and a failure here is a warning, not fatal.
        try:
            os.chmod(path, 0o444)
        except OSError as error:
            log.warning(f"could not set mode on {path}: {error}")
        log.info(f"Generated a new machine-id: {machine_id}")


def start_service(name: str):
    """Start a supervisor service and wait for it to become ready.
    :param name: The process/service name to start
    """
    log.info(f"Starting `{name}`...")
    process = subprocess.Popen(["supervisorctl", "start", name],
                               stdin=subprocess.PIPE,
                               universal_newlines=True)
    return_code = process.wait()
    # Validate that the service has actually started
    service_ready = False
    if name == "syncovery":
        # Syncovery's web port/bind are user-configurable so readiness is checked against the process
        for _ in range(statics.STARTUP_WAIT_SECONDS * 10):
            result = subprocess.run(["ps", "-e", "-o", "comm="], capture_output=True, text=True)
            if statics.SYNCOVERY_PROCESS_NAME in result.stdout.split():
                service_ready = True
                break
            time.sleep(0.1)
    elif name == "rsyslog":
        # rsyslog creates the /dev/log socket once it is up
        for _ in range(statics.STARTUP_WAIT_SECONDS * 10):
            if os.path.exists(statics.SYSLOG_SOCKET):
                service_ready = True
                break
            time.sleep(0.1)
    else:
        service_ready = True
    if not service_ready:
        log.error(f"unable to start {name} in {statics.STARTUP_WAIT_SECONDS} seconds")
        short_circuit()
    if return_code != 0:
        log.warning(f"Return code from {name} start: {return_code}")


def run():
    """Prepare and start services
    """
    # Set up logging before taking any actions
    configure_logging()
    # Load config/ENV vars and apply options
    log.info("Initializing container...")
    log.info("Checking configuration...")
    # Check every environment variable against the defaults
    #   - if any matching keys have different values, highlight them
    #   - if any keys are not present in the defaults, highlight them
    #   - censor output if the variable name looks like a password, key, or token
    env = copy.deepcopy(statics.DEFAULT_ENV)
    for variable, value in sorted(os.environ.items()):
        # Case-insensitive match; "pass" also covers WebPassword/WEBPASS
        censor = any(secret in variable.lower() for secret in ("key", "pass", "token", "secret", "cred"))
        shown = "***" if censor else value
        if variable in statics.DEFAULT_ENV:
            if value != statics.DEFAULT_ENV[variable]:
                log.info(f"Overriding default: {variable}={shown}")
                env[variable] = value
        elif variable in statics.IGNORED_ENV:
            # Known benign container/shell variable; ignore without warning
            continue
        else:
            log.warning(f"Unknown variable `{variable}={shown}`")

    # Set /etc/localtime from TZ and record it in /etc/timezone
    tz = env["TZ"]
    zoneinfo = os.path.join("/usr/share/zoneinfo", tz)
    if tz.startswith("/") or ".." in tz.split("/") or not os.path.isfile(zoneinfo):
        log.warning(f"invalid or unknown timezone {tz!r}; leaving /etc/localtime unchanged "
                    f"(the TZ env var still applies per-process)")
    else:
        run_or_warn(["ln", "-fs", zoneinfo, "/etc/localtime"], "Linking timezone")
        try:
            with open("/etc/timezone", "w") as handle:
                handle.write(tz + "\n")
        except OSError as error:
            log.warning(f"could not write /etc/timezone: {error}")

    # Ensure machine-id is persistent before Syncovery starts
    ensure_machine_id()

    # Set the Syncovery web server to listen on all interfaces if no config exists yet
    if not os.path.isfile(os.path.join(env["SYNCOVERY_HOME"], ".Syncovery/Syncovery.cfg")):
        run_or_warn(
            [os.path.join(env["SYNCOVERY_INSTALL_DIR"], "SyncoveryCL"), "SET", "/WEBSERVER=0.0.0.0"],
            "Setting Syncovery web server address")

    # Start services in the order defined in statics
    log.info("Starting services...")
    for service in statics.SERVICES_ORDER:
        # Check if the service is enabled in env
        if is_value_true(env[f"SC_SERVICE_{service.upper()}"]):
            start_service(service)

    log.info("Init complete.")


# Run the script if executed standalone
if __name__ == "__main__":
    run()
