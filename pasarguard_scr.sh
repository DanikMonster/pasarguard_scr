#!/usr/bin/env bash
set -e

# ============================================================================
#  PasarGuard Installer & Manager (pasarguard_scr)
#
#  INSTALL MODE:  Interactive installer with configurable parameters
#  MANAGE MODE:   Post-install management (domain, port, SSL, templates, etc.)
#
#  Usage:
#    pasarguard_scr                — main menu (install or manage)
#    pasarguard_scr install        — run installer directly
#    pasarguard_scr manage         — open management menu
#    pasarguard_scr change-domain  — change panel domain & SSL
#    pasarguard_scr change-port    — change panel port
#    pasarguard_scr change-uri     — change dashboard URI path
#    pasarguard_scr change-sub     — change subscription page HTML
#    pasarguard_scr change-home    — change home page HTML
#    pasarguard_scr change-admin   — change admin password
#    pasarguard_scr status         — show panel status
#    pasarguard_scr restart        — restart panel
#    pasarguard_scr logs           — show panel logs
#
#  Tested on Ubuntu 20.04 / 22.04 / 24.04, Debian 11/12
# ============================================================================

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── globals ──────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/pasarguard"
DATA_DIR="/var/lib/pasarguard"
TEMPLATES_DIR="$DATA_DIR/templates"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
SCRIPT_INSTALL_PATH="/usr/local/bin/pasarguard_scr"
SCRIPT_URL="https://raw.githubusercontent.com/DanikMonster/pasarguard_scr/main/pasarguard_scr.sh"

PANEL_DOMAIN=""
PANEL_PORT="8000"
DB_ENGINE="sqlite"
SSL_MODE="none"
SSL_CERT_PATH=""
SSL_KEY_PATH=""
ADMIN_USER="admin"
ADMIN_PASS=""
INSTALL_NODE="n"
NODE_PORT="62050"
NODE_API_PORT="62051"

# ── helpers ──────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# Read a value from .env (handles KEY=VAL and KEY = "VAL" formats)
env_get() {
    local key="$1"
    local file="${2:-$ENV_FILE}"
    if [[ ! -f "$file" ]]; then return; fi
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
        | head -1 \
        | sed -E "s/^[^=]*=[[:space:]]*//" \
        | sed -E 's/^"(.*)"$/\1/' \
        | sed -E "s/^'(.*)'$/\1/"
}

