const { mathjax } = require('mathjax-full/js/mathjax.js');
const { TeX } = require('mathjax-full/js/input/tex.js');
const { SVG } = require('mathjax-full/js/output/svg.js');
const { liteAdaptor } = require('mathjax-full/js/adaptors/liteAdaptor.js');
const { RegisterHTMLHandler } = require('mathjax-full/js/handlers/html.js');
require('mathjax-full/js/input/tex/ams/AmsConfiguration.js');
require('mathjax-full/js/input/tex/mhchem/MhchemConfiguration.js');

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
const document = mathjax.document('', {
  InputJax: new TeX({
    packages: ['base', 'ams', 'mhchem'],
    maxBuffer: 8000,
    maxMacros: 1500,
    formatError: (_jax, error) => { throw error; },
  }),
  OutputJax: new SVG({ fontCache: 'none' }),
});

globalThis.quelytFormula = (latex, display) => {
  const container = document.convert(latex, { display, em: 16, ex: 8 });
  const svg = adaptor.firstChild(container);
  if (!svg || adaptor.kind(svg) !== 'svg') throw new Error('Empty formula');
  const width = Number.parseFloat(adaptor.getAttribute(svg, 'width'));
  const height = Number.parseFloat(adaptor.getAttribute(svg, 'height'));
  const style = adaptor.getAttribute(svg, 'style') || '';
  const depth = -(Number.parseFloat(/vertical-align:\s*([^;]+)/.exec(style)?.[1]) || 0);
  adaptor.setAttribute(svg, 'width', String(width * 8));
  adaptor.setAttribute(svg, 'height', String(height * 8));
  adaptor.removeAttribute(svg, 'style');
  return JSON.stringify({svg: adaptor.outerHTML(svg), width, height, depth});
};
