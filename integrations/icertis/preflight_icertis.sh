#!/usr/bin/env bash
# preflight_icertis.sh — Pre-deployment validation for the Icertis → Veza OAA integration
#
# Usage:
#   bash preflight_icertis.sh --all          # run all checks non-interactively
#   bash preflight_icertis.sh                # interactive menu
#
# Exit codes: 0 = all checks passed, 1 = one or more checks failed

set -uo pipefail

# ---------------------------------------------------------------------------
# Color helpers & counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

TESTS_PASSED=0; TESTS_FAILED=0; TESTS_WARNING=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/preflight_$(date +%Y%m%d_%H%M%S).log"
ALL_MODE=false

pass()  { echo -e "${GREEN}  ✓${NC} $*"; echo "[PASS]  $*" >> "${LOG_FILE}"; ((TESTS_PASSED++)) || true; }
fail()  { echo -e "${RED}  ✗${NC} $*"; echo "[FAIL]  $*" >> "${LOG_FILE}"; ((TESTS_FAILED++))  || true; }
warn()  { echo -e "${YELLOW}  ⚠${NC} $*"; echo "[WARN]  $*" >> "${LOG_FILE}"; ((TESTS_WARNING++)) || true; }
info()  { echo -e "${BLUE}  ℹ${NC} $*"; echo "[INFO]  $*" >> "${LOG_FILE}"; }

section() {
    echo ""
    echo -e "${BLUE}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "" >> "${LOG_FILE}"
    echo "=== $* ===" >> "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) ALL_MODE=true ;;
        *) echo "Unknown flag: $1" >&2 ;;
    esac
    shift
done

# Initialise log
{
    echo "Icertis → Veza OAA Preflight — $(date)"
    echo "Script dir: ${SCRIPT_DIR}"
    echo "Log: ${LOG_FILE}"
} > "${LOG_FILE}"

# ---------------------------------------------------------------------------
# Check 1: System Requirements
# ---------------------------------------------------------------------------
check_system_requirements() {
    section "1. System Requirements"

    # Python 3.9+
    if command -v python3 &>/dev/null; then
        py_ver=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        major=$(echo "${py_ver}" | cut -d. -f1)
        minor=$(echo "${py_ver}" | cut -d. -f2)
        if [[ "${major}" -ge 3 && "${minor}" -ge 9 ]]; then
            pass "Python ${py_ver}"
        else
            fail "Python ${py_ver} — requires 3.9+"
        fi
    else
        fail "python3 not found"
    fi

    # pip3
    if command -v pip3 &>/dev/null || python3 -m pip --version &>/dev/null 2>&1; then
        pass "pip3 available"
    else
        fail "pip3 not found"
    fi

    # curl
    if command -v curl &>/dev/null; then
        pass "curl $(curl --version | head -1 | awk '{print $2}')"
    else
        warn "curl not found (recommended for connectivity checks)"
    fi

    # jq (optional)
    if command -v jq &>/dev/null; then
        pass "jq $(jq --version)"
    else
        warn "jq not found (optional — useful for inspecting JSON payloads)"
    fi
}

# ---------------------------------------------------------------------------
# Check 2: Python Dependencies
# ---------------------------------------------------------------------------
check_python_deps() {
    section "2. Python Dependencies"

    local py_bin="${SCRIPT_DIR}/venv/bin/python"
    [[ -x "${py_bin}" ]] || py_bin="python3"
    info "Using Python: ${py_bin}"

    local deps=("oaaclient" "dotenv" "requests" "urllib3")
    for dep in "${deps[@]}"; do
        if "${py_bin}" -c "import ${dep}" 2>/dev/null; then
            ver=$("${py_bin}" -c "import importlib.metadata; print(importlib.metadata.version('${dep}'))" 2>/dev/null || echo "unknown")
            pass "${dep} ${ver}"
        else
            fail "${dep} — not importable (run: pip install -r requirements.txt)"
        fi
    done
}

