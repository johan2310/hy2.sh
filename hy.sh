#!/usr/bin/env bash
#
# Script de instalación y gestión de TFN-UDP (Hysteria) con autenticación externa
# Permite añadir/eliminar usuarios con fecha de caducidad y límite de conexiones,
# y modificar la configuración (OBFS, dominio, puerto) de forma persistente.
# Incluye menú interactivo.
#
# Uso: ./install.sh [opciones]   (sin opciones muestra el menú)
#

set -e

# Archivo de configuración persistente para el instalador
INSTALLER_CONF="/etc/hysteria/installer.conf"

# Configuración por defecto (se sobrescriben con valores de INSTALLER_CONF si existe)
DOMAIN="tudominio.com"                # Cambiar por tu dominio o IP
PROTOCOL="udp"
UDP_PORT=":36712"
OBFS="tfn"

# Rutas fijas (no modificables por el usuario)
CONFIG_DIR="/etc/hysteria"
USER_DB="$CONFIG_DIR/users.db"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
SYSTEMD_SERVICE="$SYSTEMD_SERVICES_DIR/hysteria-server.service"
REPO_URL="https://github.com/apernet/hysteria"
API_BASE_URL="https://api.github.com/repos/apernet/hysteria"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# Variables internas
OPERATION=""
VERSION=""
LOCAL_FILE=""
FORCE=""
FORCE_NO_ROOT=""
FORCE_NO_SYSTEMD=""
OPERATING_SYSTEM=""
ARCHITECTURE=""
HYSTERIA_USER="root"
HYSTERIA_HOME_DIR="$CONFIG_DIR"

# Colores y funciones de utilidad
has_command() { type -P "$1" > /dev/null 2>&1; }
curl() { command curl "${CURL_FLAGS[@]}" "$@"; }
mktemp() { command mktemp "$@" "hyservinst.XXXXXXXXXX"; }
tput() { if has_command tput; then command tput "$@"; fi; }
tred() { tput setaf 1; }
tgreen() { tput setaf 2; }
tyellow() { tput setaf 3; }
tblue() { tput setaf 4; }
taoi() { tput setaf 6; }
tbold() { tput bold; }
treset() { tput sgr0; }
note() { echo -e "$(basename "$0"): $(tbold)note: $1$(treset)"; }
warning() { echo -e "$(basename "$0"): $(tyellow)warning: $1$(treset)"; }
error() { echo -e "$(basename "$0"): $(tred)error: $1$(treset)"; }

show_argument_error_and_exit() {
    error "$1"
    echo "Try \"$0 --help\" for usage." >&2
    exit 22
}

exec_sudo() {
    local _saved_ifs="$IFS"
    IFS=$'\n'
    local _preserved_env=(
        $(env | grep "^PACKAGE_MANAGEMENT_INSTALL=" || true)
        $(env | grep "^OPERATING_SYSTEM=" || true)
        $(env | grep "^ARCHITECTURE=" || true)
        $(env | grep "^HYSTERIA_\w*=" || true)
        $(env | grep "^FORCE_\w*=" || true)
    )
    IFS="$_saved_ifs"
    exec sudo env "${_preserved_env[@]}" "$@"
}

check_permission() {
    if [[ "$UID" -eq '0' ]]; then return; fi
    case "$FORCE_NO_ROOT" in
        '1') warning "FORCE_NO_ROOT=1, continuando sin root (puede fallar por permisos)";;
        *)
            if has_command sudo; then
                note "Re-ejecutando con sudo..."
                exec_sudo "$0" "${SCRIPT_ARGS[@]}"
            else
                error "Ejecuta como root o con FORCE_NO_ROOT=1"
                exit 13
            fi
            ;;
    esac
}

check_environment_operating_system() {
    [[ -n "$OPERATING_SYSTEM" ]] && return
    [[ "$(uname)" == "Linux" ]] && OPERATING_SYSTEM=linux && return
    error "Solo Linux soportado. Usa OPERATING_SYSTEM= para forzar."
    exit 95
}

check_environment_architecture() {
    [[ -n "$ARCHITECTURE" ]] && return
    case "$(uname -m)" in
        i386|i686) ARCHITECTURE='386' ;;
        amd64|x86_64) ARCHITECTURE='amd64' ;;
        armv5tel|armv6l|armv7|armv7l) ARCHITECTURE='arm' ;;
        armv8|aarch64) ARCHITECTURE='arm64' ;;
        mips|mipsle|mips64|mips64le) ARCHITECTURE='mipsle' ;;
        s390x) ARCHITECTURE='s390x' ;;
        *) error "Arquitectura no soportada: $(uname -m). Usa ARCHITECTURE= para forzar."; exit 8 ;;
    esac
}

