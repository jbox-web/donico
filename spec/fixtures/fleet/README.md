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

The one edit made to an expected image README: the line `bin/rake help` became
`donico help` (this binary has no Rakefile).

The gem is retired, so these files are no longer regenerated: they are frozen
reference outputs. A deliberate change of the format is written here by hand,
in the same change as the code, and never by copying what `bin/donico-manager` writes,
which would turn the specs that read them into a comparison of the code with
itself.

If an image directory is added or renamed, every expected file changes with it,
the heritage tree included. The heritage tree reads the `Dockerfile`s and the
manifest's `registries`, which the two README generators do not.
