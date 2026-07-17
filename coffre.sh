#!/usr/bin/env bash
#
# coffre.sh — gestion d'un environnement sécurisé (coffre LUKS)
#
# Part III - Configuration :
#   ssh-template   : crée un fichier de configuration template pour le client ssh (utilisable avec -F)
#   alias          : préconfigure un fichier d'alias dans le coffre + lien symbolique dans $HOME
#   ssh-import     : importe la config + les clefs ssh d'un host existant de ~/.ssh/config vers le coffre
#   perms          : applique les bonnes permissions & attributs aux fichiers du coffre et au conteneur
#
# Part IV - Utilisation :
#   open           : ouvre (déchiffre + monte) l'environnement
#   close          : ferme (démonte + chiffre) l'environnement
#   gpg-import     : importe des clefs gpg (publiques et/ou privées) du coffre vers le trousseau
#   gpg-export     : exporte des clefs gpg (publiques et/ou privées) du trousseau vers le coffre
#
# NB : la Part I (création du conteneur 5G LUKS/ext4, commande « install »)
# est réalisée par un autre membre du groupe — ce script suppose que le
# conteneur $CONTAINER_FILE existe déjà.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Valeurs par défaut (cohérentes avec la Part I), surchargeables par variables
# d'environnement : CONTAINER_FILE=/chemin VAULT_MOUNT=/chemin ./coffre.sh ...
# ---------------------------------------------------------------------------
CONTAINER_FILE="${CONTAINER_FILE:-$HOME/coffre.img}"
VAULT_MOUNT="${VAULT_MOUNT:-$HOME/coffre}"
MAPPER_NAME="${MAPPER_NAME:-coffre}"

GPG_DIR="$VAULT_MOUNT/gpg"
SSH_DIR="$VAULT_MOUNT/ssh"
SSH_KEYS_DIR="$SSH_DIR/keys"
VAULT_SSH_CONFIG="$SSH_DIR/config"
ALIAS_FILE="$VAULT_MOUNT/aliases"
ALIAS_LINK="$HOME/.coffre_aliases"
USER_SSH_CONFIG="${USER_SSH_CONFIG:-$HOME/.ssh/config}"

err()  { printf 'Erreur : %s\n' "$*" >&2; exit 1; }
info() { printf '[coffre] %s\n' "$*"; }

# Le coffre doit être ouvert (monté) pour travailler dedans.
require_vault() {
    [ -d "$VAULT_MOUNT" ] || err "le point de montage $VAULT_MOUNT n'existe pas (ouvrez le coffre d'abord)"
    if ! mountpoint -q "$VAULT_MOUNT"; then
        info "attention : $VAULT_MOUNT n'est pas un point de montage (coffre non ouvert ?)"
    fi
    mkdir -p "$SSH_DIR" "$SSH_KEYS_DIR"
}

# ---------------------------------------------------------------------------
# Part III.1 — template de configuration ssh (ssh -F <fichier>)
# ---------------------------------------------------------------------------
cmd_ssh_template() {
    require_vault
    if [ -e "$VAULT_SSH_CONFIG" ]; then
        info "le fichier $VAULT_SSH_CONFIG existe déjà, rien à faire"
        return 0
    fi
    cat > "$VAULT_SSH_CONFIG" <<EOF
# Configuration ssh du coffre — à utiliser avec : ssh -F $VAULT_SSH_CONFIG <host>
# (ou via l'alias evsh, cf. fichier d'alias du coffre)

# Exemple d'entrée :
# Host exemple
#     HostName 192.0.2.10
#     User client
#     Port 22
#     IdentityFile $SSH_KEYS_DIR/exemple_id_ed25519
#     IdentitiesOnly yes

Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    HashKnownHosts yes
    UserKnownHostsFile $SSH_DIR/known_hosts
EOF
    chmod 600 "$VAULT_SSH_CONFIG"
    info "template créé : $VAULT_SSH_CONFIG"
    info "utilisation : ssh -F $VAULT_SSH_CONFIG <host>"
}

# ---------------------------------------------------------------------------
# Part III.2 — fichier d'alias dans le coffre + lien symbolique
# ---------------------------------------------------------------------------
cmd_alias() {
    require_vault
    cat > "$ALIAS_FILE" <<EOF
# Alias de l'environnement sécurisé
alias evsh="ssh -F $VAULT_SSH_CONFIG"
EOF
    chmod 600 "$ALIAS_FILE"
    ln -sfn "$ALIAS_FILE" "$ALIAS_LINK"
    info "fichier d'alias créé : $ALIAS_FILE"
    info "lien symbolique : $ALIAS_LINK -> $ALIAS_FILE"
    info "pour l'activer, ajoutez à votre ~/.bashrc ou ~/.zshrc :"
    info "    [ -r $ALIAS_LINK ] && source $ALIAS_LINK"
}

# ---------------------------------------------------------------------------
# Part III.3 — import de la config & des clefs ssh existantes, par host
# ---------------------------------------------------------------------------