# Set a value in .env (uncomments if commented, creates if missing)
env_set() {
    local key="$1"
    local value="$2"
    local file="${3:-$ENV_FILE}"

    if [[ ! -f "$file" ]]; then
        echo "${key}=${value}" > "$file"
        return
    fi

    # Escape sed special chars in value (& and \)
    local escaped_value
    escaped_value=$(printf '%s' "$value" | sed 's|[&\\]|\\&|g')

    # If key exists (commented or not), replace it
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key}=${escaped_value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

# Comment out a key in .env
env_comment() {
    local key="$1"
    local file="${2:-$ENV_FILE}"
    [[ -f "$file" ]] || return 0
    sed -i -E "s|^([[:space:]]*)${key}[[:space:]]*=|# ${key} =|" "$file"
}

restart_panel() {
    info "Restarting PasarGuard panel ..."
    cd "$INSTALL_DIR" && docker compose restart 2>&1
    success "Panel restarted."
}

is_installed() {
    [[ -f "$ENV_FILE" ]] && [[ -f "$COMPOSE_FILE" ]]
}

# ── dependency helpers ───────────────────────────────────────────────────────
install_if_missing() {
    local cmd="$1" pkg="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        info "Installing $pkg ..."
        apt-get install -y -qq "$pkg" >/dev/null 2>&1
        success "$pkg installed."
    fi
}

install_docker() {
    if command -v docker &>/dev/null; then
        success "Docker is already installed."
        return
    fi
    info "Installing Docker ..."
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable --now docker.service >/dev/null 2>&1
    success "Docker installed and started."
}

install_yq() {
    if command -v yq &>/dev/null; then
        success "yq is already installed."
        return
    fi
    info "Installing yq ..."
    local arch
    arch=$(dpkg --print-architecture)
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
    success "yq installed."
}

install_acme() {
    if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
        success "acme.sh is already installed."
        return
    fi
    install_if_missing cron cron
    systemctl enable --now cron >/dev/null 2>&1 || true
    info "Installing acme.sh ..."
    curl -fsSL https://get.acme.sh | sh -s email="acme@${PANEL_DOMAIN:-localhost}" >/dev/null 2>&1
    success "acme.sh installed."
}

# ── password validation ──────────────────────────────────────────────────────
validate_password() {
    local pw="$1"
    local errors=()
    [[ ${#pw} -lt 12 ]]                                       && errors+=("at least 12 characters")
    [[ $(echo "$pw" | grep -oP '[0-9]' | wc -l) -lt 2 ]]     && errors+=("at least 2 digits")
    [[ $(echo "$pw" | grep -oP '[A-Z]' | wc -l) -lt 2 ]]     && errors+=("at least 2 uppercase letters")
    [[ ! "$pw" =~ [^a-zA-Z0-9] ]]                             && errors+=("at least 1 special character")
    if [[ ${#errors[@]} -gt 0 ]]; then
        warn "Password requirements not met:"
        for e in "${errors[@]}"; do echo -e "  ${RED}-${NC} $e"; done
        return 1
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL MODE — interactive prompts & installation
# ══════════════════════════════════════════════════════════════════════════════

prompt_panel_domain() {
    header "Panel Domain / URL"
    echo -e "Enter the domain name that points to this server."
    echo -e "Example: ${BOLD}panel.example.com${NC}"
    echo -e "(Leave empty to use server IP only)\n"
    read -rp "> Domain: " PANEL_DOMAIN
    if [[ -z "$PANEL_DOMAIN" ]]; then
        info "No domain specified. Panel will be available by server IP."
    else
        success "Domain set to: $PANEL_DOMAIN"
    fi
}

prompt_panel_port() {
    header "Panel Port"
    echo -e "Port on which the PasarGuard panel will listen."
    echo -e "Default: ${BOLD}8000${NC}\n"
    read -rp "> Port [8000]: " input
    PANEL_PORT="${input:-8000}"
    success "Panel port: $PANEL_PORT"
}

prompt_database() {
    header "Database Engine"
    echo -e "Choose the database for PasarGuard:\n"
    echo -e "  ${BOLD}1)${NC} SQLite        ${YELLOW}(default, simplest)${NC}"
    echo -e "  ${BOLD}2)${NC} MySQL"
    echo -e "  ${BOLD}3)${NC} MariaDB"
    echo -e "  ${BOLD}4)${NC} PostgreSQL    ${YELLOW}(v1.0.0+)${NC}"
    echo -e "  ${BOLD}5)${NC} TimescaleDB   ${YELLOW}(v1.0.0+)${NC}"
    echo ""
    read -rp "> Choose [1]: " choice
    case "${choice:-1}" in
        1) DB_ENGINE="sqlite"      ;;
        2) DB_ENGINE="mysql"       ;;
        3) DB_ENGINE="mariadb"     ;;
        4) DB_ENGINE="postgres"    ;;
        5) DB_ENGINE="timescaledb" ;;
        *) DB_ENGINE="sqlite"      ;;
    esac
    success "Database: $DB_ENGINE"
}

prompt_ssl() {
    header "SSL Certificate"
    echo -e "Choose how to set up HTTPS for the panel:\n"
    echo -e "  ${BOLD}1)${NC} Let's Encrypt — automatic via domain   ${YELLOW}(recommended)${NC}"
    echo -e "  ${BOLD}2)${NC} Let's Encrypt — automatic via server IP"
    echo -e "  ${BOLD}3)${NC} Custom certificate (provide paths)"
    echo -e "  ${BOLD}4)${NC} No SSL (localhost only / reverse proxy)"
    echo ""
    read -rp "> Choose [1]: " choice
    case "${choice:-1}" in
        1)
            SSL_MODE="domain"
            if [[ -z "$PANEL_DOMAIN" ]]; then
                warn "No domain was set. Please enter the domain for the certificate:"
                read -rp "> Domain: " PANEL_DOMAIN
            fi
            success "SSL: Let's Encrypt for $PANEL_DOMAIN"
            ;;
        2)
            SSL_MODE="ip"
            success "SSL: Let's Encrypt for server IP"
            ;;
        3)
            SSL_MODE="custom"
            read -rp "> Path to certificate (fullchain.pem): " SSL_CERT_PATH
            read -rp "> Path to private key (key.pem):       " SSL_KEY_PATH
            if [[ ! -f "$SSL_CERT_PATH" || ! -f "$SSL_KEY_PATH" ]]; then
                error "Certificate or key file not found. Falling back to no SSL."
                SSL_MODE="none"
            else
                success "SSL: Custom certificate"
            fi
            ;;
        4)
            SSL_MODE="none"
            success "SSL: Disabled"
            ;;
        *)
            SSL_MODE="none"
            ;;
    esac
}

prompt_admin() {
    header "Admin Account"
    echo -e "Create a sudo administrator for the panel.\n"
    read -rp "> Username [admin]: " input
    ADMIN_USER="${input:-admin}"

    while true; do
        echo -e "\nPassword requirements:"
        echo -e "  - Minimum 12 characters"
        echo -e "  - At least 2 digits"
        echo -e "  - At least 2 uppercase letters"
        echo -e "  - At least 1 special character (!@#\$%^&* etc.)\n"
        read -rsp "> Password: " ADMIN_PASS
        echo ""
        if validate_password "$ADMIN_PASS"; then
            read -rsp "> Confirm password: " confirm
            echo ""
            if [[ "$ADMIN_PASS" == "$confirm" ]]; then
                success "Admin account configured: $ADMIN_USER"
                break
            else
                warn "Passwords do not match. Try again."
            fi
        fi
    done
}

prompt_node() {
    header "Node Installation"
    echo -e "PasarGuard needs at least one Xray node to work."
    echo -e "Install a node on this same server?\n"
    read -rp "> Install node? [Y/n]: " input
    INSTALL_NODE="${input:-Y}"
    if [[ "$INSTALL_NODE" =~ ^[Yy]$ ]]; then
        INSTALL_NODE="y"
        read -rp "> Node service port [62050]: " input
        NODE_PORT="${input:-62050}"
        read -rp "> Node API port [62051]: " input
        NODE_API_PORT="${input:-62051}"
        success "Node will be installed (ports $NODE_PORT / $NODE_API_PORT)"
    else
        INSTALL_NODE="n"
        info "Skipping node installation."
    fi
}

show_summary() {
    header "Installation Summary"
    echo -e "  ${BOLD}Domain:${NC}       ${PANEL_DOMAIN:-<none>}"
    echo -e "  ${BOLD}Port:${NC}         $PANEL_PORT"
    echo -e "  ${BOLD}Database:${NC}     $DB_ENGINE"
    echo -e "  ${BOLD}SSL:${NC}          $SSL_MODE"
    echo -e "  ${BOLD}Admin user:${NC}   $ADMIN_USER"
    echo -e "  ${BOLD}Install node:${NC} $INSTALL_NODE"
    if [[ "$INSTALL_NODE" == "y" ]]; then
        echo -e "  ${BOLD}Node port:${NC}    $NODE_PORT"
        echo -e "  ${BOLD}Node API:${NC}     $NODE_API_PORT"
    fi
    echo ""
    read -rp "Proceed with installation? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "Installation cancelled."
        exit 0
    fi
}

