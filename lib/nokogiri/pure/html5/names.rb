# frozen_string_literal: true

module Nokogiri
  module Pure
    module Html5
      # Tag and attribute renames copied from Gumbo's gperf tables.
      module Names
        SVG_TAGS = {
          "altglyph" => "altGlyph",
          "altglyphdef" => "altGlyphDef",
          "altglyphitem" => "altGlyphItem",
          "animatecolor" => "animateColor",
          "animatemotion" => "animateMotion",
          "animatetransform" => "animateTransform",
          "clippath" => "clipPath",
          "feblend" => "feBlend",
          "fecolormatrix" => "feColorMatrix",
          "fecomponenttransfer" => "feComponentTransfer",
          "fecomposite" => "feComposite",
          "feconvolvematrix" => "feConvolveMatrix",
          "fediffuselighting" => "feDiffuseLighting",
          "fedisplacementmap" => "feDisplacementMap",
          "fedistantlight" => "feDistantLight",
          "feflood" => "feFlood",
          "fefunca" => "feFuncA",
          "fefuncb" => "feFuncB",
          "fefuncg" => "feFuncG",
          "fefuncr" => "feFuncR",
          "fegaussianblur" => "feGaussianBlur",
          "feimage" => "feImage",
          "femerge" => "feMerge",
          "femergenode" => "feMergeNode",
          "femorphology" => "feMorphology",
          "feoffset" => "feOffset",
          "fepointlight" => "fePointLight",
          "fespecularlighting" => "feSpecularLighting",
          "fespotlight" => "feSpotLight",
          "fetile" => "feTile",
          "feturbulence" => "feTurbulence",
          "foreignobject" => "foreignObject",
          "glyphref" => "glyphRef",
          "lineargradient" => "linearGradient",
          "radialgradient" => "radialGradient",
          "textpath" => "textPath"
        }.freeze

        SVG_ATTRS = {
          "attributename" => "attributeName",
          "attributetype" => "attributeType",
          "basefrequency" => "baseFrequency",
          "baseprofile" => "baseProfile",
          "calcmode" => "calcMode",
          "clippathunits" => "clipPathUnits",
          "diffuseconstant" => "diffuseConstant",
          "edgemode" => "edgeMode",
          "filterunits" => "filterUnits",
          "glyphref" => "glyphRef",
          "gradienttransform" => "gradientTransform",
          "gradientunits" => "gradientUnits",
          "kernelmatrix" => "kernelMatrix",
          "kernelunitlength" => "kernelUnitLength",
          "keypoints" => "keyPoints",
          "keysplines" => "keySplines",
          "keytimes" => "keyTimes",
          "lengthadjust" => "lengthAdjust",
          "limitingconeangle" => "limitingConeAngle",
          "markerheight" => "markerHeight",
          "markerunits" => "markerUnits",
          "markerwidth" => "markerWidth",
          "maskcontentunits" => "maskContentUnits",
          "maskunits" => "maskUnits",
          "numoctaves" => "numOctaves",
          "pathlength" => "pathLength",
          "patterncontentunits" => "patternContentUnits",
          "patterntransform" => "patternTransform",
          "patternunits" => "patternUnits",
          "pointsatx" => "pointsAtX",
          "pointsaty" => "pointsAtY",
          "pointsatz" => "pointsAtZ",
          "preservealpha" => "preserveAlpha",
          "preserveaspectratio" => "preserveAspectRatio",
          "primitiveunits" => "primitiveUnits",
          "refx" => "refX",
          "refy" => "refY",
          "repeatcount" => "repeatCount",
          "repeatdur" => "repeatDur",
          "requiredextensions" => "requiredExtensions",
          "requiredfeatures" => "requiredFeatures",
          "specularconstant" => "specularConstant",
          "specularexponent" => "specularExponent",
          "spreadmethod" => "spreadMethod",
          "startoffset" => "startOffset",
          "stddeviation" => "stdDeviation",
          "stitchtiles" => "stitchTiles",
          "surfacescale" => "surfaceScale",
          "systemlanguage" => "systemLanguage",
          "tablevalues" => "tableValues",
          "targetx" => "targetX",
          "targety" => "targetY",
          "textlength" => "textLength",
          "viewbox" => "viewBox",
          "viewtarget" => "viewTarget",
          "xchannelselector" => "xChannelSelector",
          "ychannelselector" => "yChannelSelector",
          "zoomandpan" => "zoomAndPan"
        }.freeze

        FOREIGN_ATTRS = {
          "xlink:actuate" => ["actuate", :xlink],
          "xlink:arcrole" => ["arcrole", :xlink],
          "xlink:href" => ["href", :xlink],
          "xlink:role" => ["role", :xlink],
          "xlink:show" => ["show", :xlink],
          "xlink:title" => ["title", :xlink],
          "xlink:type" => ["type", :xlink],
          "xml:lang" => ["lang", :xml],
          "xml:space" => ["space", :xml],
          "xmlns" => ["xmlns", :xmlns],
          "xmlns:xlink" => ["xlink", :xmlns]
        }.freeze

        module_function

        def svg_tag(name)
          SVG_TAGS[name] || name
        end

        def svg_attr(name)
          SVG_ATTRS[name] || name
        end

        def foreign_attr(name)
          FOREIGN_ATTRS[name]
        end
      end
    end
  end
end
