#!/usr/bin/env bash
# ==============================================================================
# USB/IP Manager – Limpeza completa do thin client Linux
# ==============================================================================
# Remove TUDO que o install.sh instalou, incluindo configuração.
# Use quando quiser partir de uma instalação do zero.
#
# Uso:
#   sudo bash ./uninstall.sh
#   sudo bash ./uninstall.sh --keep-config    # preserva /etc/usbip-manager/
#   sudo bash ./uninstall.sh --force          # não pede confirmação
#
# O que é removido:
#   Serviços systemd  : usbip-manager.service, usbipd.service,
#                       usbip-manager-udev@.service
#   Regra udev        : /etc/udev/rules.d/90-usbip-manager.rules
#   Módulos autoload  : /etc/modules-load.d/usbip-manager.conf
#   Binários          : /opt/usbip-manager/
#   Configuração      : /etc/usbip-manager/  (removida salvo --keep-config)
#   Estado runtime    : /run/usbip-manager/
#   Bloqueio de módulo: /etc/modprobe.d/usbip-manager-blacklist.conf (se existir)
#
# O que NÃO é removido:
#   Pacotes apt (python3, usbip, usbutils, hwdata) – foram instalados pelo
#   sistema e podem ser usados por outros serviços.
#   Módulos do kernel usbip-core / usbip-host (só são descarregados se idle).
# ==============================================================================
set -euo pipefail

# ── Caminhos ────────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/usbip-manager"
CONFIG_DIR="/etc/usbip-manager"
SYSTEMD_DIR="/etc/systemd/system"
UDEV_RULE="/etc/udev/rules.d/90-usbip-manager.rules"
MODULES_FILE="/etc/modules-load.d/usbip-manager.conf"
MODPROBE_BLACKLIST="/etc/modprobe.d/usbip-manager-blacklist.conf"
RUNTIME_DIR="/run/usbip-manager"

SERVICES=(
    "usbip-manager.service"
    "usbip-manager-udev@.service"   # template – para todas as instâncias ativas
    "usbipd.service"
)

KEEP_CONFIG=0
FORCE=0

# ── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; GRAY='\033[0;37m'; RESET='\033[0m'

step()  { echo -e "\n${CYAN}[UNINSTALL]${RESET} $*"; }
ok()    { echo -e "  ${GREEN}OK${RESET}  $*"; }
skip()  { echo -e "  ${GRAY}--${RESET}  $*"; }
warn()  { echo -e "  ${YELLOW}!!${RESET}  $*"; }
fatal() { echo -e "${RED}ERRO: $*${RESET}" >&2; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || fatal "Execute como root: sudo bash ./uninstall.sh"
}

confirm() {
    [[ "${FORCE}" -eq 1 ]] && return 0
    read -rp "$* [s/N] " answer
    [[ "${answer,,}" == "s" ]]
}

remove_dir() {
    local path="$1" label="${2:-$1}"
    if [[ -d "${path}" ]]; then
        rm -rf "${path}"
        ok "Diretório '${label}' removido"
    else
        skip "Diretório '${label}' não encontrado"
    fi
}

remove_file() {
    local path="$1" label="${2:-$1}"
    if [[ -f "${path}" ]]; then
        rm -f "${path}"
        ok "Arquivo '${label}' removido"
    else
        skip "Arquivo '${label}' não encontrado"
    fi
}

# ── Argumentos ───────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
USB/IP Manager – limpeza completa do thin client Linux.

Uso:
  sudo bash ./uninstall.sh [opções]

Opções:
  --keep-config    Preserva /etc/usbip-manager/ (útil para reinstalar)
  --force          Não pede confirmação
  -h, --help       Exibe esta ajuda
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-config) KEEP_CONFIG=1; shift ;;
        --force)       FORCE=1;       shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Opção desconhecida: $1" >&2; usage; exit 2 ;;
    esac
done

# ── Início ───────────────────────────────────────────────────────────────────

require_root