install_dependencies() {
    header "Installing Dependencies"
    apt-get update -qq >/dev/null 2>&1
    install_if_missing curl curl
    install_if_missing jq jq
    install_if_missing openssl openssl
    install_if_missing socat socat
    install_docker
    install_yq
}

install_pasarguard_panel() {
    header "Installing PasarGuard Panel"
    mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$TEMPLATES_DIR"

    info "Fetching configuration files ..."
    curl -fsSL "https://raw.githubusercontent.com/PasarGuard/panel/main/.env.example" -o "$ENV_FILE"
    curl -fsSL "https://raw.githubusercontent.com/PasarGuard/scripts/main/compose/default.yml" -o "$COMPOSE_FILE"
    success "Configuration files downloaded."

    info "Configuring environment ..."
    sed -i 's|^.*UVICORN_HOST.*|UVICORN_HOST = "0.0.0.0"|' "$ENV_FILE"
    sed -i "s|^.*UVICORN_PORT.*|UVICORN_PORT = $PANEL_PORT|" "$ENV_FILE"

    case "$DB_ENGINE" in
        sqlite)
            sed -i 's|^.*SQLALCHEMY_DATABASE_URL.*|SQLALCHEMY_DATABASE_URL = "sqlite+aiosqlite:\/\/\/\/\/var\/lib\/pasarguard\/db.sqlite3"|' "$ENV_FILE"
            ;;
        mysql)   warn "MySQL selected — configure SQLALCHEMY_DATABASE_URL in $ENV_FILE." ;;
        mariadb) warn "MariaDB selected — configure SQLALCHEMY_DATABASE_URL in $ENV_FILE." ;;
        postgres)    warn "PostgreSQL selected — configure SQLALCHEMY_DATABASE_URL in $ENV_FILE." ;;
        timescaledb) warn "TimescaleDB selected — configure SQLALCHEMY_DATABASE_URL in $ENV_FILE." ;;
    esac
    success "Panel environment configured."
}

setup_ssl_certificates() {
    header "Setting Up SSL"
    local cert_dir="$DATA_DIR/certs/${PANEL_DOMAIN:-ssl}"
    mkdir -p "$cert_dir"

    case "$SSL_MODE" in
        domain)
            install_acme
            info "Issuing Let's Encrypt certificate for $PANEL_DOMAIN ..."
            "$HOME/.acme.sh/acme.sh" --issue -d "$PANEL_DOMAIN" --standalone --httpport 80 --force 2>&1 || {
                error "Failed to issue certificate. Check domain DNS & port 80."
                SSL_MODE="none"
                return
            }
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$PANEL_DOMAIN" \
                --cert-file "$cert_dir/cert.pem" \
                --key-file "$cert_dir/key.pem" \
                --fullchain-file "$cert_dir/fullchain.pem" \
                --reloadcmd "cd $INSTALL_DIR && docker compose restart" 2>&1
            env_set "UVICORN_SSL_CERTFILE" "$cert_dir/fullchain.pem"
            env_set "UVICORN_SSL_KEYFILE" "$cert_dir/key.pem"
            env_set "UVICORN_SSL_CA_TYPE" "public"
            success "SSL certificate installed for $PANEL_DOMAIN"
            ;;
        ip)
            install_acme
            local server_ip
            server_ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || echo "")
            if [[ -z "$server_ip" ]]; then
                error "Could not detect server IP. Skipping SSL."
                SSL_MODE="none"
                return
            fi
            info "Issuing Let's Encrypt certificate for IP $server_ip ..."
            "$HOME/.acme.sh/acme.sh" --issue -d "$server_ip" --standalone --httpport 80 --force 2>&1 || {
                error "Failed to issue certificate for IP."
                SSL_MODE="none"
                return
            }
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$server_ip" \
                --cert-file "$cert_dir/cert.pem" \
                --key-file "$cert_dir/key.pem" \
                --fullchain-file "$cert_dir/fullchain.pem" \
                --reloadcmd "cd $INSTALL_DIR && docker compose restart" 2>&1
            env_set "UVICORN_SSL_CERTFILE" "$cert_dir/fullchain.pem"
            env_set "UVICORN_SSL_KEYFILE" "$cert_dir/key.pem"
            env_set "UVICORN_SSL_CA_TYPE" "public"
            success "SSL certificate installed for $server_ip"
            ;;
        custom)
            local target_cert="$cert_dir/fullchain.pem"
            local target_key="$cert_dir/key.pem"
            cp "$SSL_CERT_PATH" "$target_cert"
            cp "$SSL_KEY_PATH" "$target_key"
            env_set "UVICORN_SSL_CERTFILE" "$target_cert"
            env_set "UVICORN_SSL_KEYFILE" "$target_key"
            env_set "UVICORN_SSL_CA_TYPE" "public"
            success "Custom SSL certificate configured."
            ;;
        none)
            info "SSL disabled."
            ;;
    esac
}

