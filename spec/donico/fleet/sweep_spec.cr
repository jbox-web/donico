require "../../spec_helper"

private SEPARATOR = "---------------------"

private def fleet_yaml : String
  <<-YAML
    registry:  harbor.example.org/base
    group:     git@example.org:factory/images
    workspace: docker-images
    images:
      - traefik
      - grafana
      - ruby

    YAML
end

private def clone(env : Donico::Env, *names : String) : Nil
  names.each { |name| Dir.mkdir_p(File.join(env.dir, "docker-images", name)) }
end

# An output that claims to be a terminal.
private class TtyIO < IO::Memory
  def tty? : Bool
    true
  end
end

private NO_VARS = {} of String => String

describe Donico::Fleet::Color do
  it "leaves the text alone when the stream is not a terminal" do
    Donico::Fleet::Color.paint(IO::Memory.new, "ruby", :green, NO_VARS).should eq "ruby"
  end

  it "wraps the text in the colour and a reset on a terminal" do
    Donico::Fleet::Color.paint(TtyIO.new, "ruby", :green, NO_VARS).should eq "\e[32mruby\e[0m"
    Donico::Fleet::Color.paint(TtyIO.new, "ruby", :red, NO_VARS).should eq "\e[31mruby\e[0m"
  end

  # Thor's `set_color`, which the gem's lines went through: no colour when
  # NO_COLOR holds a value (https://no-color.org), nor on a dumb terminal.
  it "leaves the text alone on a terminal when NO_COLOR holds a value" do
    Donico::Fleet::Color.paint(TtyIO.new, "ruby", :green, {"NO_COLOR" => "1"}).should eq "ruby"
  end

  it "still colours when NO_COLOR is set but empty" do
    Donico::Fleet::Color.paint(TtyIO.new, "ruby", :green, {"NO_COLOR" => ""}).should eq "\e[32mruby\e[0m"
  end

  it "leaves the text alone on a terminal whose TERM is dumb" do
    Donico::Fleet::Color.paint(TtyIO.new, "ruby", :red, {"TERM" => "dumb"}).should eq "ruby"
  end
end

private def repos_for(env : Donico::Env) : Donico::Fleet::Repos
  Donico::Fleet::Repos.new(Donico::Fleet::Manifest.load(env), env.dir)
end

private def quiet_runner_for : String -> Donico::Runner
  ->(_dir : String) { RecordingRunner.new.as(Donico::Runner) }
end

describe Donico::Fleet::Sweep do
  it "announces each cloned repository between separators and runs the block there, skipping the others" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "grafana", "ruby")
      dirs = [] of String
      runner_for = ->(dir : String) { dirs << dir; RecordingRunner.new.as(Donico::Runner) }

      failed = Donico::Fleet::Sweep.new(repos_for(env), env, runner_for).call(nil) do |name, _runner|
        env.stdout.puts "running #{name}"
        true
      end

      failed.should eq 0
      dirs.should eq [File.join(env.dir, "docker-images", "grafana"), File.join(env.dir, "docker-images", "ruby")]
      env.stdout.to_s.should eq [
        SEPARATOR, "Enter in grafana", "running grafana", SEPARATOR, "",
        SEPARATOR, "Enter in ruby", "running ruby", SEPARATOR, "",
        "traefik: not cloned, skipping",
      ].join('\n') + "\n"
    end
  end

  it "builds the runner of a repository only for a cloned one" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "ruby")
      dirs = [] of String
      runner_for = ->(dir : String) { dirs << dir; RecordingRunner.new.as(Donico::Runner) }

      Donico::Fleet::Sweep.new(repos_for(env), env, runner_for).call("traefik") { |_name, _runner| true }

      dirs.should be_empty
    end
  end

  it "counts the repositories whose block returned false and goes on after each" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "grafana", "ruby", "traefik")
      visited = [] of String

      failed = Donico::Fleet::Sweep.new(repos_for(env), env, quiet_runner_for).call(nil) do |name, _runner|
        visited << name
        name == "ruby"
      end

      failed.should eq 2
      visited.should eq ["grafana", "ruby", "traefik"]
    end
  end

  it "does not count a repository that is not cloned" do
    with_fleet(fleet_yaml) do |env|
      Donico::Fleet::Sweep.new(repos_for(env), env, quiet_runner_for).call(nil) { |_name, _runner| false }.should eq 0
      env.stdout.to_s.should eq "grafana: not cloned, skipping\nruby: not cloned, skipping\ntraefik: not cloned, skipping\n"
    end
  end

  it "sweeps the one repository named" do
    with_fleet(fleet_yaml) do |env|
      clone(env, "grafana", "ruby")
      visited = [] of String

      Donico::Fleet::Sweep.new(repos_for(env), env, quiet_runner_for).call("ruby") do |name, _runner|
        visited << name
        true
      end

      visited.should eq ["ruby"]
    end
  end

  it "refuses a repository the manifest does not declare" do
    with_fleet(fleet_yaml) do |env|
      expect_raises(Donico::UsageError, "Unknown repository: nope") do
        Donico::Fleet::Sweep.new(repos_for(env), env, quiet_runner_for).call("nope") { |_name, _runner| true }
      end
    end
  end
end
