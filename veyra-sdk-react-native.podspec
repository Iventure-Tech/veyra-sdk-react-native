# Veyra React Native SDK — CocoaPods spec (consumed by React Native autolinking).
#
# The native SDK ships as a prebuilt XCFramework hosted on the Veyra artifact server
# (authenticated: your repository credentials must be in ~/.netrc — see the README).
# It is downloaded and checksum-verified at `pod install`; nothing else to configure.
#
# The Swift API (VeyraSDK / VeyraSoftPOS / VeyraWallet) is compiled from ios/VeyraFacade/,
# which the release train copies in — so this pod is self-contained: framework + facade + bridge.

require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

# Pinned by the release train to the SDK version this wrapper shipped with.
veyra_kmp_version  = "1.0.18" # VEYRA-KMP-VERSION-MARKER (pinned by the release train)
veyra_kmp_zip_url  = "https://repo.veyra.co/releases/files/VeyraKMP-1.0.18.xcframework.zip" # VEYRA-KMP-URL-MARKER
veyra_kmp_checksum = "0986204af152593a620743de3e9c44e574483b4a83e02ed7d10199fc6b90bbf3" # VEYRA-KMP-CHECKSUM-MARKER

Pod::Spec.new do |s|
  s.name         = "veyra-sdk-react-native"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["repository"]["url"].sub(/\.git\z/, "")
  s.license      = { :type => "Commercial", :text => "See README.md" }
  s.author       = "Veyra"
  s.platforms    = { :ios => "15.0" }
  s.source       = { :git => package["repository"]["url"], :tag => s.version.to_s }
  s.swift_version = "5.9"

  s.source_files = "ios/**/*.{swift,h,m}"

  if veyra_kmp_zip_url.empty?
    raise <<~MSG
      [veyra-sdk-react-native] This is a development build of the package — the Veyra
      framework URL has not been pinned. Install a released version from npm.
    MSG
  end

  # Download + verify + unpack the framework, once. curl -n reads ~/.netrc for the
  # artifact-server credentials (same mechanism as Swift Package Manager); the checksum
  # is the SwiftPM one (SHA-256 of the zip).
  #
  # This runs HERE, in the podspec body, and not in a `prepare_command`: React Native
  # autolinking installs this package from node_modules as a local (`:path`) pod, and
  # CocoaPods runs `prepare_command` only for pods it downloads itself — so for every
  # React Native app that hook never fires. The podspec, by contrast, is evaluated on
  # every `pod install`. Already unpacked (or dropped in by a local build) ⇒ no-op.
  artifacts = File.join(__dir__, "Artifacts")
  unless File.directory?(File.join(artifacts, "VeyraKMP.xcframework"))
    Pod::UI.puts "[veyra-sdk-react-native] Fetching VeyraKMP #{veyra_kmp_version}…" if defined?(Pod::UI)
    fetched = system("/bin/bash", "-c", <<~CMD)
      set -euo pipefail
      mkdir -p "#{artifacts}"
      cd "#{artifacts}"
      curl -n -f -sS -L -o VeyraKMP.xcframework.zip "#{veyra_kmp_zip_url}"
      echo "#{veyra_kmp_checksum}  VeyraKMP.xcframework.zip" | shasum -a 256 -c -
      unzip -q VeyraKMP.xcframework.zip
      rm VeyraKMP.xcframework.zip
    CMD
    raise <<~MSG unless fetched
      [veyra-sdk-react-native] Could not fetch the Veyra framework from
      #{veyra_kmp_zip_url}
      The download is authenticated: put your Veyra repository credentials in ~/.netrc
      (chmod 600) as described in the README, then run `pod install` again.
    MSG
  end

  s.vendored_frameworks = "Artifacts/VeyraKMP.xcframework"

  # The framework version travels with the podspec so a mismatch is impossible.
  s.info_plist = { "VeyraKMPVersion" => veyra_kmp_version }

  s.dependency "React-Core"
end