start_panel() {
    header "Starting PasarGuard Panel"
    if ! grep -q "/var/lib/pasarguard" "$COMPOSE_FILE" 2>/dev/null; then
        yq eval -i '.services.pasarguard.volumes = ["/var/lib/pasarguard:/var/lib/pasarguard"]' "$COMPOSE_FILE" 2>/dev/null || true
    fi
    yq eval -i '.services.pasarguard.network_mode = "host"' "$COMPOSE_FILE" 2>/dev/null || true
    yq eval -i '.services.pasarguard.env_file = ".env"' "$COMPOSE_FILE" 2>/dev/null || true
    yq eval -i '.services.pasarguard.restart = "always"' "$COMPOSE_FILE" 2>/dev/null || true

    cd "$INSTALL_DIR"
    docker compose pull 2>&1
    docker compose up -d 2>&1
    success "PasarGuard panel is running."

    info "Waiting for panel to initialize (up to 30s) ..."
    for i in $(seq 1 30); do
        if docker compose logs 2>&1 | grep -q "Application startup complete"; then
            success "Panel is ready."
            return
        fi
        sleep 1
    done
    warn "Panel may still be starting. Check: pasarguard_scr logs"
}

create_admin() {
    header "Creating Admin Account"
    info "Creating admin user '$ADMIN_USER' ..."
    printf '%s\n%s\nN\n' "${ADMIN_PASS}" "${ADMIN_PASS}" | pasarguard cli admins -c "$ADMIN_USER" -s 2>&1 || {
        warn "Could not create admin automatically."
        warn "Create manually: pasarguard cli admins -c $ADMIN_USER -s"
        return
    }
    success "Admin '$ADMIN_USER' created."
}

install_node() {
    header "Installing PasarGuard Node"
    if [[ "$INSTALL_NODE" != "y" ]]; then
        info "Skipping node installation."
        return
    fi
    info "Running official node installer ..."
    curl -fsSLo /tmp/pg_install.sh https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh
    chmod +x /tmp/pg_install.sh
    bash /tmp/pg_install.sh install-node 2>&1 || {
        warn "Node install had issues. Try manually: pasarguard install-node"
    }
    success "Node installation step completed."
}

install_pasarguard_script() {
    info "Installing pasarguard management script ..."
    curl -fsSLo /tmp/pg_main.sh https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh
    bash /tmp/pg_main.sh install-script 2>&1 || true
    success "Management script installed."
}

install_self() {
    info "Installing pasarguard_scr to $SCRIPT_INSTALL_PATH ..."
    local self_path
    self_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")"
    if [[ -n "$self_path" && -f "$self_path" ]]; then
        if [[ "$(readlink -f "$self_path")" == "$(readlink -f "$SCRIPT_INSTALL_PATH" 2>/dev/null)" ]]; then
            success "pasarguard_scr is already installed at $SCRIPT_INSTALL_PATH"
            return
        fi
        cp "$self_path" "$SCRIPT_INSTALL_PATH"
    else
        curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_INSTALL_PATH"
    fi
    chmod +x "$SCRIPT_INSTALL_PATH"
    success "pasarguard_scr installed. Run it anytime with: pasarguard_scr"
}

show_install_result() {
    local proto="http"
    [[ "$SSL_MODE" != "none" ]] && proto="https"
    local host="${PANEL_DOMAIN:-$(curl -4 -fsSL ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')}"

    header "Installation Complete!"
    echo ""
    echo -e "  ${GREEN}${BOLD}PasarGuard has been installed successfully!${NC}"
    echo ""
    echo -e "  ${BOLD}Panel URL:${NC}     ${proto}://${host}:${PANEL_PORT}/dashboard/"
    echo -e "  ${BOLD}Admin user:${NC}    ${ADMIN_USER}"
    echo -e "  ${BOLD}Admin pass:${NC}    (the password you entered during setup)"
    echo -e "  ${BOLD}Database:${NC}      ${DB_ENGINE}"
    echo -e "  ${BOLD}SSL:${NC}           ${SSL_MODE}"
    echo ""
    if [[ "$INSTALL_NODE" == "y" ]]; then
        echo -e "  ${BOLD}Node port:${NC}     ${NODE_PORT}"
        echo -e "  ${BOLD}Node API:${NC}      ${NODE_API_PORT}"
        echo -e "  ${YELLOW}Don't forget to add the node in the panel: Dashboard -> Nodes${NC}"
        echo ""
    fi
    echo -e "  ${BOLD}Management:${NC}    Run ${CYAN}pasarguard_scr${NC} anytime to manage your panel."
    echo ""
}

do_install() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║                                              ║"
    echo "  ║     PasarGuard Interactive Installer         ║"
    echo "  ║                                              ║"
    echo "  ║     github.com/DanikMonster/pasarguard_scr   ║"
    echo "  ║                                              ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root
    prompt_panel_domain
    prompt_panel_port
    prompt_database
    prompt_ssl
    prompt_admin
    prompt_node
    show_summary

    install_dependencies
    install_pasarguard_panel
    install_pasarguard_script
    setup_ssl_certificates
    start_panel
    create_admin
    install_node
    install_self

    show_install_result
}

# ══════════════════════════════════════════════════════════════════════════════
#  MANAGE MODE — post-install management functions
# ══════════════════════════════════════════════════════════════════════════════

