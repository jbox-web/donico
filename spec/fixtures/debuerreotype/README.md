# debuerreotype script fixtures

`<name>.sh` here is the build script that "danico" (the Rakefile of the
`debian-base` image repository) hands to `bin/build`, for one matrix row and one
architecture: `templates/debian-build.erb` rendered by Ruby's ERB, comments and
empty lines removed, the remaining lines joined by `;`. A newline ends each
file. They were produced by Ruby from the original template, not by this
binary: `spec/donico/rootfs_spec.cr` compares what `Donico::Rootfs#script`
renders with them, byte for byte.

To regenerate them, with `<debian-base checkout>` the directory of the image
repository that still holds `templates/debian-build.erb`:

```sh
ruby spec/fixtures/debuerreotype/render.rb <debian-base checkout>
```

`render.rb` repeats the three lines of the Rakefile's `build` task (the locals,
the filter, the join) and holds the four cases:

| File | Row | What it exercises |
|------|-----|-------------------|
| `trixie.sh` | trixie 13, amd64 | every default, no APT proxy |
| `trixie-proxy.sh` | trixie 13, arm64 | APT proxy `http://proxy.example.org:3142` in use |
| `jessie-eol.sh` | jessie 8, amd64 | `eol: true`, `debootstrap_url` and three `debootstrap_opts` |
| `bullseye-386.sh` | bullseye 11, 386 | debootstrap architecture `i386`, build directory still named `386` |

The timestamp is `20260730` everywhere: the day before the fixed clock of
`with_project`, which is the default danico computes.

"No APT proxy" is danico with `ENABLE_APT_PROXY=false`. danico with the proxy
enabled and no `apt_proxy` key rendered `export http_proxy=` with an empty
value; donico does not reproduce that, it leaves the proxy out.
