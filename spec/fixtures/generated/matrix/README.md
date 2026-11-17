# Matrix file fixtures

`<name>.yml` here is the `.gitlab-ci/extends/.matrix.yml` that the Ruby gem
(donico 2.0.6) writes for `spec/fixtures/bake/<name>.yml`. They were produced
by the gem, not by this binary; the only edit is the second line, where
`bin/rake` became `donico`.

For each fixture, in an empty temporary directory holding the fixture as
`donico.yml`, with `RUBY` and `BUNDLE` the absolute paths printed by
`mise which ruby` and `mise which bundle` run from the gem directory, and
`DONICO_RELEASE` unset, and `<gem checkout>` the directory of the Ruby gem:

```sh
BUNDLE_GEMFILE=<gem checkout>/Gemfile \
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DONICO_QUIET=1 \
"$RUBY" "$BUNDLE" exec "$RUBY" -rrake -I<gem checkout>/lib -rdonico \
  -e 'Donico.load!; Rake::Task["generate-files"].invoke'
sed '2s/bin\/rake/donico/' .gitlab-ci/extends/.matrix.yml > <name>.yml
```

`quoted_versions.yml` is the fixture that exercises quoting: its versions
`"0.17"`, `"18"` and `"1.31.8"` (real fleet values) come out single-quoted,
single-quoted and bare. It has no expected bakefile.