# ── show current config ──────────────────────────────────────────────────────
manage_show_status() {
    header "PasarGuard Status"

    local port domain dash_path sub_path ssl_cert ssl_key proto host
    port=$(env_get "UVICORN_PORT")
    domain=""
    ssl_cert=$(env_get "UVICORN_SSL_CERTFILE")
    ssl_key=$(env_get "UVICORN_SSL_KEYFILE")
    dash_path=$(env_get "DASHBOARD_PATH")
    sub_path=$(env_get "SUBSCRIPTION_PATH")
    local sub_template=$(env_get "SUBSCRIPTION_PAGE_TEMPLATE")
    local home_template=$(env_get "HOME_PAGE_TEMPLATE")
    local templates_dir=$(env_get "CUSTOM_TEMPLATES_DIRECTORY")

    # try to extract domain from cert path
    if [[ -n "$ssl_cert" ]]; then
        domain=$(echo "$ssl_cert" | grep -oP 'certs/\K[^/]+')
        proto="https"
    else
        proto="http"
    fi
    host="${domain:-$(curl -4 -fsSL ifconfig.me 2>/dev/null || echo '?')}"

    echo -e "  ${BOLD}Panel URL:${NC}           ${proto}://${host}:${port:-8000}${dash_path:-/dashboard/}"
    echo -e "  ${BOLD}Port:${NC}                ${port:-8000}"
    echo -e "  ${BOLD}Domain:${NC}              ${domain:-<not set>}"
    echo -e "  ${BOLD}Dashboard path:${NC}      ${dash_path:-/dashboard/}"
    echo -e "  ${BOLD}Subscription path:${NC}   ${sub_path:-sub}"
    echo -e "  ${BOLD}SSL cert:${NC}            ${ssl_cert:-<not set>}"
    echo -e "  ${BOLD}SSL key:${NC}             ${ssl_key:-<not set>}"
    echo -e "  ${BOLD}Templates dir:${NC}       ${templates_dir:-$TEMPLATES_DIR}"
    echo -e "  ${BOLD}Sub page template:${NC}   ${sub_template:-<default>}"
    echo -e "  ${BOLD}Home page template:${NC}  ${home_template:-<default>}"
    echo ""

    info "Docker status:"
    cd "$INSTALL_DIR" && docker compose ps 2>&1
    echo ""
}

# ── change domain ────────────────────────────────────────────────────────────
manage_change_domain() {
    header "Change Panel Domain"

    local current_cert=$(env_get "UVICORN_SSL_CERTFILE")
    local current_domain=""
    if [[ -n "$current_cert" ]]; then
        current_domain=$(echo "$current_cert" | grep -oP 'certs/\K[^/]+')
    fi
    echo -e "  Current domain: ${BOLD}${current_domain:-<not set>}${NC}\n"

    read -rp "> New domain (e.g. panel.example.com): " new_domain
    if [[ -z "$new_domain" ]]; then
        warn "No domain entered. Aborting."
        return
    fi

    echo -e "\nSSL for the new domain:\n"
    echo -e "  ${BOLD}1)${NC} Let's Encrypt (automatic)"
    echo -e "  ${BOLD}2)${NC} Custom certificate"
    echo -e "  ${BOLD}3)${NC} No SSL"
    echo ""
    read -rp "> Choose [1]: " ssl_choice

    local cert_dir="$DATA_DIR/certs/${new_domain}"
    mkdir -p "$cert_dir"

    case "${ssl_choice:-1}" in
        1)
            install_acme
            info "Issuing certificate for $new_domain ..."
            # Stop panel temporarily to free port 80 if needed
            "$HOME/.acme.sh/acme.sh" --issue -d "$new_domain" --standalone --httpport 80 --force 2>&1 || {
                error "Failed to issue certificate. Check DNS and port 80."
                return
            }
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$new_domain" \
                --cert-file "$cert_dir/cert.pem" \
                --key-file "$cert_dir/key.pem" \
                --fullchain-file "$cert_dir/fullchain.pem" \
                --reloadcmd "cd $INSTALL_DIR && docker compose restart" 2>&1
            env_set "UVICORN_SSL_CERTFILE" "$cert_dir/fullchain.pem"
            env_set "UVICORN_SSL_KEYFILE" "$cert_dir/key.pem"
            env_set "UVICORN_SSL_CA_TYPE" "public"
            success "SSL certificate installed for $new_domain"
            ;;
        2)
            read -rp "> Path to fullchain.pem: " cpath
            read -rp "> Path to key.pem:       " kpath
            if [[ -f "$cpath" && -f "$kpath" ]]; then
                cp "$cpath" "$cert_dir/fullchain.pem"
                cp "$kpath" "$cert_dir/key.pem"
                env_set "UVICORN_SSL_CERTFILE" "$cert_dir/fullchain.pem"
                env_set "UVICORN_SSL_KEYFILE" "$cert_dir/key.pem"
                env_set "UVICORN_SSL_CA_TYPE" "public"
                success "Custom SSL set for $new_domain"
            else
                error "Files not found."
                return
            fi
            ;;
        3)
            env_comment "UVICORN_SSL_CERTFILE"
            env_comment "UVICORN_SSL_KEYFILE"
            env_comment "UVICORN_SSL_CA_TYPE"
            success "SSL disabled for $new_domain"
            ;;
    esac

    restart_panel
    local port=$(env_get "UVICORN_PORT")
    local proto="http"
    [[ "${ssl_choice:-1}" != "3" ]] && proto="https"
    success "Domain changed! Panel: ${proto}://${new_domain}:${port:-8000}/dashboard/"
}

# ── change port ──────────────────────────────────────────────────────────────
manage_change_port() {
    header "Change Panel Port"

    local current=$(env_get "UVICORN_PORT")
    echo -e "  Current port: ${BOLD}${current:-8000}${NC}\n"

    read -rp "> New port: " new_port
    if [[ -z "$new_port" || ! "$new_port" =~ ^[0-9]+$ ]]; then
        error "Invalid port number."
        return
    fi

    env_set "UVICORN_PORT" "$new_port"
    restart_panel
    success "Port changed to $new_port"
}