check_environment_systemd() {
    if [[ -d "/run/systemd/system" ]] || grep -q systemd <(ls -l /sbin/init 2>/dev/null); then
        return
    fi
    case "$FORCE_NO_SYSTEMD" in
        1) warning "FORCE_NO_SYSTEMD=1, asumiendo systemd presente" ;;
        2) warning "FORCE_NO_SYSTEMD=2, se omitirán comandos systemd" ;;
        *) error "Solo sistemas con systemd. Usa FORCE_NO_SYSTEMD=1/2 para forzar."; exit 95 ;;
    esac
}

install_software() {
    local package="$1"
    if has_command apt-get; then
        apt-get update && apt-get install -y "$package"
    elif has_command dnf; then
        dnf install -y "$package"
    elif has_command yum; then
        yum install -y "$package"
    elif has_command zypper; then
        zypper install -y "$package"
    elif has_command pacman; then
        pacman -Sy --noconfirm "$package"
    else
        error "No se pudo instalar $package. Instálalo manualmente."
        exit 1
    fi
}

check_environment_curl() { has_command curl || install_software curl; }
check_environment_grep() { has_command grep || install_software grep; }
check_environment_sqlite3() { has_command sqlite3 || install_software sqlite3; }
check_environment_jq() { has_command jq || install_software jq; }

check_environment() {
    check_environment_operating_system
    check_environment_architecture
    check_environment_systemd
    check_environment_curl
    check_environment_grep
    check_environment_sqlite3
    check_environment_jq
}

# Cargar configuración persistente si existe
load_installer_config() {
    if [[ -f "$INSTALLER_CONF" ]]; then
        source "$INSTALLER_CONF"
        note "Configuración cargada desde $INSTALLER_CONF"
    fi
}

# Guardar configuración persistente
save_installer_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$INSTALLER_CONF" << EOF
# Configuración del instalador de TFN-UDP
# Generado automáticamente. No editar manualmente a menos que sepas lo que haces.
DOMAIN="$DOMAIN"
PROTOCOL="$PROTOCOL"
UDP_PORT="$UDP_PORT"
OBFS="$OBFS"
EOF
    note "Configuración guardada en $INSTALLER_CONF"
}

# Actualizar un valor y regenerar configuración
update_setting() {
    local key="$1"
    local value="$2"
    case "$key" in
        DOMAIN) DOMAIN="$value" ;;
        PROTOCOL) PROTOCOL="$value" ;;
        UDP_PORT) UDP_PORT="$value" ;;
        OBFS) OBFS="$value" ;;
        *) error "Variable desconocida: $key"; return 1 ;;
    esac
    save_installer_config
    if [[ -f "$CONFIG_DIR/config.json" ]]; then
        generate_config
        if systemctl list-units --full -all | grep -q "hysteria-server.service"; then
            systemctl restart hysteria-server.service
            note "Servicio reiniciado con nueva configuración."
        else
            warning "El servicio no está instalado o no se pudo reiniciar."
        fi
    else
        note "Configuración guardada. Se usará cuando instales el servidor."
    fi
}

# Funciones de base de datos
init_database() {
    mkdir -p "$CONFIG_DIR"
    sqlite3 "$USER_DB" "CREATE TABLE IF NOT EXISTS users (
        username TEXT PRIMARY KEY,
        password TEXT NOT NULL,
        expiration INTEGER NOT NULL,
        max_connections INTEGER NOT NULL DEFAULT 1,
        active_connections INTEGER DEFAULT 0
    );"
}

user_exists() {
    local username="$1"
    local count=$(sqlite3 "$USER_DB" "SELECT COUNT(*) FROM users WHERE username='$username';")
    [[ $count -gt 0 ]]
}

