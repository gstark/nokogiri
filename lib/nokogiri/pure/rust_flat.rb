# frozen_string_literal: true

# Optional native filler for the flat XML table.
# Build it with ext/nokogiri_rust/build.sh.
# The Ruby reader runs when this library is absent.
begin
  require_relative "nokogiri_rust_flat"
rescue LoadError
  # The Ruby reader runs when the native filler is not built.
end