# ---------------------------------------------------------------------------
# Check 3: Configuration
# ---------------------------------------------------------------------------
check_configuration() {
    section "3. Configuration"

    local env_file="${SCRIPT_DIR}/.env"

    if [[ -f "${env_file}" ]]; then
        pass ".env file exists: ${env_file}"
        local perms
        perms=$(stat -c "%a" "${env_file}" 2>/dev/null || stat -f "%Lp" "${env_file}" 2>/dev/null || echo "?")
        if [[ "${perms}" == "600" ]]; then
            pass ".env permissions: ${perms}"
        else
            warn ".env permissions: ${perms} — recommend chmod 600 ${env_file}"
        fi
        # shellcheck disable=SC1090
        set -a; source "${env_file}" 2>/dev/null; set +a
    else
        fail ".env not found — copy .env.example to .env and fill in values"
        return
    fi

    local required_vars=("ICERTIS_API_URL" "ICERTIS_BUSINESS_API_URL" "ICERTIS_TOKEN_URL" "ICERTIS_CLIENT_ID" "ICERTIS_CLIENT_SECRET" "ICERTIS_SCOPE" "VEZA_URL" "VEZA_API_KEY")
    for var in "${required_vars[@]}"; do
        val="${!var:-}"
        if [[ -z "${val}" ]]; then
            fail "${var} — not set"
        elif echo "${val}" | grep -qiE '^your_|^your-|^<'; then
            fail "${var} — still contains placeholder value"
        else
            # Mask sensitive values
            if echo "${var}" | grep -qiE 'PASSWORD|KEY|TOKEN|SECRET'; then
                display="${val:0:4}****"
            else
                display="${val}"
            fi
            pass "${var} = ${display}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Check 4: Network Connectivity
# ---------------------------------------------------------------------------
check_network() {
    section "4. Network Connectivity"

    local api_url="${ICERTIS_API_URL:-}"
    local business_api_url="${ICERTIS_BUSINESS_API_URL:-}"
    local veza_url="${VEZA_URL:-}"

    if [[ -z "${api_url}" ]]; then
        fail "ICERTIS_API_URL not set — skipping Icertis API connectivity check"
    else
        local host
        host=$(echo "${api_url}" | sed -E 's|https?://([^/:]+).*|\1|')
        info "Testing TCP ${host}:443..."
        if timeout 5 bash -c "echo >/dev/tcp/${host}/443" 2>/dev/null; then
            pass "Icertis API host reachable: ${host}:443"
        else
            fail "Cannot reach ${host}:443 — check network/firewall"
        fi
    fi

    if [[ -z "${business_api_url}" ]]; then
        fail "ICERTIS_BUSINESS_API_URL not set — skipping Business API connectivity check"
    else
        local biz_host
        biz_host=$(echo "${business_api_url}" | sed -E 's|https?://([^/:]+).*|\1|')
        info "Testing TCP ${biz_host}:443..."
        if timeout 5 bash -c "echo >/dev/tcp/${biz_host}/443" 2>/dev/null; then
            pass "Icertis Business API host reachable: ${biz_host}:443"
        else
            fail "Cannot reach ${biz_host}:443 — check network/firewall"
        fi
    fi

    if [[ -z "${veza_url}" ]]; then
        fail "VEZA_URL not set — skipping Veza connectivity check"
    else
        local veza_host
        veza_host=$(echo "${veza_url}" | sed -E 's|https?://([^/:]+).*|\1|')
        info "Testing HTTPS ${veza_host}:443..."
        local http_code
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 "${veza_url}/" 2>/dev/null || echo "000")
        if [[ "${http_code}" != "000" ]]; then
            pass "Veza HTTPS reachable: ${veza_url} (HTTP ${http_code})"
        else
            fail "Cannot reach Veza HTTPS: ${veza_url}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Check 5: API Authentication
# ---------------------------------------------------------------------------
check_api_auth() {
    section "5. API Authentication"

    local token_url="${ICERTIS_TOKEN_URL:-}"
    local client_id="${ICERTIS_CLIENT_ID:-}"
    local client_secret="${ICERTIS_CLIENT_SECRET:-}"
    local scope="${ICERTIS_SCOPE:-api://6c49748d-db77-4577-b9d0-e31330bc889c/.default}"
    local veza_url="${VEZA_URL:-}"
    local veza_api_key="${VEZA_API_KEY:-}"

    if [[ -z "${token_url}" || -z "${client_id}" || -z "${client_secret}" ]]; then
        fail "Icertis OAuth2 credentials incomplete — skipping auth test"
    else
        info "Testing OAuth2 token request to ${token_url}..."
        local http_code response_body
        response_body=$(curl -sk -w "\n%{http_code}" \
            -X POST "${token_url}" \
            -d "grant_type=client_credentials" \
            -d "client_id=${client_id}" \
            -d "client_secret=${client_secret}" \
            -d "scope=${scope}" 2>/dev/null)
        http_code=$(echo "${response_body}" | tail -1)
        body=$(echo "${response_body}" | head -n -1)
        if [[ "${http_code}" == "200" ]] && echo "${body}" | grep -q '"access_token"'; then
            pass "Icertis OAuth2 token obtained (HTTP ${http_code})"
        else
            fail "Icertis OAuth2 auth failed (HTTP ${http_code}): ${body:0:200}"
        fi
    fi

    if [[ -z "${veza_url}" || -z "${veza_api_key}" ]]; then
        fail "Veza credentials incomplete — skipping Veza auth test"
    else
        info "Testing Veza API key at ${veza_url}..."
        local http_code
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -H "Authorization: Bearer ${veza_api_key}" \
            "${veza_url}/api/v1/providers" 2>/dev/null || echo "000")
        if [[ "${http_code}" == "200" ]]; then
            pass "Veza API key valid (HTTP ${http_code})"
        else
            fail "Veza API key test failed (HTTP ${http_code}) — check VEZA_API_KEY"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Check 6: Veza Endpoint Access
# ---------------------------------------------------------------------------
check_veza_access() {
    section "6. Veza Endpoint Access"

    local veza_url="${VEZA_URL:-}"
    local veza_api_key="${VEZA_API_KEY:-}"

    if [[ -z "${veza_url}" || -z "${veza_api_key}" ]]; then
        fail "Veza credentials not set — skipping"
        return
    fi

    local http_code
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -X POST "${veza_url}/api/v1/assessments/query" \
        -H "Authorization: Bearer ${veza_api_key}" \
        -H "Content-Type: application/json" \
        -d '{"query": {"providers": {"type": "EXACT", "value": "Icertis"}}}' 2>/dev/null || echo "000")

    if [[ "${http_code}" == "200" || "${http_code}" == "400" ]]; then
        pass "Veza Query API accessible (HTTP ${http_code})"
    else
        warn "Veza Query API returned HTTP ${http_code} — may lack read permissions"
    fi
}