add_user() {
    local username="$1"
    local password="$2"
    local expiration="$3"   # formato YYYY-MM-DD o timestamp Unix
    local max_conn="$4"
    
    # Convertir fecha a timestamp si es formato YYYY-MM-DD
    if [[ "$expiration" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        expiration=$(date -d "$expiration" +%s 2>/dev/null) || {
            error "Formato de fecha inválido. Use YYYY-MM-DD."
            exit 1
        }
    elif ! [[ "$expiration" =~ ^[0-9]+$ ]]; then
        error "La expiración debe ser YYYY-MM-DD o timestamp Unix."
        exit 1
    fi
    
    # Validar que max_conn sea número positivo
    if ! [[ "$max_conn" =~ ^[0-9]+$ ]] || [ "$max_conn" -lt 1 ]; then
        error "max_connections debe ser un número entero positivo."
        exit 1
    fi
    
    if user_exists "$username"; then
        error "El usuario $username ya existe."
        return 1
    fi
    
    sqlite3 "$USER_DB" "INSERT INTO users (username, password, expiration, max_connections) VALUES ('$username', '$password', $expiration, $max_conn);"
    note "Usuario $username añadido correctamente."
}

remove_user() {
    local username="$1"
    if ! user_exists "$username"; then
        error "El usuario $username no existe."
        return 1
    fi
    sqlite3 "$USER_DB" "DELETE FROM users WHERE username='$username';"
    note "Usuario $username eliminado."
}

list_users() {
    if ! sqlite3 "$USER_DB" "SELECT COUNT(*) FROM users;" | grep -q [1-9]; then
        echo "No hay usuarios registrados."
        return
    fi
    printf "%-20s %-20s %-10s %-10s\n" "Usuario" "Expiración" "Límite" "Activas"
    sqlite3 "$USER_DB" "SELECT username, datetime(expiration, 'unixepoch'), max_connections, active_connections FROM users;" | while IFS='|' read user exp max act; do
        printf "%-20s %-20s %-10s %-10s\n" "$user" "$exp" "$max" "$act"
    done
}

edit_user_interactive() {
    local username="$1"
    if ! user_exists "$username"; then
        error "El usuario $username no existe."
        return 1
    fi
    
    echo "Editando usuario $username. Deja en blanco para mantener valor actual."
    
    # Obtener datos actuales
    local current_pass=$(sqlite3 "$USER_DB" "SELECT password FROM users WHERE username='$username';")
    local current_exp=$(sqlite3 "$USER_DB" "SELECT expiration FROM users WHERE username='$username';")
    local current_max=$(sqlite3 "$USER_DB" "SELECT max_connections FROM users WHERE username='$username';")
    
    echo "Contraseña actual: $current_pass"
    read -p "Nueva contraseña (dejar vacío para no cambiar): " new_pass
    echo "Fecha expiración actual: $(date -d @$current_exp '+%Y-%m-%d')"
    read -p "Nueva expiración (YYYY-MM-DD, vacío para no cambiar): " new_exp
    echo "Límite conexiones actual: $current_max"
    read -p "Nuevo límite (número entero, vacío para no cambiar): " new_max
    
    local updates=()
    [[ -n "$new_pass" ]] && updates+=("password='$new_pass'")
    if [[ -n "$new_exp" ]]; then
        if [[ "$new_exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            new_exp_ts=$(date -d "$new_exp" +%s)
            updates+=("expiration=$new_exp_ts")
        else
            error "Formato de fecha inválido. Se ignora."
        fi
    fi
    if [[ -n "$new_max" ]] && [[ "$new_max" =~ ^[0-9]+$ ]] && [ "$new_max" -gt 0 ]; then
        updates+=("max_connections=$new_max")
    fi
    
    if [ ${#updates[@]} -gt 0 ]; then
        local update_sql=$(IFS=,; echo "${updates[*]}")
        sqlite3 "$USER_DB" "UPDATE users SET $update_sql WHERE username='$username';"
        note "Usuario $username actualizado."
    else
        note "No se realizaron cambios."
    fi
}

# Funciones interactivas para el menú
interactive_add_user() {
    echo "=== Añadir usuario ==="
    read -p "Nombre de usuario: " username
    read -p "Contraseña: " password
    read -p "Fecha de expiración (YYYY-MM-DD): " expiration
    read -p "Límite de conexiones simultáneas: " max_conn
    add_user "$username" "$password" "$expiration" "$max_conn"
}

interactive_remove_user() {
    echo "=== Eliminar usuario ==="
    read -p "Nombre de usuario: " username
    remove_user "$username"
}

interactive_edit_user() {
    echo "=== Editar usuario ==="
    read -p "Nombre de usuario: " username
    edit_user_interactive "$username"
}

interactive_set_obfs() {
    echo "=== Modificar OBFS ==="
    echo "Valor actual: $OBFS"
    read -p "Nuevo valor (ej. tfn, salamander, etc.): " new_obfs
    if [[ -n "$new_obfs" ]]; then
        update_setting "OBFS" "$new_obfs"
    else
        note "No se realizaron cambios."
    fi
}

# Generar scripts de autenticación
generate_auth_scripts() {
    local auth_script="$CONFIG_DIR/auth.sh"
    local disconnect_script="$CONFIG_DIR/disconnect.sh"
    
    cat > "$auth_script" << 'EOF'
#!/bin/bash
# Script de autenticación para Hysteria
# Recibe por stdin: {"username": "...", "password": "..."}
DB="/etc/hysteria/users.db"
INPUT=$(cat)
USER=$(echo "$INPUT" | jq -r '.username')
PASS=$(echo "$INPUT" | jq -r '.password')
ROW=$(sqlite3 "$DB" "SELECT password, expiration, max_connections, active_connections FROM users WHERE username='$USER'")
if [ -z "$ROW" ]; then
    exit 1
fi
IFS='|' read -r DB_PASS EXPIRATION MAX_CONN ACTIVE_CONN <<< "$ROW"
if [ "$PASS" != "$DB_PASS" ]; then
    exit 1
fi
NOW=$(date +%s)
if [ "$NOW" -gt "$EXPIRATION" ]; then
    exit 1
fi
if [ "$ACTIVE_CONN" -ge "$MAX_CONN" ]; then
    exit 1
fi
sqlite3 "$DB" "UPDATE users SET active_connections = active_connections + 1 WHERE username='$USER'"
exit 0
EOF

    cat > "$disconnect_script" << 'EOF'
#!/bin/bash
# Script llamado al desconectar
DB="/etc/hysteria/users.db"
INPUT=$(cat)
USER=$(echo "$INPUT" | jq -r '.username')
sqlite3 "$DB" "UPDATE users SET active_connections = active_connections - 1 WHERE username='$USER'"
exit 0
EOF

    chmod +x "$auth_script" "$disconnect_script"
    note "Scripts de autenticación generados en $CONFIG_DIR"
}

# Generar archivo de configuración de Hysteria con autenticación externa
generate_config() {
    local config_file="$CONFIG_DIR/config.json"
    cat > "$config_file" << EOF
{
  "server": "$DOMAIN",
  "listen": "$UDP_PORT",
  "protocol": "$PROTOCOL",
  "auth": {
    "mode": "external",
    "config": {
      "program": "$CONFIG_DIR/auth.sh",
      "on_disconnect": "$CONFIG_DIR/disconnect.sh",
      "timeout": 5
    }
  },
  "obfs": "$OBFS"
}
EOF
    note "Archivo de configuración generado en $config_file"
}

# Descargar e instalar el binario de Hysteria
download_hysteria() {
    local version="$1"
    local dest="$2"
    local url="$REPO_URL/releases/download/$version/hysteria-$OPERATING_SYSTEM-$ARCHITECTURE"
    echo "Descargando Hysteria $version desde $url ..."
    if ! curl -R -H 'Cache-Control: no-cache' "$url" -o "$dest"; then
        error "Descarga fallida."
        return 11
    fi
    return 0
}

install_hysteria() {
    local binary_source
    if [[ -n "$LOCAL_FILE" ]]; then
        binary_source="$LOCAL_FILE"
        note "Instalando desde archivo local: $binary_source"
    else
        # Determinar versión
        if [[ -z "$VERSION" ]]; then
            # Obtener última versión
            VERSION=$(curl -s "$API_BASE_URL/releases/latest" | jq -r '.tag_name')
            if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
                error "No se pudo obtener la última versión. Especifica --version."
                exit 1
            fi
            note "Última versión detectada: $VERSION"
        fi
        local tmp_bin=$(mktemp)
        download_hysteria "$VERSION" "$tmp_bin" || exit $?
        binary_source="$tmp_bin"
    fi
    
    # Instalar binario
    install -m 755 "$binary_source" "$EXECUTABLE_INSTALL_PATH"
    note "Binario instalado en $EXECUTABLE_INSTALL_PATH"
    
    # Limpiar si fue temporal
    [[ -n "$tmp_bin" ]] && rm -f "$tmp_bin"
}

install_service() {
    local service_file="$SYSTEMD_SERVICE"
    cat > "$service_file" << EOF
[Unit]
Description=TFN-UDP Service (Hysteria)
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$EXECUTABLE_INSTALL_PATH server --config $CONFIG_DIR/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    note "Servicio systemd creado en $service_file"
    systemctl daemon-reload
}

remove_hysteria() {
    # Detener y deshabilitar servicio
    if systemctl list-units --full -all | grep -q "hysteria-server.service"; then
        systemctl stop hysteria-server.service || true
        systemctl disable hysteria-server.service || true
    fi
    # Eliminar archivos
    rm -f "$EXECUTABLE_INSTALL_PATH"
    rm -f "$SYSTEMD_SERVICE"
    rm -rf "$CONFIG_DIR"
    note "Hysteria eliminado."
}

show_service_status() {
    systemctl status hysteria-server.service --no-pager -l
}

show_service_logs() {
    journalctl -u hysteria-server.service -n 50 --no-pager -f
}

show_usage_and_exit() {
    echo
    echo -e "$(tbold)Script de instalación y gestión de TFN-UDP$(treset)"
    echo
    echo "Uso: $0 [opciones]"
    echo "  Sin opciones: Muestra el menú interactivo"
    echo
    echo "Opciones de instalación:"
    echo "  --version <vX.Y.Z>       Instala una versión específica"
    echo "  -l, --local <archivo>    Instala desde un binario local"
    echo "  --remove                 Desinstala completamente"
    echo "  --force                  Fuerza reinstalación"
    echo
    echo "Gestión de usuarios:"
    echo "  --add-user <user> <pass> <fecha> <max>   Añade usuario (fecha: YYYY-MM-DD o timestamp)"
    echo "  --remove-user <user>                      Elimina usuario"
    echo "  --list-users                              Lista usuarios"
    echo "  --edit-user <user>                         Edita usuario (interactivo)"
    echo
    echo "Configuración:"
    echo "  --set-obfs <valor>        Cambia el método de ofuscación (OBFS) y reinicia el servicio"
    echo
    echo "  -h, --help              Muestra esta ayuda"
    echo
    exit 0
}

parse_arguments() {
    SCRIPT_ARGS=("$@")
    while [[ "$#" -gt '0' ]]; do
        case "$1" in
            '--remove')
                OPERATION='remove'
                ;;
            '--version')
                VERSION="$2"
                if [[ -z "$VERSION" ]]; then show_argument_error_and_exit "Falta versión"; fi
                shift
                if ! [[ "$VERSION" == v* ]]; then show_argument_error_and_exit "La versión debe empezar con 'v'"; fi
                ;;
            '--force')
                FORCE='1'
                ;;
            '-l'|'--local')
                LOCAL_FILE="$2"
                if [[ -z "$LOCAL_FILE" ]]; then show_argument_error_and_exit "Falta archivo local"; fi
                shift
                ;;
            '--add-user')
                OPERATION='add-user'
                if [[ $# -lt 5 ]]; then show_argument_error_and_exit "Faltan argumentos para --add-user"; fi
                ADD_USER="$2"
                ADD_PASS="$3"
                ADD_EXP="$4"
                ADD_MAX="$5"
                shift 4
                ;;
            '--remove-user')
                OPERATION='remove-user'
                REMOVE_USER="$2"
                if [[ -z "$REMOVE_USER" ]]; then show_argument_error_and_exit "Falta nombre de usuario"; fi
                shift
                ;;
            '--list-users')
                OPERATION='list-users'
                ;;
            '--edit-user')
                OPERATION='edit-user'
                EDIT_USER="$2"
                if [[ -z "$EDIT_USER" ]]; then show_argument_error_and_exit "Falta nombre de usuario"; fi
                shift
                ;;
            '--set-obfs')
                OPERATION='set-obfs'
                NEW_OBFS="$2"
                if [[ -z "$NEW_OBFS" ]]; then show_argument_error_and_exit "Falta valor para OBFS"; fi
                shift
                ;;
            '--menu')
                OPERATION='menu'
                ;;
            '-h'|'--help')
                show_usage_and_exit
                ;;
            *)
                show_argument_error_and_exit "Opción desconocida: $1"
                ;;
        esac
        shift
    done
    
    # Si no hay operación, establecer menú por defecto
    if [[ -z "$OPERATION" ]]; then
        OPERATION='menu'
    fi
}

# Función para instalar servidor (extraída del case install)
install_server() {
    check_environment
    if [[ -f "$EXECUTABLE_INSTALL_PATH" && -z "$FORCE" ]]; then
        note "Hysteria ya está instalado. Usa --force para reinstalar."
        return
    fi
    mkdir -p "$CONFIG_DIR"
    init_database
    generate_auth_scripts
    generate_config
    install_hysteria
    save_installer_config
    if [[ "$FORCE_NO_SYSTEMD" != "2" ]]; then
        install_service
        systemctl enable hysteria-server.service
        systemctl start hysteria-server.service
        note "Servicio iniciado."
    else
      
