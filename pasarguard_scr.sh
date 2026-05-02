#!/usr/bin/env bash
set -e

# ============================================================================
#  PasarGuard Installer Script (pasarguard_scr)
#  Interactive installer with configurable parameters:
#    - Panel domain / URL
#    - Database engine (SQLite, MySQL, MariaDB, PostgreSQL, TimescaleDB)
#    - SSL certificate method (Let's Encrypt domain, Let's Encrypt IP, custom, none)
#    - Admin username & password
#    - Node installation (optional, on the same server)
#    - Panel port
#  Tested on Ubuntu 20.04 / 22.04 / 24.04, Debian 11/12
# ============================================================================

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── globals ──────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/pasarguard"
DATA_DIR="/var/lib/pasarguard"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
PANEL_DOMAIN=""
PANEL_PORT="8000"
DB_ENGINE="sqlite"
SSL_MODE="none"        # none | domain | ip | custom
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
    [[ ${#pw} -lt 12 ]]                           && errors+=("at least 12 characters")
    [[ $(echo "$pw" | grep -oP '[0-9]' | wc -l) -lt 2 ]] && errors+=("at least 2 digits")
    [[ $(echo "$pw" | grep -oP '[A-Z]' | wc -l) -lt 2 ]] && errors+=("at least 2 uppercase letters")
    [[ ! "$pw" =~ [^a-zA-Z0-9] ]]                 && errors+=("at least 1 special character")
    if [[ ${#errors[@]} -gt 0 ]]; then
        warn "Password requirements not met:"
        for e in "${errors[@]}"; do echo -e "  ${RED}-${NC} $e"; done
        return 1
    fi
    return 0
}

# ── interactive prompts ──────────────────────────────────────────────────────
prompt_panel_domain() {
    header "Panel Domain / URL"
    echo -e "Enter the domain name that points to this server."
    echo -e "Example: ${BOLD}panel.example.com${NC}"
    echo -e "(Leave empty to use server IP only)\n"
    read -rp "> Domain: " PANEL_DOMAIN
    if [[ -z "$PANEL_DOMAIN" ]]; then
        PANEL_DOMAIN=""
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

# ── show summary ─────────────────────────────────────────────────────────────
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

# ── core installation ────────────────────────────────────────────────────────
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

    mkdir -p "$INSTALL_DIR" "$DATA_DIR"

    # download .env and compose file
    info "Fetching configuration files ..."
    curl -fsSL "https://raw.githubusercontent.com/PasarGuard/panel/main/.env.example" -o "$ENV_FILE"
    curl -fsSL "https://raw.githubusercontent.com/PasarGuard/scripts/main/compose/default.yml" -o "$COMPOSE_FILE"
    success "Configuration files downloaded."

    # --- configure .env ---
    info "Configuring environment ..."

    # host & port
    sed -i 's|^.*UVICORN_HOST.*|UVICORN_HOST = "0.0.0.0"|' "$ENV_FILE"
    sed -i "s|^.*UVICORN_PORT.*|UVICORN_PORT = $PANEL_PORT|" "$ENV_FILE"

    # database
    case "$DB_ENGINE" in
        sqlite)
            sed -i 's|^.*SQLALCHEMY_DATABASE_URL.*|SQLALCHEMY_DATABASE_URL = "sqlite+aiosqlite:\/\/\/\/\/var\/lib\/pasarguard\/db.sqlite3"|' "$ENV_FILE"
            ;;
        mysql)
            warn "MySQL selected — configure SQLALCHEMY_DATABASE_URL in $ENV_FILE with your credentials."
            ;;
        mariadb)
            warn "MariaDB selected — configure SQLALCHEMY_DATABASE_URL in $ENV_FILE with your credentials."
            ;;
        postgres)
            warn "PostgreSQL selected — configure SQLALCHEMY_DATABASE_URL in $ENV_FILE with your credentials."
            ;;
        timescaledb)
            warn "TimescaleDB selected — configure SQLALCHEMY_DATABASE_URL in $ENV_FILE with your credentials."
            ;;
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
                error "Failed to issue certificate. Make sure:"
                echo "  1. Domain $PANEL_DOMAIN resolves to this server's IP"
                echo "  2. Port 80 is open and not used by another service"
                warn "Continuing without SSL. You can re-run SSL setup later."
                SSL_MODE="none"
                return
            }
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$PANEL_DOMAIN" \
                --cert-file "$cert_dir/cert.pem" \
                --key-file "$cert_dir/key.pem" \
                --fullchain-file "$cert_dir/fullchain.pem" \
                --reloadcmd "cd $INSTALL_DIR && docker compose restart" 2>&1

            # update .env
            sed -i "s|^.*UVICORN_SSL_CERTFILE.*|UVICORN_SSL_CERTFILE=$cert_dir/fullchain.pem|" "$ENV_FILE"
            sed -i "s|^.*UVICORN_SSL_KEYFILE.*|UVICORN_SSL_KEYFILE=$cert_dir/key.pem|" "$ENV_FILE"
            sed -i "s|^.*UVICORN_SSL_CA_TYPE.*|UVICORN_SSL_CA_TYPE=public|" "$ENV_FILE"
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
                error "Failed to issue certificate for IP. Continuing without SSL."
                SSL_MODE="none"
                return
            }
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$server_ip" \
                --cert-file "$cert_dir/cert.pem" \
                --key-file "$cert_dir/key.pem" \
                --fullchain-file "$cert_dir/fullchain.pem" \
                --reloadcmd "cd $INSTALL_DIR && docker compose restart" 2>&1

            sed -i "s|^.*UVICORN_SSL_CERTFILE.*|UVICORN_SSL_CERTFILE=$cert_dir/fullchain.pem|" "$ENV_FILE"
            sed -i "s|^.*UVICORN_SSL_KEYFILE.*|UVICORN_SSL_KEYFILE=$cert_dir/key.pem|" "$ENV_FILE"
            sed -i "s|^.*UVICORN_SSL_CA_TYPE.*|UVICORN_SSL_CA_TYPE=public|" "$ENV_FILE"
            success "SSL certificate installed for $server_ip"
            ;;
        custom)
            local target_cert="$cert_dir/fullchain.pem"
            local target_key="$cert_dir/key.pem"
            cp "$SSL_CERT_PATH" "$target_cert"
            cp "$SSL_KEY_PATH" "$target_key"
            sed -i "s|^.*UVICORN_SSL_CERTFILE.*|UVICORN_SSL_CERTFILE=$target_cert|" "$ENV_FILE"
            sed -i "s|^.*UVICORN_SSL_KEYFILE.*|UVICORN_SSL_KEYFILE=$target_key|" "$ENV_FILE"
            sed -i "s|^.*UVICORN_SSL_CA_TYPE.*|UVICORN_SSL_CA_TYPE=public|" "$ENV_FILE"
            success "Custom SSL certificate configured."
            ;;
        none)
            info "SSL disabled. Panel will run on localhost only or behind reverse proxy."
            ;;
    esac
}

