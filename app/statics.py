"""Static values
"""

# Store the default/expected environment variables
DEFAULT_ENV = {
    # ========
    # Runtime environment configuration options
    "SC_SERVICE_SYNCOVERY": "1",  # Run Syncovery
    "SC_SERVICE_RSYSLOG": "1",  # Run rsyslog
    # ========
    # Values baked-in at build time or expected in the environment, indicated by: *Preset*
    # These should typically not be changed
    "HOME": "/root",  # *Preset* User homedir is root for the service manager
    "HOSTNAME": "syncovery-container",  # *Preset* Default hostname
    "LC_CTYPE": "C.UTF-8",  # *Preset* Expected default locale for ctype/multibyte functions
    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",  # *Preset* Default system PATH
    "PWD": "/var/run",  # *Preset* Working directory
    "PYTHONDONTWRITEBYTECODE": "1",  # *Preset* Skip writing .pyc bytecode cache (in Dockerfile)
    "PYTHONIOENCODING": "UTF-8",  # *Preset* Python IO encoding to UTF-8 (in Dockerfile)
    "PYTHONUNBUFFERED": "1",  # *Preset* Python stdout/stderr routing (in Dockerfile)
    "SUPERVISOR_ENABLED": "1",  # *Preset* Set by Supervisor in the environment
    "SUPERVISOR_SERVER_URL": "unix:///dev/shm/supervisor.sock",  # *Preset* Supervisor server URL (in supervisord.conf)
    "SUPERVISOR_PROCESS_NAME": "init",  # *Preset* Name of init script service process (in init_service.conf)
    "SUPERVISOR_GROUP_NAME": "init",  # *Preset* Name of init script service group (in init_service.conf)
    "SYNCOVERY_HOME": "/config",  # *Preset* Application homedir (in Dockerfile)
    "SYNCOVERY_INSTALL_DIR": "/syncovery",  # *Preset* Application bindir (in Dockerfile)
    "TZ": "Etc/UTC",  # *Preset* Timezone (in Dockerfile)
}

# Environment variables that may appear and can be ignored without warning
IGNORED_ENV = {
    "SYNCOVERY_IMAGE",  # compose image override (only present if passed via env_file or -e)
    "SC_DATA_DIR",      # compose data path (only present if passed via env_file or -e)
    "SHLVL",            # shell nesting level (set by shell)
    "_",                # last command executed (set by shell)
    "OLDPWD",           # previous working directory (set by shell)
    "TERM",             # terminal type (only present when a TTY is attached)
    "LANG",             # locale
    "LANGUAGE",         # locale
    "LC_ALL",           # locale
    "container",        # set by some container runtimes
}

# Syslog socket created by rsyslog when it comes up; init waits for it to appear
SYSLOG_SOCKET = "/dev/log"

# Persistent machine-id
# Syncovery encrypts stored credentials with /etc/machine-id, so it should be consistent over time.
# The user bind-mounts a file there (see the README); init refuses to
# start if it is missing, unreadable, malformed, or unwritable when empty.
MACHINE_ID_PATH = "/etc/machine-id"

# Syncovery process name, used for readiness check (see start_service).
SYNCOVERY_PROCESS_NAME = "SyncoveryCL"

# Set the startup order
# - Evaluated top-to-bottom for startup
# - Shutdown occurs in reverse order, bottom-up
# - Case-insensitive list
SERVICES_ORDER = [
    "rsyslog",
    "syncovery"
]

# Used as a delay timeout in the init
STARTUP_WAIT_SECONDS = 10