# Liste les hosts « concrets » (sans jokers * ou ?) de ~/.ssh/config
list_hosts() {
    awk 'tolower($1)=="host" { for (i=2; i<=NF; i++) if ($i !~ /[*?]/) print $i }' \
        "$USER_SSH_CONFIG" | sort -u
}

# Affiche le bloc de configuration d'un host donné
host_block() {
    awk -v host="$1" '
        tolower($1)=="host" {
            inblock = 0
            for (i=2; i<=NF; i++) if ($i == host) inblock = 1
        }
        inblock { print }
    ' "$USER_SSH_CONFIG"
}

cmd_ssh_import() {
    require_vault
    [ -r "$USER_SSH_CONFIG" ] || err "aucun fichier $USER_SSH_CONFIG à parser"

    mapfile -t hosts < <(list_hosts)
    [ "${#hosts[@]}" -gt 0 ] || err "aucun host trouvé dans $USER_SSH_CONFIG"

    local host="${1:-}"
    if [ -z "$host" ]; then
        info "hosts trouvés dans $USER_SSH_CONFIG :"
        select host in "${hosts[@]}"; do
            [ -n "$host" ] && break
        done
    else
        printf '%s\n' "${hosts[@]}" | grep -Fqx -- "$host" \
            || err "host « $host » introuvable dans $USER_SSH_CONFIG"
    fi

    # Le template sert de base au fichier de config du coffre
    [ -e "$VAULT_SSH_CONFIG" ] || cmd_ssh_template
    if awk 'tolower($1)=="host" { for (i=2; i<=NF; i++) print $i }' "$VAULT_SSH_CONFIG" \
           | grep -Fqx -- "$host"; then
        err "le host « $host » est déjà présent dans $VAULT_SSH_CONFIG"
    fi

    # Recopie le bloc en réécrivant chaque IdentityFile vers le coffre,
    # et copie la paire de clefs correspondante.
    local line key pub dest
    {
        echo ""
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*[Ii]dentity[Ff]ile[[:space:]=]+(.+)$ ]]; then
                key="${BASH_REMATCH[1]}"
                key="${key/#\~/$HOME}"
                key="${key//\$HOME/$HOME}"
                [ -r "$key" ] || err "clef privée introuvable : $key"
                dest="$SSH_KEYS_DIR/${host}_$(basename "$key")"
                cp "$key" "$dest"
                chmod 600 "$dest"
                pub="$key.pub"
                if [ -r "$pub" ]; then
                    cp "$pub" "$dest.pub"
                    chmod 644 "$dest.pub"
                fi
                printf '    IdentityFile %s\n' "$dest"
                info "clef copiée : $key -> $dest" >&2
            else
                printf '%s\n' "$line"
            fi
        done < <(host_block "$host")
    } >> "$VAULT_SSH_CONFIG"

    info "host « $host » importé dans $VAULT_SSH_CONFIG"
    info "test : ssh -F $VAULT_SSH_CONFIG $host   (ou : evsh $host)"
}

# ---------------------------------------------------------------------------
# Part III.4 — permissions & attributs
# ---------------------------------------------------------------------------
cmd_perms() {
    # Conteneur : lecture/écriture pour le propriétaire uniquement,
    # + attribut « nodump » (exclu des sauvegardes dump) si le fs le permet.
    if [ -e "$CONTAINER_FILE" ]; then
        chmod 600 "$CONTAINER_FILE"
        chattr +d "$CONTAINER_FILE" 2>/dev/null \
            && info "attribut +d (nodump) posé sur $CONTAINER_FILE" \
            || info "chattr non supporté sur $CONTAINER_FILE (ignoré)"
        info "conteneur : $CONTAINER_FILE -> 600"
    fi

    [ -d "$VAULT_MOUNT" ] || return 0
    chmod 700 "$VAULT_MOUNT"
    [ -d "$SSH_DIR" ]      && chmod 700 "$SSH_DIR"
    [ -d "$SSH_KEYS_DIR" ] && chmod 700 "$SSH_KEYS_DIR"
    [ -e "$VAULT_SSH_CONFIG" ] && chmod 600 "$VAULT_SSH_CONFIG"
    [ -e "$ALIAS_FILE" ]       && chmod 600 "$ALIAS_FILE"

    # Clefs : privées en 600, publiques en 644
    if [ -d "$SSH_KEYS_DIR" ]; then
        find "$SSH_KEYS_DIR" -type f ! -name '*.pub' -exec chmod 600 {} +
        find "$SSH_KEYS_DIR" -type f   -name '*.pub' -exec chmod 644 {} +
    fi
    info "permissions appliquées sur $VAULT_MOUNT"
}

# ---------------------------------------------------------------------------
# Part IV — installation / ouverture / fermeture de l'environnement
# ---------------------------------------------------------------------------

# cryptsetup et mount demandent les droits root
as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

