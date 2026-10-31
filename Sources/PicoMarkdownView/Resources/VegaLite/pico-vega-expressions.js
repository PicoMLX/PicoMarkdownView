/* Bounded user expressions, parsed by the bundled official Vega parser. */
(function (global) {
  'use strict';
  const forbiddenProperties = new Set(['__proto__', 'constructor', 'prototype']);
  const constants = new Set(['datum', 'PI', 'E', 'LN2', 'LN10', 'LOG2E', 'LOG10E', 'SQRT1_2', 'SQRT2', 'undefined', 'NaN']);
  const functions = new Set([
    'if', 'isValid', 'isFinite', 'isNaN', 'isNumber', 'isString', 'isBoolean', 'isDate', 'isArray',
    'toNumber', 'toString', 'toBoolean', 'toDate',
    'abs', 'acos', 'asin', 'atan', 'atan2', 'ceil', 'clamp', 'cos', 'exp', 'floor',
    'hypot', 'log', 'max', 'min', 'pow', 'round', 'sin', 'sqrt', 'tan',
    'datetime', 'utc', 'year', 'quarter', 'month', 'date', 'day', 'hours', 'minutes', 'seconds',
    'milliseconds', 'time', 'utcyear', 'utcquarter', 'utcmonth', 'utcdate', 'utcday',
    'utchours', 'utcminutes', 'utcseconds', 'utcmilliseconds',
    'length', 'lower', 'upper', 'trim', 'substring', 'slice', 'indexof', 'lastindexof'
  ]);
  const unary = new Set(['+', '-', '!']);
  const binary = new Set(['+', '-', '*', '/', '%', '**', '==', '!=', '===', '!==', '<', '<=', '>', '>=']);
  function expression(source) {
    if (typeof source !== 'string' || !source.length || source.length > 8192) return false;
    let nodes = 0;
    function property(node) {
      if (node.computed) {
        if (node.property.type !== 'Literal') return false;
        const key = node.property.value;
        return typeof key === 'string' ? key.length <= 256 && !forbiddenProperties.has(key) :
          Number.isInteger(key) && key >= 0 && key < 4096;
      }
      return node.property.type === 'Identifier' && !forbiddenProperties.has(node.property.name);
    }
    function member(node, depth) {
      if (++nodes > 256 || depth > 24) return false;
      if (node.type === 'Identifier') return node.name === 'datum';
      return node.type === 'MemberExpression' && property(node) && member(node.object, depth + 1);
    }
    function visit(node, depth) {
      if (!node || ++nodes > 256 || depth > 24) return false;
      switch (node.type) {
        case 'Literal':
          return !node.regex && (node.value === null || typeof node.value === 'boolean' ||
            (typeof node.value === 'number' && Number.isFinite(node.value) && Math.abs(node.value) <= 1e12) ||
            (typeof node.value === 'string' && node.value.length <= 8192));
        case 'Identifier': return constants.has(node.name);
        case 'MemberExpression': return property(node) && member(node.object, depth + 1);
        case 'UnaryExpression': return unary.has(node.operator) && visit(node.argument, depth + 1);
        case 'BinaryExpression': return binary.has(node.operator) && visit(node.left, depth + 1) && visit(node.right, depth + 1);
        case 'LogicalExpression': return (node.operator === '&&' || node.operator === '||') && visit(node.left, depth + 1) && visit(node.right, depth + 1);
        case 'ConditionalExpression': return visit(node.test, depth + 1) && visit(node.consequent, depth + 1) && visit(node.alternate, depth + 1);
        case 'CallExpression': return node.callee.type === 'Identifier' && functions.has(node.callee.name) &&
          node.arguments.length <= 16 && node.arguments.every(function (arg) { return visit(arg, depth + 1); });
        default: return false;
      }
    }
    try { return visit(vega.parseExpression(source), 0); } catch (_) { return false; }
  }
  function walk(spec, prepare) {
    let nodes = 0;
    function predicate(value, depth) {
      if (typeof value === 'string') {
        if (!expression(value)) throw new Error('Unsupported expression');
        return prepare ? 'picoBoundedExpression((' + value + '))' : value;
      }
      if (!value || typeof value !== 'object' || Array.isArray(value) || depth > 32) throw new Error('Invalid predicate');
      for (const key of ['and', 'or']) {
        if (value[key] != null) {
          if (!Array.isArray(value[key])) throw new Error('Invalid predicate');
          value[key] = value[key].map(function (child) { return predicate(child, depth + 1); });
        }
      }
      if (value.not != null) value.not = predicate(value.not, depth + 1);
      return value;
    }
    function visit(value, depth) {
      if (++nodes > 400000 || depth > 32) throw new Error('Specification limit');
      if (!value || typeof value !== 'object') return;
      if (Array.isArray(value)) { value.forEach(function (child) { visit(child, depth + 1); }); return; }
      for (const key of Object.keys(value)) {
        // Data columns named calculate, filter or test are ordinary JSON data.
        if (key === 'values' || key === 'datasets') continue;
        if (key === 'calculate') {
          if (!expression(value[key])) throw new Error('Unsupported expression');
          if (prepare) value[key] = 'picoBoundedExpression((' + value[key] + '))';
        } else if (key === 'filter' || key === 'test') value[key] = predicate(value[key], depth + 1);
        else visit(value[key], depth + 1);
      }
    }
    visit(spec, 0);
    return spec;
  }
  let stringBudget = 0;
  let rejected = false;
  vega.expressionFunction('picoBoundedExpression', function (value) {
    if (typeof value === 'string') {
      stringBudget += value.length;
      if (value.length > 8192 || stringBudget > 8388608) { rejected = true; throw new Error('Expression result limit'); }
    } else if (typeof value === 'function' || typeof value === 'symbol' ||
               (value != null && typeof value === 'object' && !(value instanceof Date))) {
      rejected = true;
      throw new Error('Expression result must be scalar');
    }
    return value;
  });
  global.picoVegaExpressionsRejected = function () { return rejected; };
  global.picoValidateVegaLiteExpressions = function (source) {
    try { walk(JSON.parse(source), false); return true; } catch (_) { return false; }
  };
  global.picoPrepareVegaLiteExpressions = function (spec) {
    stringBudget = 0;
    rejected = false;
    return walk(spec, true);
  };
})(globalThis);
