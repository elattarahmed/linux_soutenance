#!/usr/bin/env bash
#
# pt3.sh — Part III : Configuration
#
# • Template de configuration ssh (utilisable avec -F).
# • Fichier d'alias (evsh) + lien symbolique.
# • Import de la config & des clefs ssh déjà existantes, par host.
# • Permissions & attributs sur les fichiers du coffre et le conteneur.
#

pt3_ssh_template() {
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

pt3_alias() {
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

# Liste les hosts « concrets » (sans jokers * ou ?) de ~/.ssh/config
pt3_list_hosts() {
    awk 'tolower($1)=="host" { for (i=2; i<=NF; i++) if ($i !~ /[*?]/) print $i }' \
        "$USER_SSH_CONFIG" | sort -u
}

# Affiche le bloc de configuration d'un host donné
pt3_host_block() {
    awk -v host="$1" '
        tolower($1)=="host" {
            inblock = 0
            for (i=2; i<=NF; i++) if ($i == host) inblock = 1
        }
        inblock { print }
    ' "$USER_SSH_CONFIG"
}

pt3_ssh_import() {
    require_vault
    [ -r "$USER_SSH_CONFIG" ] || err "aucun fichier $USER_SSH_CONFIG à parser"

    local hosts=()
    while IFS= read -r h; do hosts+=("$h"); done < <(pt3_list_hosts)
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
    [ -e "$VAULT_SSH_CONFIG" ] || pt3_ssh_template
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
        done < <(pt3_host_block "$host")
    } >> "$VAULT_SSH_CONFIG"

    info "host « $host » importé dans $VAULT_SSH_CONFIG"
    info "test : ssh -F $VAULT_SSH_CONFIG $host   (ou : evsh $host)"
}

pt3_perms() {
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
    [ -d "$GPG_DIR" ]      && chmod 700 "$GPG_DIR"
    [ -e "$VAULT_SSH_CONFIG" ] && chmod 600 "$VAULT_SSH_CONFIG"
    [ -e "$ALIAS_FILE" ]       && chmod 600 "$ALIAS_FILE"

    # Clefs ssh : privées en 600, publiques en 644
    if [ -d "$SSH_KEYS_DIR" ]; then
        find "$SSH_KEYS_DIR" -type f ! -name '*.pub' -exec chmod 600 {} +
        find "$SSH_KEYS_DIR" -type f   -name '*.pub' -exec chmod 644 {} +
    fi
    # Clefs gpg : privées en 600, publiques en 644
    if [ -d "$GPG_DIR" ]; then
        find "$GPG_DIR" -type f -name '*_private.asc' -exec chmod 600 {} +
        find "$GPG_DIR" -type f -name '*_public.asc'  -exec chmod 644 {} +
    fi
    info "permissions appliquées sur $VAULT_MOUNT"
}