# ── change dashboard URI ─────────────────────────────────────────────────────
manage_change_uri() {
    header "Change Dashboard URI Path"

    local current=$(env_get "DASHBOARD_PATH")
    echo -e "  Current path: ${BOLD}${current:-/dashboard/}${NC}"
    echo -e "  This is the URL path to access the admin panel.\n"
    echo -e "  Examples: ${DIM}/dashboard/  /admin/  /secret-panel/${NC}\n"

    read -rp "> New path (must start and end with /): " new_path
    if [[ -z "$new_path" ]]; then
        warn "No path entered. Aborting."
        return
    fi
    # ensure it starts and ends with /
    [[ "$new_path" != /* ]] && new_path="/${new_path}"
    [[ "$new_path" != */ ]] && new_path="${new_path}/"

    env_set "DASHBOARD_PATH" "\"${new_path}\""
    restart_panel
    success "Dashboard URI changed to: $new_path"
}

# ── change subscription page HTML ────────────────────────────────────────────
manage_change_sub_html() {
    header "Change Subscription Page HTML"

    local templates_dir=$(env_get "CUSTOM_TEMPLATES_DIRECTORY")
    templates_dir="${templates_dir:-$TEMPLATES_DIR}"
    local current=$(env_get "SUBSCRIPTION_PAGE_TEMPLATE")

    echo -e "  Current template: ${BOLD}${current:-<default>}${NC}"
    echo -e "  Templates dir:    ${BOLD}${templates_dir}${NC}\n"
    echo -e "  Options:\n"
    echo -e "  ${BOLD}1)${NC} Edit subscription HTML in nano/vi"
    echo -e "  ${BOLD}2)${NC} Provide path to custom HTML file"
    echo -e "  ${BOLD}3)${NC} Reset to default template"
    echo -e "  ${BOLD}4)${NC} Change subscription URL path"
    echo ""
    read -rp "> Choose [1]: " choice

    case "${choice:-1}" in
        1)
            mkdir -p "${templates_dir}/subscription"
            local tpl_file="${templates_dir}/subscription/index.html"
            if [[ ! -f "$tpl_file" ]]; then
                cat > "$tpl_file" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Subscription</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 20px; background: #0d1117; color: #c9d1d9; }
        .container { max-width: 600px; margin: 0 auto; }
        h1 { color: #58a6ff; }
        .info { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 16px; margin: 10px 0; }
        code { background: #1f2937; padding: 2px 6px; border-radius: 4px; color: #7ee787; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Your Subscription</h1>
        <div class="info">
            <p>Copy this link into your proxy client:</p>
            <code>{{ sub_url }}</code>
        </div>
    </div>
</body>
</html>
HTMLEOF
                info "Created default template at $tpl_file"
            fi

            local editor="nano"
            command -v nano &>/dev/null || editor="vi"
            "$editor" "$tpl_file"

            env_set "CUSTOM_TEMPLATES_DIRECTORY" "\"${templates_dir}\""
            env_set "SUBSCRIPTION_PAGE_TEMPLATE" "\"subscription/index.html\""
            restart_panel
            success "Subscription page template updated."
            ;;
        2)
            read -rp "> Path to HTML file: " html_path
            if [[ ! -f "$html_path" ]]; then
                error "File not found: $html_path"
                return
            fi
            mkdir -p "${templates_dir}/subscription"
            cp "$html_path" "${templates_dir}/subscription/index.html"
            env_set "CUSTOM_TEMPLATES_DIRECTORY" "\"${templates_dir}\""
            env_set "SUBSCRIPTION_PAGE_TEMPLATE" "\"subscription/index.html\""
            restart_panel
            success "Subscription page updated from $html_path"
            ;;
        3)
            env_comment "SUBSCRIPTION_PAGE_TEMPLATE"
            restart_panel
            success "Subscription page reset to default."
            ;;
        4)
            local cur_sub=$(env_get "SUBSCRIPTION_PATH")
            echo -e "\n  Current subscription path: ${BOLD}${cur_sub:-sub}${NC}"
            echo -e "  This is the URL prefix for user subscription links.\n"
            read -rp "> New subscription path (e.g. sub, subscribe, my-sub): " new_sub
            if [[ -z "$new_sub" ]]; then
                warn "No path entered. Aborting."
                return
            fi
            env_set "SUBSCRIPTION_PATH" "\"${new_sub}\""
            restart_panel
            success "Subscription path changed to: $new_sub"
            ;;
    esac
}

# ── change home page HTML ────────────────────────────────────────────────────
manage_change_home_html() {
    header "Change Home Page HTML"

    local templates_dir=$(env_get "CUSTOM_TEMPLATES_DIRECTORY")
    templates_dir="${templates_dir:-$TEMPLATES_DIR}"
    local current=$(env_get "HOME_PAGE_TEMPLATE")

    echo -e "  Current template: ${BOLD}${current:-<default>}${NC}\n"
    echo -e "  ${BOLD}1)${NC} Edit home page HTML in nano/vi"
    echo -e "  ${BOLD}2)${NC} Provide path to custom HTML file"
    echo -e "  ${BOLD}3)${NC} Reset to default"
    echo ""
    read -rp "> Choose [1]: " choice

    case "${choice:-1}" in
        1)
            mkdir -p "${templates_dir}/home"
            local tpl_file="${templates_dir}/home/index.html"
            if [[ ! -f "$tpl_file" ]]; then
                cat > "$tpl_file" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; display: flex; justify-content: center; align-items: center; min-height: 100vh; background: #0d1117; color: #c9d1d9; }
        .container { text-align: center; }
        h1 { color: #58a6ff; font-size: 2.5em; }
        p { color: #8b949e; font-size: 1.2em; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome</h1>
        <p>Service is running.</p>
    </div>
</body>
</html>
HTMLEOF
                info "Created default template at $tpl_file"
            fi

            local editor="nano"
            command -v nano &>/dev/null || editor="vi"
            "$editor" "$tpl_file"

            env_set "CUSTOM_TEMPLATES_DIRECTORY" "\"${templates_dir}\""
            env_set "HOME_PAGE_TEMPLATE" "\"home/index.html\""
            restart_panel
            success "Home page template updated."
            ;;
        2)
            read -rp "> Path to HTML file: " html_path
            if [[ ! -f "$html_path" ]]; then
                error "File not found: $html_path"
                return
            fi
            mkdir -p "${templates_dir}/home"
            cp "$html_path" "${templates_dir}/home/index.html"
            env_set "CUSTOM_TEMPLATES_DIRECTORY" "\"${templates_dir}\""
            env_set "HOME_PAGE_TEMPLATE" "\"home/index.html\""
            restart_panel
            success "Home page updated from $html_path"
            ;;
        3)
            env_comment "HOME_PAGE_TEMPLATE"
            restart_panel
            success "Home page reset to default."
            ;;
    esac
}

