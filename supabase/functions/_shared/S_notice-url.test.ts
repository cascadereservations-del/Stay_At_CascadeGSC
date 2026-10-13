import { assertEquals } from 'jsr:@std/assert@1';
import { S_noticeUrl } from './S_notice-url.ts';

Deno.test('a Facebook share link is kept without tracking ids', () => {
  assertEquals(S_noticeUrl('https://www.facebook.com/share/p/1AbCdEf/?mibextid=wwXIfr&fbclid=XYZ'), 'https://www.facebook.com/share/p/1AbCdEf/');
});
Deno.test('a story link keeps only the two ids it needs', () => {
  assertEquals(S_noticeUrl('https://m.facebook.com/story.php?story_fbid=123&id=456&mibextid=x&ref=a@b.com'), 'https://m.facebook.com/story.php?story_fbid=123&id=456');
});
Deno.test('the first link in a message is the one used', () => {
  assertEquals(S_noticeUrl('water notice: Oct 16 8am to 5pm https://fb.watch/abc123/ and https://example.com/x'), 'https://fb.watch/abc123/');
});
Deno.test('a bare facebook.com link with no scheme gets https', () => {
  assertEquals(S_noticeUrl('facebook.com/gscwaterdistrict/posts/99'), 'https://facebook.com/gscwaterdistrict/posts/99');
});
Deno.test('credentials, other schemes and plain text give null', () => {
  assertEquals(S_noticeUrl('https://user:pw@facebook.com/x'), null);
  assertEquals(S_noticeUrl('javascript:alert(1)'), null);
  assertEquals(S_noticeUrl('ftp://facebook.com/x'), null);
  assertEquals(S_noticeUrl('call me on 0917 123 4567'), null);
  assertEquals(S_noticeUrl(null), null);
});
Deno.test('an over-long link gives null', () => {
  assertEquals(S_noticeUrl('https://www.facebook.com/' + 'a'.repeat(600)), null);
});
