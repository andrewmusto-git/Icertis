#!/usr/bin/env bash
# install_icertis.sh — One-command installer for the Icertis → Veza OAA integration
#
# Usage (interactive):
#   curl -fsSL https://raw.githubusercontent.com/andrewmusto-git/Icertis/main/integrations/icertis/install_icertis.sh | bash
#
# Usage (non-interactive / CI):
#   ICERTIS_BASE_URL=https://... \
#   ICERTIS_TOKEN_URL=https://... \
#   ICERTIS_CLIENT_ID=... \
#   ICERTIS_CLIENT_SECRET=... \
#   ICERTIS_SCOPE=api://... \
#   VEZA_URL=https://... \
#   VEZA_API_KEY=... \
#   bash install_icertis.sh --non-interactive

set -uo pipefail

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
INTEGRATION_SLUG="icertis"
INSTALL_DIR="/opt/VEZA/${INTEGRATION_SLUG}-veza"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
LOGS_DIR="${INSTALL_DIR}/logs"
REPO_URL="${REPO_URL:-https://github.com/andrewmusto-git/Icertis}"
BRANCH="${BRANCH:-main}"
INTEGRATION_SUBDIR="integrations/${INTEGRATION_SLUG}"
NON_INTERACTIVE=false
OVERWRITE_ENV=false
SETUP_CRON=false
RUN_NOW=false

# Detect OS package manager
PKG_MGR=""
OS_ID=""
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    OS_ID=$(. /etc/os-release && echo "${ID:-}")
fi
if command -v dnf  &>/dev/null; then PKG_MGR="dnf"
elif command -v yum &>/dev/null; then PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then PKG_MGR="apt-get"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

_install_pkg() {
    local pkg="$1"
    info "Installing ${pkg}..."
    case "${PKG_MGR}" in
        dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null 2>&1 ;;
        apt-get) apt-get install -y "${pkg}" >/dev/null 2>&1 ;;
        *) die "No supported package manager found (dnf/yum/apt-get)" ;;
    esac
}

check_python_version() {
    local py_bin="${1:-python3}"
    local ver
    ver=$("${py_bin}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null) || return 1
    local major minor
    major=$(echo "${ver}" | cut -d. -f1)
    minor=$(echo "${ver}" | cut -d. -f2)
    [[ "${major}" -ge 3 && "${minor}" -ge 8 ]]
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --overwrite-env)   OVERWRITE_ENV=true   ;;
        --setup-cron)      SETUP_CRON=true       ;;
        --run-now)         RUN_NOW=true          ;;
        --install-dir)     INSTALL_DIR="$2"; SCRIPTS_DIR="${INSTALL_DIR}/scripts"; LOGS_DIR="${INSTALL_DIR}/logs"; shift ;;
        --repo-url)        REPO_URL="$2"; shift ;;
        --branch)          BRANCH="$2"; shift ;;
        *) warn "Unknown flag: $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------
info "Checking system dependencies..."

command -v git &>/dev/null || _install_pkg git

command -v python3 &>/dev/null || _install_pkg python3

python3 -m pip --version &>/dev/null || _install_pkg python3-pip

# curl — skip on Amazon Linux if curl-minimal already present
if ! command -v curl &>/dev/null; then
    if [[ "${OS_ID}" == "amzn" ]]; then
        warn "Skipping curl install on Amazon Linux (curl-minimal conflict)"
    else
        _install_pkg curl
    fi
fi

# python3-venv — python3-venv package does not exist on Amazon Linux 2023 / RHEL 9+
if ! python3 -m venv --help &>/dev/null 2>&1; then
    case "${PKG_MGR}" in
        dnf|yum) _install_pkg python3-virtualenv ;;
        apt-get) _install_pkg python3-venv ;;
    esac
fi

check_python_version python3 || die "Python 3.8 or higher is required. Please upgrade Python and re-run."
ok "Python $(python3 -c 'import sys; print(sys.version.split()[0])')"

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
info "Creating directory layout under ${INSTALL_DIR}..."
mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}"
ok "Directories created"

# ---------------------------------------------------------------------------
# Download integration files
# ---------------------------------------------------------------------------
info "Cloning repository (${REPO_URL}, branch: ${BRANCH})..."
tmp_dir=$(mktemp -d)
GIT_TERMINAL_PROMPT=0 git clone \
    --branch "${BRANCH}" \
    --depth 1 \
    --single-branch \
    "${REPO_URL}" "${tmp_dir}" 2>/dev/null || die "git clone failed — check REPO_URL and BRANCH"