start_panel() {
    header "Starting PasarGuard Panel"

    # make sure compose file has correct volume mapping
    if ! grep -q "/var/lib/pasarguard" "$COMPOSE_FILE" 2>/dev/null; then
        yq eval -i '.services.pasarguard.volumes = ["/var/lib/pasarguard:/var/lib/pasarguard"]' "$COMPOSE_FILE" 2>/dev/null || true
    fi
    # ensure network_mode host
    yq eval -i '.services.pasarguard.network_mode = "host"' "$COMPOSE_FILE" 2>/dev/null || true
    # ensure env_file
    yq eval -i '.services.pasarguard.env_file = ".env"' "$COMPOSE_FILE" 2>/dev/null || true
    # ensure restart policy
    yq eval -i '.services.pasarguard.restart = "always"' "$COMPOSE_FILE" 2>/dev/null || true

    cd "$INSTALL_DIR"
    docker compose pull 2>&1
    docker compose up -d 2>&1
    success "PasarGuard panel is running."

    # wait for panel to start
    info "Waiting for panel to initialize (up to 30s) ..."
    for i in $(seq 1 30); do
        if docker compose logs 2>&1 | grep -q "Application startup complete"; then
            success "Panel is ready."
            return
        fi
        sleep 1
    done
    warn "Panel may still be starting. Check logs: docker compose -f $COMPOSE_FILE logs"
}

