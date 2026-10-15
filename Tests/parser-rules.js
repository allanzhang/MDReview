#!/usr/bin/env node
'use strict';

const assert = require('assert');
const { loadRenderer } = require('./lib/load-renderer');
const md = loadRenderer();

assert.strictEqual(md.renderInline('[$x](url)$'), '<a href="url">$x</a>$');
for (const source of ['^[H~2~O]', '^[a $x^2$ b]', '^A**"x"**B^']) {
  assert.doesNotThrow(() => md.render(source), source);
}
assert.ok(md.render('^[H~2~O]').includes('H<sub>2</sub>O'));
const note = md.render('^[x^2^]');
assert.ok(note.includes('footnote-ref'));
assert.ok(note.includes('x<sup>2</sup>'));
const formula = md.renderInline('$x\\$y$');
assert.ok(formula.includes('class="katex"'));
assert.ok(!formula.includes('katex-error'));
assert.ok(formula.includes('x\\$y</annotation>'));
assert.strictEqual(md.renderInline('~~12~3~~'), '<s>12~3</s>');
assert.strictEqual(md.renderInline('H~2~O'), 'H<sub>2</sub>O');
assert.strictEqual(md.renderInline('~文字~'), '~文字~');
assert.strictEqual(md.renderInline('a**! [x](https://example.com/**) **'), 'a**! <a href="https://example.com/**">x</a> **');
assert.strictEqual(md.renderInline('a**! *b** c*'), 'a**! <em>b</em>* c*');
assert.strictEqual(md.renderInline('1.2...1.4 1--2 (c)'), '1.2...1.4 1--2 (c)');
assert.strictEqual(md.render('a\nb'), '<p>a\nb</p>\n');
assert.ok(md.render('a  \nb').includes('<br>'));
for (const source of ['- \\[x] literal', '- &#91;x] literal', '- `[x]` literal']) {
  assert.ok(!md.render(source).includes('type="checkbox"'), source);
}
for (const source of ['- [x] first\n\n  second', '- [ ] task', '- [X] task', '- [x]', '- outer\n  - [x] inner']) {
  assert.ok(md.render(source).includes('type="checkbox"'), source);
}
assert.ok(!md.render('- [x]word').includes('type="checkbox"'));
assert.ok(!md.render('```\n- [x] example\n```').includes('type="checkbox"'));

for (const source of [
  '````\n```\n# fake\n````\n# real',
  '~~~\n# fake\n~~~\n# real',
  '<div>\n# fake\n</div>\n\n# real',
  'Title\n=====\n# Next',
  '# A\nTitle\n=====\n# B',
  '   # indented\n#\n# Next',
  '> # quoted\n\n# Next',
  '- # listed\n\n# Next',
  '# A\n[ref][target]\n\n# B\n\n[target]: https://example.com',
  '# A\nnote[^n]\n\n# B\n\n[^n]: text with H~2~O'
]) {
  const doc = md.prepareDocument(source);
  const full = md.renderer.render(doc.tokens, md.options, doc.env);
  const chunked = doc.sections.map(section => md.renderer.render(section.tokens, md.options, doc.env)).join('');
  assert.strictEqual(chunked, full, source);
  assert.strictEqual(new Set(doc.outline.map(h => h.id)).size, doc.outline.length);
  for (const h of doc.outline) assert.ok(full.includes(`id="${h.id}"`), source);
}
assert.deepStrictEqual(Array.from(md.prepareDocument('Title\n=====\n# Next').outline, h => h.text), ['Title', 'Next']);
assert.deepStrictEqual(Array.from(md.prepareDocument('~~~\n# fake\n~~~\n# real').outline, h => h.text), ['real']);
assert.deepStrictEqual(Array.from(md.prepareDocument('# Title ###\n# foo_bar and `a_b`\n# [label](https://example.com/a(b))').outline, h => h.text), ['Title', 'foo_bar and a_b', 'label']);
assert.deepStrictEqual(Array.from(md.prepareDocument('# $x^2$\n\n# Before $x$ after').outline, h => h.text), ['x^2', 'Before x after']);
const nested = md.prepareDocument('> # quoted\n\n# Next');
assert.strictEqual(nested.sections[0].startSeq, 0);
const long = md.prepareDocument('# A\n' + 'paragraph\n\n'.repeat(23000) + '# B\nend');
assert.ok(long.sections.length >= 2);
assert.strictEqual(long.sections.map(s => md.renderer.render(s.tokens, md.options, long.env)).join(''), md.renderer.render(long.tokens, md.options, long.env));
console.log('ok - parser boundaries, task lists, document outline and chunk parity');