src_dir="${tmp_dir}/${INTEGRATION_SUBDIR}"
[[ -f "${src_dir}/icertis.py" ]] || die "icertis.py not found in cloned repo at ${src_dir}"

cp -f "${src_dir}/icertis.py"        "${SCRIPTS_DIR}/"
cp -f "${src_dir}/requirements.txt"  "${SCRIPTS_DIR}/"
cp -f "${src_dir}/preflight_icertis.sh" "${SCRIPTS_DIR}/" 2>/dev/null || true
chmod +x "${SCRIPTS_DIR}/preflight_icertis.sh" 2>/dev/null || true
rm -rf "${tmp_dir}"
ok "Integration files installed to ${SCRIPTS_DIR}"

# ---------------------------------------------------------------------------
# Python virtual environment
# ---------------------------------------------------------------------------
info "Creating Python virtual environment..."
python3 -m venv "${SCRIPTS_DIR}/venv" || die "Failed to create virtual environment"
"${SCRIPTS_DIR}/venv/bin/pip" install --upgrade pip --quiet
"${SCRIPTS_DIR}/venv/bin/pip" install -r "${SCRIPTS_DIR}/requirements.txt" --quiet || \
    die "Dependency installation failed"
ok "Virtual environment ready"

# ---------------------------------------------------------------------------
# .env file
# ---------------------------------------------------------------------------
env_file="${SCRIPTS_DIR}/.env"

if [[ -f "${env_file}" && "${OVERWRITE_ENV}" == "false" ]]; then
    warn ".env already exists — skipping (use --overwrite-env to replace)"
else
    info "Configuring .env..."

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        # Require all values from environment in non-interactive mode
        : "${ICERTIS_API_URL:?ICERTIS_API_URL must be set}"
        : "${ICERTIS_BUSINESS_API_URL:?ICERTIS_BUSINESS_API_URL must be set}"
        : "${ICERTIS_TOKEN_URL:?ICERTIS_TOKEN_URL must be set}"
        : "${ICERTIS_CLIENT_ID:?ICERTIS_CLIENT_ID must be set}"
        : "${ICERTIS_CLIENT_SECRET:?ICERTIS_CLIENT_SECRET must be set}"
        : "${VEZA_URL:?VEZA_URL must be set}"
        : "${VEZA_API_KEY:?VEZA_API_KEY must be set}"
        scope_val="${ICERTIS_SCOPE:-api://6c49748d-db77-4577-b9d0-e31330bc889c/.default}"
    else
        # Interactive prompts — read from /dev/tty so curl|bash piping works
        IFS= read -r -p "Icertis API URL for users/groups (e.g. https://yourcompany-api.icertis.com): " ICERTIS_API_URL </dev/tty
        IFS= read -r -p "Icertis Business API URL for org units (e.g. https://yourcompany-business-api.icertis.com): " ICERTIS_BUSINESS_API_URL </dev/tty
        IFS= read -r -p "OAuth2 token URL (e.g. https://login.microsoftonline.com/<tid>/oauth2/v2.0/token): " ICERTIS_TOKEN_URL </dev/tty
        IFS= read -r -p "OAuth2 client ID: " ICERTIS_CLIENT_ID </dev/tty
        IFS= read -r -s -p "OAuth2 client secret: " ICERTIS_CLIENT_SECRET </dev/tty; echo >/dev/tty
        scope_default="api://6c49748d-db77-4577-b9d0-e31330bc889c/.default"
        IFS= read -r -p "OAuth2 scope [${scope_default}]: " scope_input </dev/tty
        scope_val="${scope_input:-${scope_default}}"
        IFS= read -r -p "Veza URL (e.g. https://yourcompany.veza.com): " VEZA_URL </dev/tty
        IFS= read -r -s -p "Veza API key: " VEZA_API_KEY </dev/tty; echo >/dev/tty
    fi

    cat > "${env_file}" <<EOF
