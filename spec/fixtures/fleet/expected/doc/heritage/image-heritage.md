# Chaîne d'héritage des images

← [CLAUDE.md](../../CLAUDE.md)

**Description :** Arbre d'héritage des images — généré par `donico-manager heritage` depuis les lignes `FROM` des Dockerfiles. Ne pas éditer manuellement.

---

## Arbre

```
debian-base  (pipeline debuerreotype — pas de Dockerfile standard)
└── debuerreotype
    ├── alloy
    └── ruby
```

**Note :** toute mise à jour d'une image entraîne un rebuild en cascade de toutes les images indentées en dessous d'elle.

## Images avec base externe

| Image | FROM |
|---|---|
| traefik | `docker.io/library/traefik` |

## Images à base indéterminée

Déclarées au manifest, mais sans Dockerfile lisible dans le workspace — clonez-les puis relancez pour les voir prendre leur place dans l'arbre.

| Image |
|---|
| absent |
| nocategory |
