require "../../../spec_helper"

private def row(current : String, latest : String?, state : Donico::Fleet::Versions::State = Donico::Fleet::Versions::State::Update, image : String = "traefik") : Donico::Fleet::Versions::Row
  Donico::Fleet::Versions::Row.new(image: image, current: current, latest: latest, state: state, repo: "traefik/traefik", quoted: false)
end

describe Donico::Fleet::Versions::Row do
  describe "#url" do
    it "points at the upstream GitHub repository" do
      row("3.7.8", "3.7.9").url.should eq "https://github.com/traefik/traefik"
    end
  end

  describe "#update?" do
    it "is true only for an available update" do
      row("3.7.8", "3.7.9", Donico::Fleet::Versions::State::Update).update?.should be_true
      row("3.7.9", "3.7.9", Donico::Fleet::Versions::State::Ok).update?.should be_false
    end
  end

  # The rank of the first differing segment decides: 0 is a major, 1 a minor,
  # anything deeper a patch. Predictable on the 4-segment schemes (jruby) and
  # on the 2-segment ones (seaweedfs) that semver rules alone do not cover.
  describe "#bump_kind" do
    it "reports a third-segment change as a patch" do
      row("1.12.4", "1.12.6").bump_kind.should eq :patch
    end

    it "reports a second-segment change as a minor" do
      row("5.2.2", "5.3.1").bump_kind.should eq :minor
      row("4.39", "4.40").bump_kind.should eq :minor
    end

    it "reports a first-segment change as a major" do
      row("13.1.0", "14.0.0").bump_kind.should eq :major
    end

    it "reports a fourth-segment change as a patch" do
      row("10.1.0.0", "10.1.1.0").bump_kind.should eq :patch
    end

    it "is nil when the versions are identical" do
      row("3.7.9", "3.7.9", Donico::Fleet::Versions::State::Ok).bump_kind.should be_nil
    end

    it "is nil when either side is not a numeric version" do
      row("latest", "2026.7.17", Donico::Fleet::Versions::State::Unfixed).bump_kind.should be_nil
      row("3.7.8", nil, Donico::Fleet::Versions::State::Error).bump_kind.should be_nil
    end

    # 1.26.3-01 against 1.26.3-02: the trailing security counter is a patch, not
    # a parse failure.
    it "handles a dashed security suffix" do
      row("1.26.3-01", "1.26.3-02").bump_kind.should eq :patch
    end

    # A missing segment is not zero: 1.2 and 1.2.0 differ, at the third rank.
    it "reports a longer version as a patch of the shorter one" do
      row("1.2", "1.2.1").bump_kind.should eq :patch
    end

    it "compares segments as numbers, not as text" do
      row("1.9.0", "1.10.0").bump_kind.should eq :minor
    end
  end

  describe "#quoted" do
    it "carries whether donico.yml quotes the version scalar" do
      quoted = Donico::Fleet::Versions::Row.new(image: "seaweedfs", current: "4.39", latest: "4.40",
        state: Donico::Fleet::Versions::State::Update, repo: "seaweedfs/seaweedfs", quoted: true)
      quoted.quoted.should be_true
    end
  end

  # The report shows the scalar as donico.yml holds it, quotes included, so a
  # quoted version is visible at a glance (it is the one a bump can break).
  describe "#display_current" do
    it "shows the quotes when the scalar is quoted" do
      quoted = Donico::Fleet::Versions::Row.new(image: "seaweedfs", current: "4.39", latest: "4.40",
        state: Donico::Fleet::Versions::State::Update, repo: "seaweedfs/seaweedfs", quoted: true)
      quoted.display_current.should eq %("4.39")
    end

    it "shows a bare scalar as is" do
      row("3.7.8", "3.7.9").display_current.should eq "3.7.8"
    end
  end
end