# ── change admin password ────────────────────────────────────────────────────
manage_change_admin() {
    header "Change Admin Password"

    info "Current admins:"
    pasarguard cli admins -l 2>&1 || true
    echo ""

    read -rp "> Username to modify: " username
    if [[ -z "$username" ]]; then
        warn "No username entered. Aborting."
        return
    fi

    while true; do
        echo -e "\nPassword requirements:"
        echo -e "  - Minimum 12 characters"
        echo -e "  - At least 2 digits"
        echo -e "  - At least 2 uppercase letters"
        echo -e "  - At least 1 special character\n"
        read -rsp "> New password: " new_pass
        echo ""
        if validate_password "$new_pass"; then
            read -rsp "> Confirm password: " confirm
            echo ""
            if [[ "$new_pass" == "$confirm" ]]; then
                break
            else
                warn "Passwords do not match."
            fi
        fi
    done

    printf '%s\n%s\nN\n' "${new_pass}" "${new_pass}" | pasarguard cli admins -m "$username" 2>&1 || {
        warn "Could not change password automatically."
        warn "Try manually: pasarguard cli admins -m $username"
        return
    }
    success "Password changed for '$username'."
}

# ── management menu ──────────────────────────────────────────────────────────
manage_menu() {
    if ! is_installed; then
        error "PasarGuard is not installed. Run: pasarguard_scr install"
        exit 1
    fi

    while true; do
        clear
        echo -e "${CYAN}${BOLD}"
        echo "  ╔══════════════════════════════════════════════╗"
        echo "  ║                                              ║"
        echo "  ║     PasarGuard Manager                       ║"
        echo "  ║                                              ║"
        echo "  ╚══════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "  ${BOLD}1)${NC}  ${MAGENTA}Status${NC}              — Show current configuration"
        echo -e "  ${BOLD}2)${NC}  ${BLUE}Change domain${NC}       — Change panel domain & SSL"
        echo -e "  ${BOLD}3)${NC}  ${BLUE}Change port${NC}         — Change panel port"
        echo -e "  ${BOLD}4)${NC}  ${BLUE}Change dashboard URI${NC}— Change admin panel URL path"
        echo -e "  ${BOLD}5)${NC}  ${GREEN}Subscription page${NC}  — Edit subscription HTML template"
        echo -e "  ${BOLD}6)${NC}  ${GREEN}Home page${NC}          — Edit home page HTML template"
        echo -e "  ${BOLD}7)${NC}  ${YELLOW}Change admin${NC}       — Change admin password"
        echo -e "  ${BOLD}8)${NC}  ${CYAN}Restart panel${NC}      — Restart PasarGuard services"
        echo -e "  ${BOLD}9)${NC}  ${CYAN}View logs${NC}          — Show panel logs"
        echo -e "  ${BOLD}10)${NC} ${RED}Edit .env${NC}          — Manually edit configuration"
        echo -e "  ${BOLD}11)${NC} ${DIM}Update script${NC}      — Update pasarguard_scr to latest"
        echo ""
        echo -e "  ${BOLD}12)${NC} ${RED}${BOLD}Uninstall${NC}          — Remove PasarGuard & script"
        echo ""
        echo -e "  ${BOLD}0)${NC}  Exit"
        echo ""
        read -rp "  > Choose: " choice

        case "$choice" in
            1)  manage_show_status; read -rp "Press Enter to continue..." ;;
            2)  manage_change_domain; read -rp "Press Enter to continue..." ;;
            3)  manage_change_port; read -rp "Press Enter to continue..." ;;
            4)  manage_change_uri; read -rp "Press Enter to continue..." ;;
            5)  manage_change_sub_html; read -rp "Press Enter to continue..." ;;
            6)  manage_change_home_html; read -rp "Press Enter to continue..." ;;
            7)  manage_change_admin; read -rp "Press Enter to continue..." ;;
            8)  restart_panel; read -rp "Press Enter to continue..." ;;
            9)  cd "$INSTALL_DIR" && docker compose logs --tail 50 2>&1; read -rp "Press Enter to continue..." ;;
            10) local editor="nano"; command -v nano &>/dev/null || editor="vi"; "$editor" "$ENV_FILE"; restart_panel; read -rp "Press Enter to continue..." ;;
            11) manage_update_self; read -rp "Press Enter to continue..." ;;
            12) manage_uninstall ;;
            0)  echo -e "\n${GREEN}Bye!${NC}"; exit 0 ;;
            *)  warn "Invalid choice." ;;
        esac
    done
}

