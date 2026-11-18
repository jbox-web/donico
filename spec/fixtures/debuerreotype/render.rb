# frozen_string_literal: true

# Renders templates/debian-build.erb of a debian-base checkout the way its
# Rakefile does (the `build` task of danico): same locals, same filter, same
# join. Writes one file per case next to this script. See README.md.
require "erb"

reference = ARGV.fetch(0) { abort "usage: ruby render.rb <debian-base checkout>" }
template = File.read(File.join(reference, "templates", "debian-build.erb"))

# The Rakefile's DEBOOTSTRAP_ARCH_MAP.
DEBOOTSTRAP_ARCH_MAP = { "386" => "i386" }.freeze

# What the Rakefile reads from danico.yml when a key is absent.
DEFAULTS = {
  debootstrap_url: "http://deb.debian.org/debian",
  build_opts:      ["--debian"],
  old_distro:      false,
  apt_proxy:       "",
  enable_proxy:    "false",
  timestamp:       "20260730",
}.freeze

CASES = {
  "trixie" => { distro_name: "trixie", distro_version: 13, arch: "amd64" },
  "trixie-proxy" => {
    distro_name: "trixie", distro_version: 13, arch: "arm64",
    apt_proxy: "http://proxy.example.org:3142", enable_proxy: "true",
  },
  "jessie-eol" => {
    distro_name: "jessie", distro_version: 8, arch: "amd64", old_distro: true,
    debootstrap_url: "http://archive.debian.org/debian",
    build_opts: ["--debian-eol", "--no-check-gpg", "--keyring=/usr/share/keyrings/debian-archive-removed-keys.gpg"],
  },
  "bullseye-386" => { distro_name: "bullseye", distro_version: 11, arch: "386" },
}.freeze

CASES.each do |name, overrides|
  locals = DEFAULTS.merge(overrides)
  arch = locals.fetch(:arch)
  build_dir = "#{locals.fetch(:distro_name)}-#{arch}-#{locals.fetch(:timestamp)}"
  locals = locals.merge(arch: DEBOOTSTRAP_ARCH_MAP[arch] || arch, build_dir: build_dir, build_tar: "#{build_dir}.tar")

  build_script = ERB.new(template).result_with_hash(locals)
  build_cmd = build_script.split("\n").reject(&:empty?).reject { |l| l.start_with?("#") }

  File.write(File.join(__dir__, "#{name}.sh"), "#{build_cmd.join(";")}\n")
end