# Icertis Source Configuration
ICERTIS_API_URL=${ICERTIS_API_URL}
ICERTIS_BUSINESS_API_URL=${ICERTIS_BUSINESS_API_URL}
ICERTIS_TOKEN_URL=${ICERTIS_TOKEN_URL}
ICERTIS_CLIENT_ID=${ICERTIS_CLIENT_ID}
ICERTIS_CLIENT_SECRET=${ICERTIS_CLIENT_SECRET}
ICERTIS_SCOPE=${scope_val}

# Veza Configuration
VEZA_URL=${VEZA_URL}
VEZA_API_KEY=${VEZA_API_KEY}

# OAA Provider Settings
# PROVIDER_NAME=Icertis
# DATASOURCE_NAME=Icertis
EOF
    chmod 600 "${env_file}"
    ok ".env written and secured (chmod 600)"
fi

# ---------------------------------------------------------------------------
# Cron job setup
# ---------------------------------------------------------------------------
if [[ "${NON_INTERACTIVE}" == "false" && "${SETUP_CRON}" == "false" ]]; then
    IFS= read -r -p "[SETUP] Set up daily cron job to push data to Veza at 02:00? [y/N]: " _cron_answer </dev/tty
    [[ "${_cron_answer,,}" == "y" ]] && SETUP_CRON=true
fi

if [[ "${SETUP_CRON}" == "true" ]]; then
    info "Setting up cron job..."
    cron_wrapper="${SCRIPTS_DIR}/run_icertis.sh"
    cat > "${cron_wrapper}" <<'CRONEOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPTS_DIR}/venv/bin/activate"
python3 "${SCRIPTS_DIR}/icertis.py" --env-file "${SCRIPTS_DIR}/.env"
CRONEOF
    chmod +x "${cron_wrapper}"
    CRON_USER=$(whoami)
    CRON_FILE="/etc/cron.d/icertis-veza"
    if [[ -w /etc/cron.d ]]; then
        echo "0 2 * * * ${CRON_USER} ${cron_wrapper} >> ${LOGS_DIR}/cron.log 2>&1" > "${CRON_FILE}"
        chmod 644 "${CRON_FILE}"
        ok "Cron job created: ${CRON_FILE} (daily at 02:00 as ${CRON_USER})"
    else
        warn "Cannot write to /etc/cron.d — run as root or add manually:"
        warn "  echo \"0 2 * * * ${CRON_USER} ${cron_wrapper} >> ${LOGS_DIR}/cron.log 2>&1\" | sudo tee ${CRON_FILE}"
    fi
fi

# ---------------------------------------------------------------------------
# Optional first-run push
# ---------------------------------------------------------------------------
if [[ "${NON_INTERACTIVE}" == "false" && "${RUN_NOW}" == "false" ]]; then
    IFS= read -r -p "[SETUP] Run the integration now to perform the initial push to Veza? [y/N]: " _run_answer </dev/tty
    [[ "${_run_answer,,}" == "y" ]] && RUN_NOW=true
fi

if [[ "${RUN_NOW}" == "true" ]]; then
    info "Running integration — initial push to Veza..."
    if "${SCRIPTS_DIR}/venv/bin/python3" "${SCRIPTS_DIR}/icertis.py" --env-file "${env_file}"; then
        ok "Initial push to Veza completed successfully"
    else
        warn "Integration run finished with errors — review logs in ${LOGS_DIR}"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN} Icertis → Veza OAA integration installed!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo ""
echo "  Install path : ${INSTALL_DIR}"
echo "  Scripts      : ${SCRIPTS_DIR}"
echo "  Logs         : ${LOGS_DIR}"
echo ""
echo "  Next steps:"
echo ""
echo "    cd ${SCRIPTS_DIR}"
echo "    source venv/bin/activate"
echo ""
echo "    # Dry-run (validate without pushing to Veza):"
echo "    python3 icertis.py --dry-run --save-json"
echo ""
echo "    # Live push:"
echo "    python3 icertis.py"
echo ""
echo "    # Run preflight checks:"
echo "    bash preflight_icertis.sh --all"
echo ""
echo "  Automation:"
echo ""
echo "    # To push data to Veza on a schedule, ensure the cron job is in place:"
echo "    cat /etc/cron.d/icertis-veza"
echo ""
echo "    # Or re-run the installer with --setup-cron --run-now to set it up now:"
echo "    bash install_icertis.sh --setup-cron --run-now"
echo ""
