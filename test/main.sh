#!/usr/bin/env bash
#
# main.sh — coffre : environnement sécurisé chiffré (LUKS + ext4)
#
# Point d'entrée unique du projet. Regroupe les 4 parties du sujet, chacune
# dans son propre fichier, sourcé ci-dessous :
#   pt1.sh  Part I   - Mise en place  (conteneur fichier, LUKS, ext4)
#   pt2.sh  Part II  - Cryptographie  (génération & export de clefs GPG)
#   pt3.sh  Part III - Configuration  (ssh, alias, permissions)
#   pt4.sh  Part IV  - Utilisation    (install / open / close / gpg-import / gpg-export)
#
# Usage : ./main.sh <commande> [arguments]  (voir usage() ci-dessous)
#
set -euo pipefail

# Trace complète de chaque commande exécutée : DEBUG=1 ./main.sh <commande>
[ "${DEBUG:-0}" = "1" ] && set -x

# ---------------------------------------------------------------------------
# Emplacement du script, pour sourcer pt1.sh..pt4.sh quel que soit le cwd
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# ---------------------------------------------------------------------------
# Configuration (surchargeable par variables d'environnement)
# ---------------------------------------------------------------------------
CONTAINER_FILE="${CONTAINER_FILE:-$HOME/coffre.img}"
CONTAINER_SIZE="${CONTAINER_SIZE:-5G}"
VAULT_MOUNT="${VAULT_MOUNT:-$HOME/coffre}"
MAPPER_NAME="${MAPPER_NAME:-coffre}"
USER_SSH_CONFIG="${USER_SSH_CONFIG:-$HOME/.ssh/config}"

GPG_DIR="$VAULT_MOUNT/gpg"
SSH_DIR="$VAULT_MOUNT/ssh"
SSH_KEYS_DIR="$SSH_DIR/keys"
VAULT_SSH_CONFIG="$SSH_DIR/config"
ALIAS_FILE="$VAULT_MOUNT/aliases"
ALIAS_LINK="$HOME/.coffre_aliases"

# ---------------------------------------------------------------------------
# Aides communes, utilisées par pt1.sh .. pt4.sh
# ---------------------------------------------------------------------------
err()  { printf 'Erreur : %s\n' "$*" >&2; exit 1; }
info() { printf '[coffre] %s\n' "$*"; }
warn() { printf '[coffre] attention : %s\n' "$*" >&2; }

# cryptsetup / mount demandent les droits root
as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# Vérifie qu'une commande est disponible ; sinon indique la commande à
# exécuter pour installer le paquet correspondant (selon le gestionnaire de
# paquets détecté) et s'arrête. N'installe rien à la place de l'utilisateur.
require_command() {
    local cmd="$1" pkg="$2" prefix=""
    info "vérification de la commande « $cmd »..."
    if command -v "$cmd" >/dev/null 2>&1; then
        info "  -> ok ($(command -v "$cmd"))"
        return 0
    fi
    [ "$(id -u)" -eq 0 ] || prefix="sudo "

    local install_cmd
    if command -v apt-get >/dev/null 2>&1; then install_cmd="apt-get install -y $pkg"
    elif command -v dnf    >/dev/null 2>&1; then install_cmd="dnf install -y $pkg"
    elif command -v yum    >/dev/null 2>&1; then install_cmd="yum install -y $pkg"
    elif command -v pacman >/dev/null 2>&1; then install_cmd="pacman -S $pkg"
    elif command -v apk    >/dev/null 2>&1; then install_cmd="apk add $pkg"
    elif command -v zypper >/dev/null 2>&1; then install_cmd="zypper install -y $pkg"
    else install_cmd="<installez le paquet $pkg avec votre gestionnaire de paquets>"
    fi

    err "$cmd introuvable. Installez-le avec : ${prefix}${install_cmd}"
}

# Le coffre doit être ouvert (monté) pour travailler dedans ; prépare aussi
# l'arborescence attendue (gpg/, ssh/keys/).
require_vault() {
    [ -d "$VAULT_MOUNT" ] || err "le point de montage $VAULT_MOUNT n'existe pas (lancez '$0 open' d'abord)"
    mountpoint -q "$VAULT_MOUNT" || warn "$VAULT_MOUNT n'est pas un point de montage (coffre non ouvert ?)"
    mkdir -p "$GPG_DIR" "$SSH_KEYS_DIR"
}

# ---------------------------------------------------------------------------
# Chargement des 4 parties (fonctions uniquement, aucun effet de bord)
# ---------------------------------------------------------------------------
# shellcheck source=pt1.sh
source "$SCRIPT_DIR/pt1.sh"
# shellcheck source=pt2.sh
source "$SCRIPT_DIR/pt2.sh"
# shellcheck source=pt3.sh
source "$SCRIPT_DIR/pt3.sh"
# shellcheck source=pt4.sh
source "$SCRIPT_DIR/pt4.sh"

# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage : $0 <commande> [arguments]

Part IV - Utilisation :
  install                 crée le conteneur chiffré (Part I) et initialise le coffre
  open                    ouvre (déchiffre + monte) le coffre sur $VAULT_MOUNT
  close                   ferme (démonte + verrouille) le coffre
  gpg-import [fichier]    importe les clefs gpg du coffre dans le trousseau
  gpg-export <id> [--secret]
                          exporte une clef gpg du trousseau vers le coffre

Part II - Cryptographie :
  gpg-generate            génère une paire de clefs gpg, exporte la clef publique
                          (et, sur confirmation, la clef privée) dans le coffre

Part III - Configuration :
  ssh-template            crée le template de config ssh du coffre (usage : ssh -F)
  alias                   crée le fichier d'alias (evsh) + lien symbolique $ALIAS_LINK
  ssh-import [host]       importe config + clefs d'un host de $USER_SSH_CONFIG dans le coffre
  perms                   applique permissions & attributs (coffre + conteneur)

Variables : CONTAINER_FILE (défaut $HOME/coffre.img), CONTAINER_SIZE (défaut 5G),
            VAULT_MOUNT (défaut $HOME/coffre), MAPPER_NAME (défaut coffre)
EOF
    exit 1
}

info "commande : ${1:-<aucune>} ${*:2}"

case "${1:-}" in
    install)      pt4_install ;;
    open)         pt4_open ;;
    close)        pt4_close ;;
    gpg-import)   shift; pt4_gpg_import "${1:-}" ;;
    gpg-export)   shift; pt4_gpg_export "${1:-}" "${2:-}" ;;
    gpg-generate) pt2_gpg_generate ;;
    ssh-template) pt3_ssh_template ;;
    alias)        pt3_alias ;;
    ssh-import)   shift; pt3_ssh_import "${1:-}" ;;
    perms)        pt3_perms ;;
    *)            usage ;;
esac
