# Bakefile fixtures

`<name>.txt` here is the `docker-bake.hcl` that the Ruby gem (donico 2.0.6)
writes for `spec/fixtures/bake/<name>.yml`. They were produced by the gem, not
by this binary; the only edit is the second line, where `bin/rake` became
`donico`.

The gem is retired, so these files are no longer regenerated: they are frozen
reference outputs. A deliberate change of the format is written here by hand,
in the same change as the code, and never by copying what `bin/donico` prints,
which would turn the specs that read them into a comparison of the code with
itself.

`escaping.txt` is the fixture with values that need escaping in HCL (a double
quote and a backslash in build args). `quoted_versions.yml` has no expected
bakefile: it exercises the quoting of the matrix file only.
