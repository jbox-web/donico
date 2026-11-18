require "../../../spec_helper"

# The policies the manifest declares: which image tracks nothing, which is held
# back, which is held to a minor series. They are fleet configuration, so the
# specs declare them.
private POLICY_MANIFEST = <<-YAML
  registry:  harbor.example.org/base
  group:     git@example.org:factory/images
  workspace: .
  images:
    - traefik
    - mise
    - commitlint: { check_versions: false }
    - icinga2:    { pinned: true }
    - loki:       { constrain: "3.6" }

  YAML

private def with_policy(& : Donico::Fleet::Versions::Policy ->) : Nil
  with_fleet(POLICY_MANIFEST) do |env|
    yield Donico::Fleet::Versions::Policy.new(fleet_repos_of(env).manifest)
  end
end

describe Donico::Fleet::Versions::Policy do
  describe "#skip?" do
    it "skips an image that tracks no upstream version" do
      with_policy(&.skip?("commitlint").should(be_true))
    end

    it "does not skip a regular image" do
      with_policy(&.skip?("traefik").should(be_false))
    end
  end

  describe "#pinned?" do
    it "is true for an image the manifest holds back" do
      with_policy(&.pinned?("icinga2").should(be_true))
    end

    it "is false for a regular image" do
      with_policy(&.pinned?("traefik").should(be_false))
    end
  end

  describe "#constraint_for" do
    it "returns the minor series an image is held to" do
      with_policy { |policy| policy.constraint_for("loki").should eq "3.6" }
    end

    it "returns nil for an unconstrained image" do
      with_policy { |policy| policy.constraint_for("traefik").should be_nil }
    end

    # Keyed on the exact name: a prefix match would hold loki-extra to loki's
    # series.
    it "does not match on a partial image name" do
      with_policy { |policy| policy.constraint_for("loki-extra").should be_nil }
    end
  end

  describe "#classify" do
    it "reports an unversioned image as unfixed, whatever upstream says" do
      with_policy { |policy| policy.classify(image: "mise", current: "latest", latest: "2026.7.17").should eq Donico::Fleet::Versions::State::Unfixed }
    end

    it "reports a missing upstream version as an error" do
      with_policy do |policy|
        policy.classify(image: "traefik", current: "3.7.9", latest: nil).should eq Donico::Fleet::Versions::State::Error
        policy.classify(image: "traefik", current: "3.7.9", latest: "").should eq Donico::Fleet::Versions::State::Error
      end
    end

    it "reports equal versions as up to date" do
      with_policy { |policy| policy.classify(image: "traefik", current: "3.7.9", latest: "3.7.9").should eq Donico::Fleet::Versions::State::Ok }
    end

    it "reports differing versions as an available update" do
      with_policy { |policy| policy.classify(image: "traefik", current: "3.7.8", latest: "3.7.9").should eq Donico::Fleet::Versions::State::Update }
    end

    it "reports a deliberately held image as pinned even when upstream moved" do
      with_policy { |policy| policy.classify(image: "icinga2", current: "2.15.5", latest: "2.16.0").should eq Donico::Fleet::Versions::State::Pinned }
    end

    # An unfixed image has no version to compare, so it wins over the error
    # branch even when the upstream lookup itself failed.
    it "reports an unversioned image as unfixed even without an upstream version" do
      with_policy { |policy| policy.classify(image: "mise", current: "latest", latest: nil).should eq Donico::Fleet::Versions::State::Unfixed }
    end

    # Error comes before pinned: nothing was resolved, so nothing is held.
    it "reports a pinned image whose lookup failed as an error" do
      with_policy { |policy| policy.classify(image: "icinga2", current: "2.15.5", latest: nil).should eq Donico::Fleet::Versions::State::Error }
    end

    # Pinned comes before ok: held back is what the report says, even when
    # upstream has not moved.
    it "reports a pinned image at its upstream version as pinned" do
      with_policy { |policy| policy.classify(image: "icinga2", current: "2.15.5", latest: "2.15.5").should eq Donico::Fleet::Versions::State::Pinned }
    end
  end
end
