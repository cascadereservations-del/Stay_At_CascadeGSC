import { assertEquals } from 'jsr:@std/assert@1';
import { matchLine, score, tokens, type Candidate } from './match.ts';

const items: Candidate[] = [
  { item_id: 'tissue', names: ['Toilet Tissue 2-ply', 'Tissue 12 rolls'] },
  { item_id: 'water500', names: ["Nature's Spring Water 500ml"] },
  { item_id: 'water1l', names: ["Nature's Spring Water 1L"] },
  { item_id: 'soap', names: ['Safeguard Soap White 135g'] },
  { item_id: 'trash', names: ['Garbage Bags Large'] },
];

Deno.test('tokens split letters from digits and drop noise', () => {
  assertEquals(tokens('TISSUE 2PLY 12S'), ['tissue', '2', 'ply', '12']);
  assertEquals(tokens("NATURE'S SPRING 500ML"), ['natures', 'spring', '500', 'ml']);
});

Deno.test('Tagalog/English till lines find their item', () => {
  assertEquals(matchLine('TISSUE 2PLY 12S', items).item_id, 'tissue');
  assertEquals(matchLine('NATURES SPRING 500ML', items).item_id, 'water500');
  assertEquals(matchLine('SAFEGUARD WHT 135G', items).item_id, 'soap');
  assertEquals(matchLine('GARBAGE BAG LRG', items).item_id, 'trash');
});

Deno.test('an unrelated line, or an empty list, matches nothing', () => {
  assertEquals(matchLine('LUCKY ME PANCIT CANTON', items).item_id, null);
  assertEquals(matchLine('TISSUE', []).item_id, null);
  assertEquals(matchLine('', items).item_id, null);
});

Deno.test('a different size is not the same item', () => {
  assertEquals(matchLine('NATURES SPRING 1L', items).item_id, 'water1l');
  assert(score('NATURES SPRING 1L', "Nature's Spring Water 500ml") < score('NATURES SPRING 1L', "Nature's Spring Water 1L"));
});

Deno.test('an option name can carry the match', () => {
  assertEquals(matchLine('KLEENEX FACIAL', [{ item_id: 'f', names: ['Facial Tissue', 'Kleenex Facial'] }]).item_id, 'f');
});

function assert(c: boolean) { if (!c) throw new Error('assertion failed'); }
