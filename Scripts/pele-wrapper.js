// Appended verbatim to pele-bundle.js by Scripts/bundle-pele.sh.
// Bridges Pele's render() to the single entry point called from Swift by
// PeleRenderer (JavaScriptCore) in
// Sources/PicoMarkdownView/Renderer/PeleRenderer.swift.
//
// Pele themes its SVG with CSS custom properties (`var(--pele-bg,#fff)`),
// which only a browser resolves. The Swift side draws the SVG itself, so the
// wrapper substitutes every `var()` with the host theme's value, or Pele's
// own fallback, and strips the custom-property declarations from the root
// style. The returned markup contains no `var(` at all.
(function (global) {
  'use strict';

  // `--_bg:var(--pele-bg,#fff);` private aliases Pele declares on the root
  // <svg> style, each used as `var(--_bg)` throughout the drawing.
  var ALIAS_DECLARATION = /--_([a-z]+):((?:[^;"]|\([^)]*\))*);?/g;
  // `var(--name)` or `var(--name,fallback)`; the fallback may itself hold one
  // level of parentheses (`var(--_fm)` inside a font list, for example).
  var VAR_REFERENCE = /var\(--([a-z0-9_-]+)(?:,((?:[^()]|\([^()]*\))*))?\)/g;
  // Every tag, with its attributes. Pele escapes `<` and `>` in attribute
  // values and text, so a tag never contains a `>` before its end.
  var TAG = /<[^>]*>/g;
  var STYLE_ATTRIBUTE = / style="([^"]*)"/g;
  var MAX_PASSES = 8;

  var ATTRIBUTE_ESCAPES = { '&': '&amp;', '<': '&lt;', '"': '&quot;' };
  function escapeAttribute(value) {
    return String(value).replace(/[&<"]/g, function (character) { return ATTRIBUTE_ESCAPES[character]; });
  }

  // Only tags are touched: diagram text such as a label reading `var(--x)`
  // or `a;;b` is left exactly as Pele wrote it.
  function resolveVariables(svg, theme) {
    var aliases = {};
    var stripped = svg.replace(TAG, function (tag) {
      return tag.indexOf('--_') < 0 ? tag : tag.replace(ALIAS_DECLARATION, function (match, name, value) {
        aliases[name] = value;
        return '';
      });
    });

    function lookup(name, fallback) {
      var value;
      if (name.charAt(0) === '_') {
        value = aliases[name.slice(1)];
      } else if (name.indexOf('pele-') === 0) {
        value = theme[name.slice(5)];
        if (value !== undefined && value !== null && value !== '') { return escapeAttribute(value); }
      }
      if (value !== undefined && value !== null && value !== '') { return String(value); }
      return fallback !== undefined ? fallback.trim() : '';
    }

    return stripped.replace(TAG, function (tag) {
      if (tag.indexOf('var(') < 0) { return tag; }
      var out = tag;
      var previous;
      var passes = 0;
      do {
        previous = out;
        out = out.replace(VAR_REFERENCE, function (match, name, fallback) {
          return lookup(name, fallback);
        });
        passes += 1;
      } while (out !== previous && passes < MAX_PASSES);
      // Removing declarations can leave empty slots in the style attribute.
      return out.replace(STYLE_ATTRIBUTE, function (match, css) {
        return ' style="' + css.replace(/;;+/g, ';').replace(/^;/, '').replace(/;$/, '') + '"';
      });
    });
  }

  // Entry point called from Swift.
  //
  //   options.fontSize        label font size in CSS pixels (points on Apple
  //                           platforms)
  //   options.fontFamily      family labels are measured in, and drawn in
  //                           unless the theme sets `font`
  //   options.fontFamilyMono  the same for code spans
  //   options.maxWidth        width available to the diagram; types that can
  //                           draw narrower do, and wide flowcharts may turn
  //                           vertical
  //   options.theme           values for Pele's `--pele-*` variables, keyed
  //                           without the prefix (`bg`, `fg`, `series-1`, ...)
  //
  // When the host installs `global.peleMeasureText(text, size, style,
  // family, monoFamily)`, labels are measured with it instead of Pele's
  // built-in Arial metrics. `style` is Pele's bit set: 1 bold, 2 italic,
  // 4 monospace, 8 subscript, 16 superscript, 32 underline.
  //
  // Returns `{ok:true, svg, width, height, type}` or
  // `{ok:false, code, message}`; it never throws.
  function renderDiagram(source, options) {
    options = options || {};
    try {
      var renderOptions = { responsive: false };
      if (typeof options.idPrefix === 'string' && /^[\w-]+$/.test(options.idPrefix)) { renderOptions.idPrefix = options.idPrefix; }
      if (typeof options.fontSize === 'number' && options.fontSize > 0) { renderOptions.fontSize = options.fontSize; }
      if (typeof options.fontFamily === 'string' && options.fontFamily !== '') { renderOptions.fontFamily = options.fontFamily; }
      if (typeof options.fontFamilyMono === 'string' && options.fontFamilyMono !== '') { renderOptions.fontFamilyMono = options.fontFamilyMono; }
      if (typeof options.maxWidth === 'number' && options.maxWidth > 0) { renderOptions.maxWidth = options.maxWidth; }
      if (typeof global.peleMeasureText === 'function') {
        var family = renderOptions.fontFamily || 'sans-serif';
        var monoFamily = renderOptions.fontFamilyMono || 'monospace';
        renderOptions.measurer = {
          width: function (text, size, style) {
            return global.peleMeasureText(text, size, style, family, monoFamily);
          }
        };
      }
      var result = pele.render(String(source), renderOptions);
      var theme = Object.assign({}, options.theme || {},
        (options.diagramThemeOverrides || {})[result.type] || {});
      return {
        ok: true,
        svg: resolveVariables(result.svg, theme),
        width: result.width,
        height: result.height,
        type: result.type
      };
    } catch (error) {
      return {
        ok: false,
        code: (error && typeof error.code === 'string') ? error.code : 'error',
        message: String(error && error.message ? error.message : error)
      };
    }
  }

  global.renderDiagram = renderDiagram;
  global.resolvePeleVariables = resolveVariables;
})(this);