manage_uninstall() {
    header "Uninstall PasarGuard"

    echo -e "  ${RED}${BOLD}WARNING: This will completely remove PasarGuard!${NC}\n"
    echo -e "  The following will be deleted:"
    echo -e "  ${BOLD}-${NC} Docker containers and images"
    echo -e "  ${BOLD}-${NC} Application files:    ${DIM}${INSTALL_DIR}${NC}"
    echo -e "  ${BOLD}-${NC} Data files:           ${DIM}${DATA_DIR}${NC}"
    echo -e "  ${BOLD}-${NC} Management script:    ${DIM}${SCRIPT_INSTALL_PATH}${NC}"
    echo -e "  ${BOLD}-${NC} Official CLI:         ${DIM}/usr/local/bin/pasarguard${NC}"
    echo ""

    read -rp "> Type 'YES' to confirm full uninstall: " confirm
    if [[ "$confirm" != "YES" ]]; then
        info "Uninstall cancelled."
        read -rp "Press Enter to continue..."
        return
    fi

    echo ""
    read -rp "> Keep data (database, certificates)? [y/N]: " keep_data

    info "Stopping and removing Docker containers ..."
    cd "$INSTALL_DIR" && docker compose down -v 2>&1 || true

    info "Removing application files ($INSTALL_DIR) ..."
    rm -rf "$INSTALL_DIR"

    if [[ ! "$keep_data" =~ ^[Yy]$ ]]; then
        info "Removing data files ($DATA_DIR) ..."
        rm -rf "$DATA_DIR"
        success "Data files removed."
    else
        info "Data files kept at: $DATA_DIR"
    fi

    info "Removing CLI scripts ..."
    rm -f /usr/local/bin/pasarguard
    rm -f /usr/local/bin/pasarguard-node

    info "Removing pasarguard_scr ..."
    rm -f "$SCRIPT_INSTALL_PATH"

    success "PasarGuard has been completely uninstalled."
    echo ""
    echo -e "  ${DIM}To reinstall, run:${NC}"
    echo -e "  bash <(curl -fsSL $SCRIPT_URL)"
    echo ""
    exit 0
}

manage_update_self() {
    header "Update pasarguard_scr"
    info "Downloading latest version ..."
    curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_INSTALL_PATH"
    chmod +x "$SCRIPT_INSTALL_PATH"
    success "pasarguard_scr updated to the latest version."
    info "Restart the script to use the new version."
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN — entry point
# ══════════════════════════════════════════════════════════════════════════════

show_main_menu() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║                                              ║"
    echo "  ║     PasarGuard Installer & Manager           ║"
    echo "  ║                                              ║"
    echo "  ║     github.com/DanikMonster/pasarguard_scr   ║"
    echo "  ║                                              ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"

    if is_installed; then
        echo -e "  ${GREEN}PasarGuard is installed.${NC}\n"
        echo -e "  ${BOLD}1)${NC} Manage PasarGuard"
        echo -e "  ${BOLD}2)${NC} Reinstall PasarGuard"
        echo -e "  ${BOLD}0)${NC} Exit"
        echo ""
        read -rp "  > Choose [1]: " choice
        case "${choice:-1}" in
            1) manage_menu ;;
            2) do_install ;;
            0) exit 0 ;;
            *) manage_menu ;;
        esac
    else
        echo -e "  ${YELLOW}PasarGuard is not installed.${NC}\n"
        echo -e "  ${BOLD}1)${NC} Install PasarGuard"
        echo -e "  ${BOLD}0)${NC} Exit"
        echo ""
        read -rp "  > Choose [1]: " choice
        case "${choice:-1}" in
            1) do_install ;;
            0) exit 0 ;;
            *) do_install ;;
        esac
    fi
}

main() {
    check_root

    case "${1:-}" in
        install)        do_install ;;
        manage)         manage_menu ;;
        change-domain|change-port|change-uri|change-sub|change-home|change-admin|status|restart|logs|uninstall)
            if ! is_installed; then
                error "PasarGuard is not installed. Run: pasarguard_scr install"
                exit 1
            fi
            case "$1" in
                change-domain)  manage_change_domain ;;
                change-port)    manage_change_port ;;
                change-uri)     manage_change_uri ;;
                change-sub)     manage_change_sub_html ;;
                change-home)    manage_change_home_html ;;
                change-admin)   manage_change_admin ;;
                status)         manage_show_status ;;
                restart)        restart_panel ;;
                logs)           cd "$INSTALL_DIR" && docker compose logs --tail 100 -f 2>&1 ;;
                uninstall)      manage_uninstall ;;
            esac
            ;;
        update)         manage_update_self ;;
        help|--help|-h)
            echo -e "${BOLD}PasarGuard Installer & Manager${NC}"
            echo ""
            echo "Usage: pasarguard_scr [command]"
            echo ""
            echo "Commands:"
            echo "  install        Run interactive installer"
            echo "  manage         Open management menu"
            echo "  change-domain  Change panel domain & SSL"
            echo "  change-port    Change panel port"
            echo "  change-uri     Change dashboard URI path"
            echo "  change-sub     Change subscription page template"
            echo "  change-home    Change home page template"
            echo "  change-admin   Change admin password"
            echo "  status         Show current configuration"
            echo "  restart        Restart PasarGuard"
            echo "  logs           Show panel logs (live)"
            echo "  uninstall      Uninstall PasarGuard & remove script"
            echo "  update         Update this script"
            echo "  help           Show this help"
            echo ""
            echo "Without arguments: shows main menu."
            ;;
        "")             show_main_menu ;;
        *)
            error "Unknown command: $1"
            echo "Run: pasarguard_scr help"
            exit 1
            ;;
    esac
}

main "$@"
