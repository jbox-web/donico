# Matrix file fixtures

`<name>.yml` here is the `.gitlab-ci/extends/.matrix.yml` that the Ruby gem
(donico 2.0.6) writes for `spec/fixtures/bake/<name>.yml`. They were produced
by the gem, not by this binary; the only edit is the second line, where
`bin/rake` became `donico`.

The gem is retired, so these files are no longer regenerated: they are frozen
reference outputs. A deliberate change of the format is written here by hand,
in the same change as the code, and never by copying what `bin/donico` prints,
which would turn the specs that read them into a comparison of the code with
itself.

`quoted_versions.yml` is the fixture that exercises quoting: its versions
`"0.17"`, `"18"` and `"1.31.8"` (real fleet values) come out single-quoted,
single-quoted and bare. It has no expected bakefile.
