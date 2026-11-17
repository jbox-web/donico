require "../env"
require "../image"
require "../inspec"
require "../runner"

module Donico
  module Tasks
    # Runs the Inspec harness on the build tag, once with the row's inputs or,
    # when the row declares `test_variants`, once per variant with the variant
    # appended. Every variant runs even when an earlier one failed, so one
    # run reports all of them; the result is 0 only when all passed.
    class Test
      getter inspec : Inspec

      def initialize(@image : Image, @env : Env, @runner : Runner, @inspec_image : String)
        @inspec = Inspec.new(@env, @runner, @inspec_image)
      end

      def run : Int32
        inputs = @image.inspec_inputs
        variants = @image.entry.test_variants
        return @inspec.run("donico", @image.build_tag, inputs) if variants.empty?

        # An interrupt ends the whole task: the next variant would start a new
        # container after the user (or the CI) asked to stop.
        failed = false
        variants.each do |variant|
          code = @inspec.run("donico", @image.build_tag, inputs + variant)
          return code if @inspec.interrupted?
          failed = true unless code.zero?
        end
        failed ? 1 : 0
      end
    end
  end
end
