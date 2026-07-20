#!/usr/bin/env bash
#
# pt1.sh — Part I : Mise en place
#
# Réaliser un environnement sécurisé chiffré de 5G :
#   → dans un fichier
#   → LUKS
#   → ext4
#
# Ce fichier ne définit que des fonctions ; il est sourcé par main.sh, qui
# fournit la configuration (CONTAINER_FILE, VAULT_MOUNT, ...) et les aides
# communes (err, info, as_root, ...).
#

# Vérifie que le sous-système device-mapper du noyau est disponible (requis
# par LUKS). Message explicite plutôt que l'erreur cryptique de cryptsetup :
# c'est typiquement absent dans un conteneur (Docker/LXC) non privilégié,
# où LUKS ne peut de toute façon pas fonctionner (dépend du noyau hôte).
pt1_require_devmapper() {
    info "vérification de device-mapper (/dev/mapper/control)..."
    if [ -e /dev/mapper/control ]; then
        info "  -> ok"
        return 0
    fi
    info "  -> absent, tentative : modprobe dm_mod"
    modprobe dm_mod 2>/dev/null
    if [ -e /dev/mapper/control ]; then
        info "  -> ok après modprobe"
        return 0
    fi
    err "device-mapper indisponible (/dev/mapper/control absent).
  - sur une VM : essayez '$([ "$(id -u)" -eq 0 ] || echo sudo )modprobe dm_mod', puis relancez.
  - dans un conteneur (Docker/LXC/...) : LUKS a besoin du device-mapper du
    noyau HÔTE ; il faut charger dm_mod sur l'hôte et relancer le conteneur
    en --privileged avec /dev partagé, ou utiliser une vraie VM."
}

# Crée le conteneur chiffré : fichier de CONTAINER_SIZE, formaté en LUKS,
# puis en ext4 une fois déverrouillé. Le conteneur est refermé à la fin ;
# c'est pt1_container_open qui le monte.
pt1_container_create() {
    info "=== install : vérification des prérequis ==="
    require_command cryptsetup cryptsetup
    require_command mkfs.ext4 e2fsprogs
    pt1_require_devmapper
    [ -e "$CONTAINER_FILE" ] && err "$CONTAINER_FILE existe déjà (supprimez-le pour recommencer)"

    info "=== install : création du conteneur ==="
    info "création du fichier conteneur ($CONTAINER_SIZE) : $CONTAINER_FILE"
    truncate -s "$CONTAINER_SIZE" "$CONTAINER_FILE"
    chmod 600 "$CONTAINER_FILE"
    info "  -> fichier créé ($(du -h "$CONTAINER_FILE" | cut -f1) sur disque, $CONTAINER_SIZE alloués)"

    info "formatage LUKS de $CONTAINER_FILE (une passphrase va être demandée)"
    as_root cryptsetup luksFormat --batch-mode "$CONTAINER_FILE"
    info "  -> luksFormat ok"

    info "ouverture temporaire pour créer le système de fichiers ext4"
    as_root cryptsetup open "$CONTAINER_FILE" "$MAPPER_NAME"
    info "  -> /dev/mapper/$MAPPER_NAME déverrouillé"
    as_root mkfs.ext4 -q "/dev/mapper/$MAPPER_NAME"
    info "  -> ext4 créé"
    as_root cryptsetup close "$MAPPER_NAME"
    info "  -> reverrouillé"

    info "conteneur créé et prêt : $CONTAINER_FILE"
}

# Déverrouille (cryptsetup) et monte le conteneur sur VAULT_MOUNT. Idempotent :
# ne fait rien si le coffre est déjà ouvert.
pt1_container_open() {
    require_command cryptsetup cryptsetup
    pt1_require_devmapper
    [ -e "$CONTAINER_FILE" ] || err "$CONTAINER_FILE introuvable (lancez '$0 install' d'abord)"

    if mountpoint -q "$VAULT_MOUNT" 2>/dev/null; then
        info "coffre déjà ouvert sur $VAULT_MOUNT"
        return 0
    fi

    if [ -e "/dev/mapper/$MAPPER_NAME" ]; then
        info "/dev/mapper/$MAPPER_NAME déjà déverrouillé"
    else
        info "déverrouillage de $CONTAINER_FILE (une passphrase va être demandée)"
        as_root cryptsetup open "$CONTAINER_FILE" "$MAPPER_NAME"
    fi
    mkdir -p "$VAULT_MOUNT"
    as_root mount "/dev/mapper/$MAPPER_NAME" "$VAULT_MOUNT"
    info "coffre ouvert sur $VAULT_MOUNT"
}

# Démonte et reverrouille le conteneur. Idempotent.
pt1_container_close() {
    if mountpoint -q "$VAULT_MOUNT" 2>/dev/null; then
        as_root umount "$VAULT_MOUNT"
    fi
    if [ -e "/dev/mapper/$MAPPER_NAME" ]; then
        as_root cryptsetup close "$MAPPER_NAME"
    fi
    info "coffre fermé"
}
