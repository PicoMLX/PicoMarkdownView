/* Native static Vega-Lite host. Inputs are prevalidated JSON, never JavaScript. */
(function (global) {
  'use strict';
  const blocked = function () { return Promise.reject(new Error('External resources are disabled')); };
  const loader = {load: blocked, sanitize: blocked, http: blocked, file: blocked};
  vega.textMetrics.width = function (item, text) {
    const value = text == null ? (item.text == null ? '' : item.text) : text;
    return picoVegaMeasureText(String(value).trim(), +(item.fontSize == null ? 11 : item.fontSize),
      String(item.font || 'sans-serif'), String(item.fontWeight || 'normal'), String(item.fontStyle || 'normal'));
  };
  // The official interpreter owns all compiler-generated expressions.
  // Guard against accidentally regressing to runtime source compilation.
  global.Function = function () { throw new Error('Dynamic code generation is disabled'); };
  global.eval = function () { throw new Error('Dynamic code generation is disabled'); };
  // These resolved parameters are checked before Vega allocates bin arrays
  // or interpolated color schemes. In particular, signal-derived bin bounds
  // cannot be bounded from the compiled JSON alone. The registry and its
  // implementation are pinned by the bundled Vega version.
  let allocationRejected = false;
  const scalePrototype = vega.transforms.scale.prototype;
  const scaleTransform = scalePrototype.transform;
  scalePrototype.transform = function (params, pulse) {
    const bins = params.bins;
    let safe = params.schemeCount == null ||
      (Number.isFinite(+params.schemeCount) && +params.schemeCount > 0 && +params.schemeCount <= 256);
    if (bins) {
      if (Array.isArray(bins)) safe = safe && bins.length <= 258;
      else {
        const domain = params.domain || [];
        const start = bins.start == null ? domain[0] : bins.start;
        const stop = bins.stop == null ? domain[domain.length - 1] : bins.stop;
        const step = bins.step;
        safe = safe && [start, stop, step].every(Number.isFinite) && step > 0 &&
          Math.abs((stop - start) / step) <= 257;
      }
    }
    if (!safe) { allocationRejected = true; throw new Error('Scale allocation limit'); }
    return scaleTransform.call(this, params, pulse);
  };
  global.picoRenderVegaLite = function (source, options) {
    const result = {status: 'pending'};
    allocationRejected = false;
    let view;
    try {
      const spec = picoPrepareVegaLiteExpressions(JSON.parse(source));
      function sizes(node) {
        if (!node || typeof node !== 'object') return;
        if (Array.isArray(node)) { node.forEach(sizes); return; }
        if (node.width === 'container') node.width = options.width || 480;
        if (node.height === 'container') node.height = 300;
        Object.keys(node).forEach(function (key) { if (key !== 'values' && key !== 'datasets') sizes(node[key]); });
      }
      sizes(spec);
      if (options.width && !spec.facet && !spec.repeat && !spec.hconcat && !spec.vconcat && !spec.concat) {
        spec.width = Math.min(typeof spec.width === 'number' ? spec.width : options.width, options.width);
        spec.autosize = {type: 'fit', contains: 'padding', resize: false};
      }
      const fontSize = Math.max(1, Math.min(256, options.fontSize || 14));
      const config = {
        background: 'transparent', font: 'sans-serif',
        view: {continuousWidth: 480, continuousHeight: 300, stroke: options.grid},
        axis: {labelFontSize: fontSize * 0.85, titleFontSize: fontSize, labelColor: options.foreground, titleColor: options.foreground, gridColor: options.grid,
               domainColor: options.grid, tickColor: options.grid},
        legend: {labelFontSize: fontSize * 0.85, titleFontSize: fontSize, labelColor: options.foreground, titleColor: options.foreground},
        mark: {color: options.markColor || '#2a78d6'},
        title: {fontSize: fontSize * 1.1, color: options.foreground}, text: {fontSize: fontSize, color: options.foreground}
      };
      const compiled = vegaLite.compile(spec, {config: config}).spec;
      const runtime = vega.parse(compiled, null, {ast: true});
      vega.resetSVGDefIds();
      view = new vega.View(runtime, {renderer: 'none', expr: vega.expressionInterpreter, loader: loader});
      view.toSVG().then(function (svg) {
        if (allocationRejected || picoVegaExpressionsRejected()) result.status = 'failed';
        else { result.svg = svg; result.status = 'done'; }
        view.finalize();
      }, function () {
        result.status = 'failed';
        view.finalize();
      });
    } catch (_) {
      result.status = 'failed';
      if (view) view.finalize();
    }
    return result;
  };
})(globalThis);
