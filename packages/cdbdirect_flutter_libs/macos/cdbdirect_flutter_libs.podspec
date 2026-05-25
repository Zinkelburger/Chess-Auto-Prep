Pod::Spec.new do |s|
  s.name             = 'cdbdirect_flutter_libs'
  s.version          = '0.1.0'
  s.summary          = 'Bundled libcdbdirect for ChessDB TerarkDB dumps'
  s.description      = 'Prebuilt cdbdirect reader for offline ChessDB eval lookups.'
  s.homepage         = 'https://github.com/chess-auto-prep/chess-auto-prep'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Chess-Auto-Prep' => 'dev@example.com' }
  s.source           = { :path => '.' }

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  arch = `uname -m`.strip
  native_path = case arch
                when 'arm64'
                  File.expand_path('../native/macos-arm64/libcdbdirect.dylib', __dir__)
                when 'x86_64'
                  File.expand_path('../native/macos-x64/libcdbdirect.dylib', __dir__)
                end

  if native_path && File.exist?(native_path)
    s.prepare_command = "cp \"#{native_path}\" libcdbdirect.dylib"
    s.vendored_libraries = 'libcdbdirect.dylib'
  end
end