cmd_open() {
    [ -e "$CONTAINER_FILE" ] || err "$CONTAINER_FILE introuvable (créez d'abord le conteneur — Part I)"
    mountpoint -q "$VAULT_MOUNT" 2>/dev/null && { info "coffre déjà ouvert sur $VAULT_MOUNT"; return 0; }

    if [ ! -e "/dev/mapper/$MAPPER_NAME" ]; then
        as_root cryptsetup open "$CONTAINER_FILE" "$MAPPER_NAME"
    fi
    mkdir -p "$VAULT_MOUNT"
    as_root mount "/dev/mapper/$MAPPER_NAME" "$VAULT_MOUNT"
    cmd_perms
    info "coffre ouvert sur $VAULT_MOUNT"
}

cmd_close() {
    if mountpoint -q "$VAULT_MOUNT" 2>/dev/null; then
        as_root umount "$VAULT_MOUNT"
    fi
    if [ -e "/dev/mapper/$MAPPER_NAME" ]; then
        as_root cryptsetup close "$MAPPER_NAME"
    fi
    info "coffre fermé"
}

# ---------------------------------------------------------------------------
# Part IV — import / export des clefs gpg entre le coffre et le trousseau
# ---------------------------------------------------------------------------

# Import : coffre -> trousseau. Sans argument, importe tous les fichiers du
# répertoire gpg du coffre ; sinon uniquement le fichier donné.
cmd_gpg_import() {
    require_vault
    local target="${1:-}"
    if [ -n "$target" ]; then
        [ -r "$target" ] || target="$GPG_DIR/$target"
        [ -r "$target" ] || err "fichier de clef introuvable : $target"
        gpg --import "$target"
        info "clef importée dans le trousseau : $target"
        return 0
    fi
    [ -d "$GPG_DIR" ] || err "aucun répertoire $GPG_DIR dans le coffre"
    local found=0 f
    for f in "$GPG_DIR"/*.asc "$GPG_DIR"/*.gpg; do
        [ -e "$f" ] || continue
        found=1
        gpg --import "$f"
        info "importé : $f"
    done
    [ "$found" -eq 1 ] || err "aucune clef (*.asc, *.gpg) trouvée dans $GPG_DIR"
}

# Export : trousseau -> coffre. Clef publique toujours exportée ; la clef
# privée uniquement à la demande (--secret), stockée en 600 dans le coffre.
cmd_gpg_export() {
    require_vault
    local keyid="${1:-}" secret="${2:-}"
    [ -n "$keyid" ] || err "usage : $0 gpg-export <keyid|email> [--secret]"
    mkdir -p "$GPG_DIR"
    chmod 700 "$GPG_DIR"

    local pub="$GPG_DIR/${keyid//[^a-zA-Z0-9@._-]/_}_public.asc"
    gpg --export --armor -o "$pub" -- "$keyid"
    [ -s "$pub" ] || { rm -f "$pub"; err "aucune clef publique trouvée pour « $keyid »"; }
    chmod 644 "$pub"
    info "clef publique exportée : $pub"

    if [ "$secret" = "--secret" ]; then
        local priv="$GPG_DIR/${keyid//[^a-zA-Z0-9@._-]/_}_private.asc"
        gpg --export-secret-keys --armor -o "$priv" -- "$keyid" \
            || { rm -f "$priv"; err "export de la clef privée refusé ou introuvable"; }
        chmod 600 "$priv"
        info "clef privée exportée (600, dans le coffre chiffré) : $priv"
    fi
}

# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage : $0 <commande> [arguments]

Part III - Configuration :
  ssh-template            crée le template de config ssh du coffre (usage : ssh -F)
  alias                   crée le fichier d'alias (evsh) + lien symbolique $ALIAS_LINK
  ssh-import [host]       importe config + clefs d'un host de $USER_SSH_CONFIG dans le coffre
  perms                   applique permissions & attributs (coffre + conteneur)

Part IV - Utilisation :
  open                    ouvre (déchiffre + monte) le coffre sur $VAULT_MOUNT
                          (la création du conteneur — Part I — est gérée par un autre script)
  close                   ferme (démonte) le coffre
  gpg-import [fichier]    importe les clefs gpg du coffre dans le trousseau
  gpg-export <id> [--secret]
                          exporte une clef gpg du trousseau vers le coffre

Variables : CONTAINER_FILE (défaut $HOME/coffre.img), VAULT_MOUNT (défaut $HOME/coffre),
            MAPPER_NAME (défaut coffre)
EOF
    exit 1
}

case "${1:-}" in
    ssh-template) cmd_ssh_template ;;
    alias)        cmd_alias ;;
    ssh-import)   shift; cmd_ssh_import "${1:-}" ;;
    perms)        cmd_perms ;;
    open)         cmd_open ;;
    close)        cmd_close ;;
    gpg-import)   shift; cmd_gpg_import "${1:-}" ;;
    gpg-export)   shift; cmd_gpg_export "${1:-}" "${2:-}" ;;
    *)            usage ;;
esac
