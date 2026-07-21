#!/usr/bin/env bash
#
# pt2.sh — Part II : Cryptographie
#
# Repris de gpg.sh (script initial du projet). Adapté pour s'intégrer au
# reste du projet : VAULT_MOUNT/GPG_DIR viennent de main.sh (plus de
# /mnt/coffre codé en dur), require_vault/require_command/err/info/warn sont
# les aides communes déjà utilisées par pt1/pt3/pt4, et KEYID est référencé
# via "${KEYID:-}" pour rester compatible avec le set -u de main.sh.
#
# gpg_menu() et gpg_import_keys() de gpg.sh original ne sont pas repris ici :
# le menu interactif fait double emploi avec le dispatch de main.sh, et
# l'import (coffre -> trousseau) est déjà couvert par pt4_gpg_import.
#

gpg_list_keys() {
    gpg --list-secret-keys --with-colons 2>/dev/null | grep '^sec' | cut -d: -f5
    gpg --list-secret-keys --with-colons 2>/dev/null | grep '^uid' | cut -d: -f10 | sed 's/^/    /'
}

gpg_keyids() {
    gpg --list-secret-keys --with-colons 2>/dev/null | grep '^sec' | cut -d: -f5
}

gpg_choose_key() {
    info "Clés disponibles :"
    gpg_list_keys
    read -rp "Keyid à utiliser : " KEYID
    gpg --list-secret-keys "$KEYID" >/dev/null 2>&1 || err "Keyid inconnu : $KEYID"
}

# Génère une paire de clefs GPG (RSA 4096, 2 ans), exporte automatiquement la
# clef publique dans le coffre, et propose d'y exporter aussi la clef privée
# (cas d'un changement de poste).
gpg_generate_key() {
    require_command gpg gnupg
    require_vault
    read -rp  "Nom complet : " nom
    read -rp  "Email : " email
    read -rsp "Passphrase : " pass; echo
    read -rsp "Confirmation : " pass2; echo
    if [ "$pass" != "$pass2" ]; then
        err "Les passphrases ne correspondent pas."
    fi

    gpg --batch --generate-key <<EOF || err "Échec de la génération."
Key-Type: RSA
Key-Length: 4096
Name-Real: $nom
Name-Email: $email
Expire-Date: 2y
Passphrase: $pass
%commit
EOF
    info "Clé générée avec succès."

    KEYID=$(gpg_keyids | tail -n1)
    gpg_export_public

    read -rp "Exporter également la clef privée dans le coffre ? [o/N] " rep
    [[ "$rep" =~ ^[oO]$ ]] && gpg_export_private
    return 0
}

gpg_export_public() {
    require_vault
    [ -n "${KEYID:-}" ] || gpg_choose_key
    gpg --export --armor --yes --output "$GPG_DIR/${KEYID}_pub.asc" "$KEYID" \
        || err "export de la clef publique échoué"
    chmod 644 "$GPG_DIR/${KEYID}_pub.asc"
    info "Clé publique exportée : $GPG_DIR/${KEYID}_pub.asc"
}

gpg_export_private() {
    require_vault
    [ -n "${KEYID:-}" ] || gpg_choose_key
    warn "vous allez exporter une clé PRIVÉE dans le coffre."
    read -rp "Confirmer ? [o/N] " rep
    [[ "$rep" =~ ^[oO]$ ]] || { info "export annulé"; return 0; }

    gpg --export-secret-keys --armor --yes --output "$GPG_DIR/${KEYID}_priv.asc" "$KEYID" \
        || err "export de la clef privée échoué"
    chmod 600 "$GPG_DIR/${KEYID}_priv.asc"
    info "Clé privée exportée : $GPG_DIR/${KEYID}_priv.asc (permissions 600)"
}
