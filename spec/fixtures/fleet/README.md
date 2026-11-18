# Fixture fleet

A small fleet configuration repository, used by the specs of the fleet commands
(`donico-manager`). `donico-manager.yml`, `templates/README.md` and `todo.yml`
sit at its root; `docker-images/` holds the image directories, none of them a
git repository (`Repos#cloned?` of both the gem and this binary only asks for a
directory). `absent` is declared in the manifest and deliberately not cloned.

| Image | What it exercises |
|-------|-------------------|
| `traefik` | category `web`, a `github_repo`, three tags with `%<version>s` and `%<distro>s`; heritage: an external base (`docker.io/library/traefik`) |
| `debian-base` | listed in `debian_images`: the root README names its tags after the `distro`, the image README after the `image_name` of each row; no `github_repo` |
| `debuerreotype` | configuration in `danico.yml`; category `distro`, which is not in `categories`: counted in the total, shown in no table; heritage: its `FROM` is under the manifest's `debian_base` registry, so it hangs from the virtual `debian-base` root |
| `ruby` | heritage: derived from `debuerreotype` (a `FROM ... AS runtime` stage), two levels under `debian-base`; an unquoted `version: 3.10`, which Ruby's Psych reads as the float 3.1 (the gem, and so the expected files, print `3.1`); donico 3 itself refuses it |
| `alloy` | `image_name: grafana-alloy` and a `registry` that is not the manifest's: the root README uses the directory name and the image's registry, the image README the `image_name`; heritage: no root `Dockerfile`, two under `dockerfiles/` whose `FROM` differ (`trixie`, derived from `debuerreotype`, sorts before `unstable`, an external base): the first one wins |
| `nocategory` | no `category` and no `description`: skipped by the root README, `?` and the placeholder in the image README; heritage: a `Dockerfile` with no `FROM` line, so its base is undetermined |
| `absent` | declared, not cloned: undetermined in the heritage tree |

The categories are `web`, `tools` and `desktop`; `desktop` has no image, only
the planned ones of `todo.yml`.

## Expected files

`expected/README.md`, `expected/docker-images/<image>/README.md` and
`expected/doc/heritage/image-heritage.md` (the manifest's `heritage_output`)
were produced by the Ruby gem `donico-manager` (commit 6ac3b37), not by this
binary: `spec/donico/fleet/readme_spec.cr`, `image_readme_spec.cr` and
`heritage_spec.cr` compare what `Fleet::Readme`, `Fleet::ImageReadme` and
`Fleet::Heritage` write with them, byte for byte.

To regenerate them, on a copy of this directory (the gem writes in place),
with `<gem>` the checkout of the gem and `RUBY` and `BUNDLE` the paths that
`mise which ruby` and `mise which bundle` print there:

```sh
cp -R spec/fixtures/fleet "$HOME/.local/tmp/fleet-copy" && cd "$HOME/.local/tmp/fleet-copy"
for command in update-readme update-image-readmes heritage; do
  BUNDLE_GEMFILE=<gem>/Gemfile LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
    "$RUBY" "$BUNDLE" exec "$RUBY" -I<gem>/lib -rdonico_manager \
    -e 'DonicoManager::CLI.start(ARGV)' "$command"
done
```

then copy `README.md`, each `docker-images/<image>/README.md` and
`doc/heritage/image-heritage.md` back into `expected/`. The one edit made to an expected image README: the line
`bin/rake help` becomes `donico help` (this binary has no Rakefile; design
section 8, item 2).

If an image directory is added or renamed, every expected file is regenerated
the same way, the heritage tree included. The heritage tree reads the
`Dockerfile`s and the manifest's `registries`, which the two README generators
do not.