echo -e "${YELLOW}"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════╗
║      USB/IP Manager – Limpeza completa do thin client        ║
╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"

if [[ "${KEEP_CONFIG}" -eq 1 ]]; then
    warn "Modo --keep-config: /etc/usbip-manager/ será preservado"
fi

confirm "Remover todos os arquivos, serviços e regras do USB/IP Manager?" \
    || { echo "Cancelado."; exit 0; }

# ── 1. Parar e desabilitar serviços ──────────────────────────────────────────

step "1/6  Serviços systemd"

# Para instâncias ativas do template usbip-manager-udev@
mapfile -t active_udev < <(
    systemctl list-units --all --no-legend 'usbip-manager-udev@*' 2>/dev/null \
    | awk '{print $1}' || true
)
for unit in "${active_udev[@]}"; do
    [[ -z "${unit}" ]] && continue
    systemctl stop "${unit}" 2>/dev/null && ok "Parado: ${unit}" || true
done

for svc in usbip-manager.service usbipd.service; do
    if systemctl list-unit-files "${svc}" 2>/dev/null | grep -q "${svc}"; then
        systemctl disable --now "${svc}" 2>/dev/null \
            && ok "Serviço '${svc}' parado e desabilitado" \
            || warn "Não foi possível parar '${svc}' (pode já estar parado)"
    else
        skip "Serviço '${svc}' não registrado"
    fi
done

# ── 2. Descarregar módulos do kernel (se possível) ────────────────────────────

step "2/6  Módulos do kernel"

for mod in usbip-host usbip-core; do
    if lsmod 2>/dev/null | grep -q "^${mod//-/_}"; then
        rmmod "${mod//-/_}" 2>/dev/null \
            && ok "Módulo '${mod}' descarregado" \
            || warn "Módulo '${mod}' em uso, não descarregado (normal se busy)"
    else
        skip "Módulo '${mod}' não carregado"
    fi
done

# ── 3. Arquivos systemd ───────────────────────────────────────────────────────

step "3/6  Arquivos de unidade systemd"

remove_file "${SYSTEMD_DIR}/usbip-manager.service"       "usbip-manager.service"
remove_file "${SYSTEMD_DIR}/usbip-manager-udev@.service" "usbip-manager-udev@.service"
remove_file "${SYSTEMD_DIR}/usbipd.service"              "usbipd.service"

systemctl daemon-reload
ok "daemon-reload executado"

# ── 4. Regras udev e módulos autoload ─────────────────────────────────────────

step "4/6  Regras udev e autoload de módulos"

remove_file "${UDEV_RULE}"           "90-usbip-manager.rules"
remove_file "${MODULES_FILE}"        "modules-load.d/usbip-manager.conf"
remove_file "${MODPROBE_BLACKLIST}"  "modprobe.d/usbip-manager-blacklist.conf"

udevadm control --reload-rules 2>/dev/null && ok "Regras udev recarregadas" || true

# ── 5. Binários instalados ────────────────────────────────────────────────────

step "5/6  Binários e estado de runtime"

remove_dir "${INSTALL_DIR}"  "/opt/usbip-manager"
remove_dir "${RUNTIME_DIR}"  "/run/usbip-manager"

# ── 6. Configuração ────────────────────────────────────────────────────────────

step "6/6  Configuração"

if [[ "${KEEP_CONFIG}" -eq 1 ]]; then
    skip "/etc/usbip-manager/ preservada (--keep-config)"
else
    remove_dir "${CONFIG_DIR}" "/etc/usbip-manager"
fi

# ── Conclusão ──────────────────────────────────────────────────────────────────

echo -e "${GREEN}"
cat <<'DONE'
╔══════════════════════════════════════════════════════════════╗
║  Limpeza concluída.                                          ║
║                                                              ║
║  Para reinstalar:                                            ║
║    sudo bash ./install.sh --server-ip <IP> \                 ║
║                           --notify-host <IP>                 ║
╚══════════════════════════════════════════════════════════════╝
DONE
echo -e "${RESET}"
