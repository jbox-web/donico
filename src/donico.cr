# Process entry point, and the only file that calls `exit`. Everything else
# lives under src/donico/ and can be required from a spec without starting the
# CLI. VERSION is defined in src/donico/version.cr, from the DONICO_VERSION
# macro env at compile time.
require "./donico/cli"

exit Donico::CLI.new.run(ARGV)