# ---------------------------------------------------------------------------
# Check 7: Deployment Structure
# ---------------------------------------------------------------------------
check_deployment() {
    section "7. Deployment Structure"

    local script="${SCRIPT_DIR}/icertis.py"
    if [[ -f "${script}" && -r "${script}" ]]; then
        pass "icertis.py exists and is readable"
    else
        fail "icertis.py not found at ${script}"
    fi

    local venv_py="${SCRIPT_DIR}/venv/bin/python"
    if [[ -x "${venv_py}" ]]; then
        pass "venv exists: ${venv_py}"
    else
        warn "venv not found — run: python3 -m venv ${SCRIPT_DIR}/venv && ${SCRIPT_DIR}/venv/bin/pip install -r requirements.txt"
    fi

    if [[ -w "${SCRIPT_DIR}" ]]; then
        pass "logs directory writable: ${SCRIPT_DIR}"
    else
        fail "${SCRIPT_DIR} is not writable"
    fi

    info "Running as: $(whoami)"
    pass "Running user: $(whoami)"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Preflight Summary"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}Passed:${NC}   ${TESTS_PASSED}"
    echo -e "  ${YELLOW}Warnings:${NC} ${TESTS_WARNING}"
    echo -e "  ${RED}Failed:${NC}   ${TESTS_FAILED}"
    echo -e "  Log:      ${LOG_FILE}"
    echo ""
    {
        echo ""
        echo "SUMMARY: passed=${TESTS_PASSED} warnings=${TESTS_WARNING} failed=${TESTS_FAILED}"
    } >> "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
interactive_menu() {
    while true; do
        echo ""
        echo -e "${BLUE}Icertis → Veza OAA Preflight${NC}"
        echo "  1) System requirements"
        echo "  2) Python dependencies"
        echo "  3) Configuration"
        echo "  4) Network connectivity"
        echo "  5) API authentication"
        echo "  6) Veza endpoint access"
        echo "  7) Deployment structure"
        echo "  8) Run all checks"
        echo "  9) Display current config"
        echo " 10) Generate .env template"
        echo " 11) Install dependencies"
        echo "  q) Quit"
        echo ""
        IFS= read -r -p "Select option: " choice </dev/tty
        case "${choice}" in
            1) check_system_requirements ;;
            2) check_python_deps         ;;
            3) check_configuration       ;;
            4) check_network             ;;
            5) check_api_auth            ;;
            6) check_veza_access         ;;
            7) check_deployment          ;;
            8)
                check_system_requirements
                check_python_deps
                check_configuration
                check_network
                check_api_auth
                check_veza_access
                check_deployment
                print_summary
                ;;
            9)
                echo ""
                local env_file="${SCRIPT_DIR}/.env"
                [[ -f "${env_file}" ]] && grep -v 'SECRET\|KEY\|PASSWORD\|TOKEN' "${env_file}" || echo "No .env found"
                ;;
            10)
                cp -n "${SCRIPT_DIR}/.env.example" "${SCRIPT_DIR}/.env" 2>/dev/null && \
                    echo ".env created from .env.example — please fill in your values" || \
                    echo ".env already exists"
                ;;
            11)
                python3 -m venv "${SCRIPT_DIR}/venv"
                "${SCRIPT_DIR}/venv/bin/pip" install -r "${SCRIPT_DIR}/requirements.txt"
                echo "Dependencies installed"
                ;;
            q|Q) break ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
echo "" >> "${LOG_FILE}"

if [[ "${ALL_MODE}" == "true" ]]; then
    check_system_requirements
    check_python_deps
    check_configuration
    check_network
    check_api_auth
    check_veza_access
    check_deployment
    print_summary
    [[ "${TESTS_FAILED}" -eq 0 ]] && exit 0 || exit 1
else
    interactive_menu
fi