create_admin() {
    header "Creating Admin Account"
    info "Creating admin user '$ADMIN_USER' ..."

    # Use docker exec to run the CLI inside the container
    docker exec -i pasarguard-pasarguard-1 python -m app.cli admins create \
        --username "$ADMIN_USER" \
        --password "$ADMIN_PASS" \
        --sudo 2>&1 || {
        # fallback: try the host CLI
        if command -v pasarguard &>/dev/null; then
            info "Trying host CLI ..."
            # The host CLI is interactive, so we pipe answers
            echo -e "${ADMIN_PASS}\n${ADMIN_PASS}\nN" | pasarguard cli admins -c "$ADMIN_USER" -s 2>&1 || {
                warn "Could not create admin automatically."
                warn "Create it manually: pasarguard cli admins -c $ADMIN_USER -s"
                return
            }
        else
            warn "Could not create admin automatically."
            warn "Create it manually after installation: pasarguard cli admins -c $ADMIN_USER -s"
            return
        fi
    }
    success "Admin '$ADMIN_USER' created."
}

install_node() {
    header "Installing PasarGuard Node"

    if [[ "$INSTALL_NODE" != "y" ]]; then
        info "Skipping node installation."
        return
    fi

    info "Downloading official node install script ..."
    curl -fsSLo /tmp/pg_install.sh https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh
    chmod +x /tmp/pg_install.sh
    info "Running node installation ..."
    bash /tmp/pg_install.sh install-node 2>&1 || {
        warn "Automatic node installation encountered issues."
        warn "You can install the node manually: pasarguard install-node"
    }
    success "Node installation step completed."
}

install_pasarguard_script() {
    info "Installing pasarguard management script ..."
    curl -fsSLo /tmp/pg_main.sh https://github.com/PasarGuard/scripts/raw/main/pasarguard.sh
    bash /tmp/pg_main.sh install-script 2>&1 || true
    success "Management script installed."
}

# ── final summary ────────────────────────────────────────────────────────────
show_result() {
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
        echo -e ""
        echo -e "  ${YELLOW}Don't forget to add the node in the panel:${NC}"
        echo -e "  Dashboard -> Nodes -> Add Node"
        echo ""
    fi
    echo -e "  ${BOLD}Useful commands:${NC}"
    echo -e "    pasarguard status    — Check status"
    echo -e "    pasarguard logs      — View logs"
    echo -e "    pasarguard restart   — Restart services"
    echo -e "    pasarguard cli       — Management CLI"
    echo ""
    echo -e "  ${BOLD}Config files:${NC}"
    echo -e "    $ENV_FILE"
    echo -e "    $COMPOSE_FILE"
    echo ""
    echo -e "  ${CYAN}Thank you for using PasarGuard Installer!${NC}"
    echo ""
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
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

    # ── gather parameters ──
    prompt_panel_domain
    prompt_panel_port
    prompt_database
    prompt_ssl
    prompt_admin
    prompt_node
    show_summary

    # ── install ──
    install_dependencies
    install_pasarguard_panel
    install_pasarguard_script
    setup_ssl_certificates
    start_panel
    create_admin
    install_node

    # ── done ──
    show_result
}

main "$@"
