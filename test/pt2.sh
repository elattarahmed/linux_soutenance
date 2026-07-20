#!/usr/bin/env bash
#
# pt2.sh — Part II : Cryptographie
#
# • Permettre la création de clef GPG automatisée.
# • Export automatique de la clef publique dans le coffre.
# • Proposer l'export de la clef privée dans le coffre (changement de poste,
#   stockage à manier avec précaution).
#

#
# NB : tous les appels gpg ci-dessous qui n'attendent pas de saisie
# utilisateur sont explicitement branchés sur /dev/null. gpg hérite sinon du
# stdin de la fonction appelante ; si celle-ci est un jour pilotée via un
# pipe (tests automatisés, script, ...) plutôt qu'un vrai terminal, gpg peut
# lire (et donc perdre) des octets destinés aux prochains `read` du script.
#

pt2_gpg_list_keys() {
    gpg --list-secret-keys --with-colons 2>/dev/null < /dev/null | awk -F: '
        $1=="sec" { print $5 }
        $1=="uid" { print "    " $10 }
    '
}

pt2_gpg_keyids() {
    gpg --list-secret-keys --with-colons 2>/dev/null < /dev/null | awk -F: '$1=="sec" { print $5 }'
}

# Demande un keyid à l'utilisateur si non fourni ; le stocke dans REPLY_KEYID.
pt2_gpg_choose_key() {
    if [ -n "${1:-}" ]; then
        REPLY_KEYID="$1"
    else
        info "clefs disponibles :"
        pt2_gpg_list_keys
        read -rp "Keyid à utiliser : " REPLY_KEYID
    fi
    gpg --list-secret-keys "$REPLY_KEYID" >/dev/null 2>&1 < /dev/null || err "keyid inconnu : $REPLY_KEYID"
}

# Génère une paire de clefs GPG (RSA 4096, 2 ans), exporte automatiquement la
# clef publique dans le coffre, et propose d'y exporter aussi la clef privée.
pt2_gpg_generate() {
    require_vault
    read -rp  "Nom complet : " nom
    read -rp  "Email : " email
    read -rsp "Passphrase : " pass; echo
    read -rsp "Confirmation : " pass2; echo
    [ "$pass" = "$pass2" ] || err "les passphrases ne correspondent pas"

    gpg --batch --generate-key <<EOF || err "échec de la génération de la clef"
Key-Type: RSA
Key-Length: 4096
Name-Real: $nom
Name-Email: $email
Expire-Date: 2y
Passphrase: $pass
%commit
EOF
    unset pass pass2

    local keyid
    keyid="$(pt2_gpg_keyids | tail -n1)"
    info "clef générée : $keyid"

    pt2_gpg_export_public "$keyid"

    read -rp "Exporter également la clef privée dans le coffre ? [o/N] " rep
    [[ "$rep" =~ ^[oO]$ ]] && pt2_gpg_export_private "$keyid"
    return 0
}

# Export : trousseau -> coffre, clef publique (644).
pt2_gpg_export_public() {
    require_vault
    local keyid="${1:-}"
    if [ -z "$keyid" ]; then
        pt2_gpg_choose_key
        keyid="$REPLY_KEYID"
    fi

    local dest="$GPG_DIR/${keyid//[^a-zA-Z0-9@._-]/_}_public.asc"
    gpg --export --armor --yes --output "$dest" -- "$keyid" < /dev/null
    [ -s "$dest" ] || { rm -f "$dest"; err "aucune clef publique trouvée pour « $keyid »"; }
    chmod 644 "$dest"
    info "clef publique exportée : $dest"
}

# Export : trousseau -> coffre, clef privée (600). Confirmation demandée :
# une clef privée reste sensible même stockée dans un coffre chiffré.
pt2_gpg_export_private() {
    require_vault
    local keyid="${1:-}"
    if [ -z "$keyid" ]; then
        pt2_gpg_choose_key
        keyid="$REPLY_KEYID"
    fi

    warn "vous allez exporter une clef PRIVÉE dans le coffre ($keyid)"
    read -rp "Confirmer ? [o/N] " rep
    [[ "$rep" =~ ^[oO]$ ]] || { info "export annulé"; return 0; }

    local dest="$GPG_DIR/${keyid//[^a-zA-Z0-9@._-]/_}_private.asc"
    gpg --export-secret-keys --armor --yes --output "$dest" -- "$keyid" < /dev/null \
        || { rm -f "$dest"; err "export de la clef privée refusé ou introuvable"; }
    chmod 600 "$dest"
    info "clef privée exportée (600) : $dest"
}
