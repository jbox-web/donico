# Process entry point, and the only file that calls `exit`. Everything else
# lives under src/donico/ and can be required from a spec without starting the
# CLI. VERSION is defined in src/donico/version.cr, from the DONICO_VERSION
# macro env at compile time.
require "./donico/cli"
require "./donico/fleet/cli"

# One binary, two names: invoked as `donico-manager` (a symlink to it) it is
# the fleet tool, under any other name the image tool.
exit(Donico.fleet_program?(PROGRAM_NAME) ? Donico::Fleet::CLI.new.run(ARGV) : Donico::CLI.new.run(ARGV))
