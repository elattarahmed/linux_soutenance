#!/bin/bash
VAULT_MNT="/mnt/coffre" 
GPG_DIR="$VAULT_MNT/gpg"


check_vault_open() {
    if ! mountpoint -q "$VAULT_MNT"; then
        echo "Erreur : le coffre n'est pas ouvert" >&2
        return 1
    fi
    mkdir -p "$GPG_DIR"
    chmod 700 "$GPG_DIR"
}

gpg_list_keys() {
    gpg --list-secret-keys --with-colons 2>/dev/null | grep '^sec' | cut -d: -f5
    gpg --list-secret-keys --with-colons 2>/dev/null | grep '^uid' | cut -d: -f10 | sed 's/^/    /'
}

gpg_keyids() {
    gpg --list-secret-keys --with-colons 2>/dev/null | grep '^sec' | cut -d: -f5
}


gpg_choose_key() {
    echo "Clés disponibles :"
    gpg_list_keys
    read -rp "Keyid à utiliser : " KEYID
    if ! gpg --list-secret-keys "$KEYID" >/dev/null 2>&1; then
        echo "Keyid inconnu." >&2
        return 1
    fi
}


gpg_generate_key() {
    read -rp  "Nom complet : " nom
    read -rp  "Email : " email
    read -rsp "Passphrase : " pass; echo
    read -rsp "Confirmation : " pass2; echo
    if [ "$pass" != "$pass2" ]; then
        echo "Les passphrases ne correspondent pas." >&2
        return 1
    fi

    gpg --batch --generate-key <<EOF || { echo "Échec de la génération." >&2; return 1; }
Key-Type: RSA
Key-Length: 4096
Name-Real: $nom
Name-Email: $email
Expire-Date: 2y
Passphrase: $pass
%commit
EOF
    echo "Clé générée avec succès."

    KEYID=$(gpg_keyids | tail -n1)
    gpg_export_public
}

gpg_export_public() {
    [ -z "$KEYID" ] && { gpg_choose_key || return 1; }
    gpg --export --armor --yes --output "$GPG_DIR/${KEYID}_pub.asc" "$KEYID" || return 1
    chmod 644 "$GPG_DIR/${KEYID}_pub.asc"
    echo "Clé publique exportée : $GPG_DIR/${KEYID}_pub.asc"
}

gpg_export_private() {
    [ -z "$KEYID" ] && { gpg_choose_key || return 1; }
    echo "ATTENTION : vous allez exporter une clé PRIVÉE dans le coffre."
    read -rp "Confirmer ? [o/N] " rep
    [[ "$rep" =~ ^[oO]$ ]] || return 1

    gpg --export-secret-keys --armor --yes --output "$GPG_DIR/${KEYID}_priv.asc" "$KEYID" || return 1
    chmod 600 "$GPG_DIR/${KEYID}_priv.asc"
    echo "Clé privée exportée : $GPG_DIR/${KEYID}_priv.asc (permissions 600)"
}

# gpg_import_keys() {
#    echo "Clés présentes dans le coffre :"
#    ls "$GPG_DIR"/*.asc 2>/dev/null | sed 's|.*/||'
#    read -rp "Fichier à importer (ou 'tout') : " choix
#    if [ "$choix" = "tout" ]; then
#        gpg --import "$GPG_DIR"/*.asc
#    else
#        gpg --import "$GPG_DIR/$choix"
#    fi
#}

# Menu principal de la partie GPG
gpg_menu() {
    check_vault_open || return 1
    echo "=== Gestion GPG ==="
    echo "1) Générer une paire de clés"
    echo "2) Exporter la clé publique vers le coffre"
    echo "3) Exporter la clé privée vers le coffre"
    echo "4) Importer des clés du coffre"
    read -rp "Choix : " c
    case "$c" in
        1) gpg_generate_key ;;
        2) gpg_export_public ;;
        3) gpg_export_private ;;
        4) gpg_import_keys ;;
        *) echo "Choix invalide." ;;
    esac
}

