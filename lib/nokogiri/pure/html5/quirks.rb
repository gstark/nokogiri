# frozen_string_literal: true

module Nokogiri
  module Pure
    module Html5
      # Quirks-mode rules copied from Gumbo's public and system identifier tables.
      module Quirks
        NO_QUIRKS = 0
        QUIRKS = 1
        LIMITED_QUIRKS = 2

        PUBLIC_PREFIXES = [
          "+//Silmaril//dtd html Pro v0r11 19970101//",
          "-//AdvaSoft Ltd//DTD HTML 3.0 asWedit + extensions//",
          "-//AS//DTD HTML 3.0 asWedit + extensions//",
          "-//IETF//DTD HTML 2.0 Level 1//",
          "-//IETF//DTD HTML 2.0 Level 2//",
          "-//IETF//DTD HTML 2.0 Strict Level 1//",
          "-//IETF//DTD HTML 2.0 Strict Level 2//",
          "-//IETF//DTD HTML 2.0 Strict//",
          "-//IETF//DTD HTML 2.0//",
          "-//IETF//DTD HTML 2.1E//",
          "-//IETF//DTD HTML 3.0//",
          "-//IETF//DTD HTML 3.2 Final//",
          "-//IETF//DTD HTML 3.2//",
          "-//IETF//DTD HTML 3//",
          "-//IETF//DTD HTML Level 0//",
          "-//IETF//DTD HTML Level 1//",
          "-//IETF//DTD HTML Level 2//",
          "-//IETF//DTD HTML Level 3//",
          "-//IETF//DTD HTML Strict Level 0//",
          "-//IETF//DTD HTML Strict Level 1//",
          "-//IETF//DTD HTML Strict Level 2//",
          "-//IETF//DTD HTML Strict Level 3//",
          "-//IETF//DTD HTML Strict//",
          "-//IETF//DTD HTML//",
          "-//Metrius//DTD Metrius Presentational//",
          "-//Microsoft//DTD Internet Explorer 2.0 HTML Strict//",
          "-//Microsoft//DTD Internet Explorer 2.0 HTML//",
          "-//Microsoft//DTD Internet Explorer 2.0 Tables//",
          "-//Microsoft//DTD Internet Explorer 3.0 HTML Strict//",
          "-//Microsoft//DTD Internet Explorer 3.0 HTML//",
          "-//Microsoft//DTD Internet Explorer 3.0 Tables//",
          "-//Netscape Comm. Corp.//DTD HTML//",
          "-//Netscape Comm. Corp.//DTD Strict HTML//",
          "-//O'Reilly and Associates//DTD HTML 2.0//",
          "-//O'Reilly and Associates//DTD HTML Extended 1.0//",
          "-//O'Reilly and Associates//DTD HTML Extended Relaxed 1.0//",
          "-//SoftQuad Software//DTD HoTMetaL PRO 6.0::19990601::)extensions to HTML 4.0//",
          "-//SoftQuad//DTD HoTMetaL PRO 4.0::19971010::extensions to HTML 4.0//",
          "-//Spyglass//DTD HTML 2.0 Extended//",
          "-//SQ//DTD HTML 2.0 HoTMetaL + extensions//",
          "-//Sun Microsystems Corp.//DTD HotJava HTML//",
          "-//Sun Microsystems Corp.//DTD HotJava Strict HTML//",
          "-//W3C//DTD HTML 3 1995-03-24//",
          "-//W3C//DTD HTML 3.2 Draft//",
          "-//W3C//DTD HTML 3.2 Final//",
          "-//W3C//DTD HTML 3.2//",
          "-//W3C//DTD HTML 3.2S Draft//",
          "-//W3C//DTD HTML 4.0 Frameset//",
          "-//W3C//DTD HTML 4.0 Transitional//",
          "-//W3C//DTD HTML Experimental 19960712//",
          "-//W3C//DTD HTML Experimental 970421//",
          "-//W3C//DTD W3 HTML//",
          "-//W3O//DTD W3 HTML 3.0//",
          "-//WebTechs//DTD Mozilla HTML 2.0//",
          "-//WebTechs//DTD Mozilla HTML//"
        ].freeze

        PUBLIC_EXACT = [
          "-//W3O//DTD W3 HTML Strict 3.0//EN//",
          "-/W3C/DTD HTML 4.0 Transitional/EN",
          "HTML"
        ].freeze

        SYSTEM_EXACT = [
          "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd"
        ].freeze

        LIMITED_PUBLIC_PREFIXES = [
          "-//W3C//DTD XHTML 1.0 Frameset//",
          "-//W3C//DTD XHTML 1.0 Transitional//"
        ].freeze

        SYSTEM_DEPENDENT_PUBLIC_PREFIXES = [
          "-//W3C//DTD HTML 4.01 Frameset//",
          "-//W3C//DTD HTML 4.01 Transitional//"
        ].freeze

        module_function

        def compute(name, public_id, system_id, has_system_id)
          public_id = public_id.to_s
          system_id = system_id.to_s
          if name.nil? || name != "html" ||
              prefix?(public_id, PUBLIC_PREFIXES) ||
              exact?(public_id, PUBLIC_EXACT) ||
              exact?(system_id, SYSTEM_EXACT) ||
              (!has_system_id && prefix?(public_id, SYSTEM_DEPENDENT_PUBLIC_PREFIXES))
            return QUIRKS
          end

          if prefix?(public_id, LIMITED_PUBLIC_PREFIXES) ||
              (has_system_id && prefix?(public_id, SYSTEM_DEPENDENT_PUBLIC_PREFIXES))
            return LIMITED_QUIRKS
          end

          NO_QUIRKS
        end

        def prefix?(value, list)
          return false if value.empty?

          folded = value.downcase
          list.any? { |item| folded.start_with?(item.downcase) }
        end

        def exact?(value, list)
          return false if value.empty?

          folded = value.downcase
          list.any? { |item| folded == item.downcase }
        end
      end
    end
  end
end
