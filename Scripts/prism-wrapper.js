// Appended verbatim to prism-bundle.js by Scripts/bundle-prism.sh.
// Bridges Prism's nested token tree to the flat {content, type, alias?}
// objects consumed by PrismTokenizer (JavaScriptCore) in
// Sources/PicoMarkdownView/Renderer/PrismCodeHighlighter.swift.

// Flatten Prism tokens into simple objects. Nested tokens inherit the
// enclosing token's type/alias; empty strings are dropped. `alias` (the
// first one, when Prism provides any) carries standardized semantics for
// grammar-specific types — e.g. INI `key` aliases `attr-name` — letting
// themes color languages they never heard of.
function flattenPrismTokens(tokens) {
  var result = [];

  function firstAlias(alias) {
    if (!alias) { return undefined; }
    if (Array.isArray(alias)) { return alias.length > 0 ? String(alias[0]) : undefined; }
    return String(alias);
  }

  function push(content, type, alias) {
    if (content.length === 0) { return; }
    var token = { content: content, type: type || 'plain' };
    if (alias) { token.alias = alias; }
    result.push(token);
  }

  function flatten(token, parentType, parentAlias) {
    if (typeof token === 'string') {
      push(token, parentType, parentAlias);
    } else if (Array.isArray(token)) {
      token.forEach(function (t) { flatten(t, parentType, parentAlias); });
    } else if (token && typeof token === 'object') {
      var type = token.type || parentType || 'plain';
      var alias = firstAlias(token.alias) || parentAlias;
      if (typeof token.content === 'string') {
        push(token.content, type, alias);
      } else if (Array.isArray(token.content)) {
        token.content.forEach(function (t) { flatten(t, type, alias); });
      } else if (token.content && typeof token.content === 'object') {
        flatten(token.content, type, alias);
      }
    }
  }

  tokens.forEach(function (token) { flatten(token, null, undefined); });
  return result;
}

// Entry point called from Swift. Full language-alias normalization
// (c++ -> cpp, golang -> go, ...) lives in PrismLanguageNormalizer.swift;
// the lowercasing/first-word here is belt-and-braces for direct callers.
function tokenizeCode(code, language) {
  try {
    var name = String(language || '').trim().split(/\s+/)[0].toLowerCase();
    var grammar = Prism.languages[name];
    if (!grammar) {
      return [{ content: code, type: 'plain' }];
    }
    var tokens = Prism.tokenize(code, grammar);
    return flattenPrismTokens(tokens);
  } catch (e) {
    return [{ content: code, type: 'plain' }];
  }
}
