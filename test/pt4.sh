#!/usr/bin/env bash
#
# pt4.sh — Part IV : Utilisation
#
# Commandes exposées par l'appel du script :
#   • installer l'environnement (Part I)
#   • ouvrir l'environnement
#   • fermer l'environnement
#   • importer les clefs gpg (coffre -> trousseau)
#   • exporter les clefs gpg (trousseau -> coffre)
#

# install = créer le conteneur (Part I), l'ouvrir le temps d'initialiser
# l'arborescence attendue et les permissions (Part III), puis le refermer.
pt4_install() {
    pt1_container_create
    info "=== install : initialisation de l'arborescence ==="
    pt1_container_open
    mkdir -p "$GPG_DIR" "$SSH_KEYS_DIR"
    pt3_perms
    pt1_container_close
    info "coffre installé : $CONTAINER_FILE"
    info "utilisez '$0 open' pour l'ouvrir"
}

pt4_open() {
    pt1_container_open
    pt3_perms
}

pt4_close() {
    pt1_container_close
}

# Import : coffre -> trousseau. Sans argument, importe tous les fichiers du
# répertoire gpg du coffre ; sinon uniquement le fichier donné.
pt4_gpg_import() {
    require_command gpg gnupg
    require_vault
    local target="${1:-}"
    if [ -n "$target" ]; then
        [ -r "$target" ] || target="$GPG_DIR/$target"
        [ -r "$target" ] || err "fichier de clef introuvable : $target"
        gpg --import "$target"
        info "clef importée dans le trousseau : $target"
        return 0
    fi

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
# privée uniquement avec --secret (confirmation demandée par pt2_gpg_export_private).
pt4_gpg_export() {
    require_command gpg gnupg
    local keyid="${1:-}" secret="${2:-}"
    [ -n "$keyid" ] || err "usage : $0 gpg-export <keyid|email> [--secret]"
    pt2_gpg_export_public "$keyid"
    [ "$secret" = "--secret" ] && pt2_gpg_export_private "$keyid"
    return 0
}
