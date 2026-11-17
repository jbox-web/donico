# Bakefile fixtures

`<name>.txt` here is the `docker-bake.hcl` that the Ruby gem (donico 2.0.6)
writes for `spec/fixtures/bake/<name>.yml`. They were produced by the gem, not
by this binary; the only edit is the second line, where `bin/rake` became
`donico`. Regenerating them from `bin/donico` would turn the specs that read
them into a comparison of the template with itself.

For each fixture, in an empty temporary directory holding the fixture as
`donico.yml`, with `RUBY` and `BUNDLE` the absolute paths printed by
`mise which ruby` and `mise which bundle` run from the gem directory, and
`<gem checkout>` the directory of the Ruby gem:

```sh
BUNDLE_GEMFILE=<gem checkout>/Gemfile \
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DONICO_QUIET=1 \
CI_COMMIT_TIMESTAMP=2026-07-31T00:00:00Z \
"$RUBY" "$BUNDLE" exec "$RUBY" -rrake -I<gem checkout>/lib -rdonico \
  -e 'Donico.load!; Rake::Task["generate-files"].invoke'
sed '2s/bin\/rake/donico/' docker-bake.hcl > <name>.txt
```

`escaping.txt` is the fixture with values that need escaping in HCL (a double
quote and a backslash in build args). `quoted_versions.yml` has no expected
bakefile: it exercises the quoting of the matrix file only.
