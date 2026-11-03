import {test} from 'node:test';
import assert from 'node:assert/strict';
import {decodePhoto,validPhotoPath,readBoundedBody,MAX_PHOTO_BYTES} from '../supabase/functions/_shared/product_photos.ts';

test('image upload verifies size and declared MIME against actual headers',()=>{
 const png=Buffer.from([137,80,78,71,13,10,26,10]);
 assert.equal(decodePhoto('image/png',png.toString('base64')).extension,'png');
 assert.equal(decodePhoto('image/jpeg',Buffer.from([255,216,255]).toString('base64')).extension,'jpg');
 assert.equal(decodePhoto('image/webp',Buffer.from('RIFF0000WEBP').toString('base64')).extension,'webp');
 assert.throws(()=>decodePhoto('__proto__',Buffer.from('RIFF0000WEBP').toString('base64')),/INVALID_PHOTO_TYPE/);
 for(const [mime,data] of [['image/svg+xml',png.toString('base64')],['image/jpeg',png.toString('base64')],['image/png','<script>'],['image/png',Buffer.from('fake').toString('base64')]])assert.throws(()=>decodePhoto(mime,data),/INVALID_PHOTO_TYPE/);
 assert.throws(()=>decodePhoto('image/png',Buffer.alloc(MAX_PHOTO_BYTES+1).toString('base64')),/PHOTO_TOO_LARGE/);
});
test('signed image references stay in their authenticated organization',()=>{
 const org='00000000-0000-4000-8000-000000000001',file='00000000-0000-4000-8000-000000000002';
 assert.ok(validPhotoPath(org,`${org}/${file}.jpg`));
 for(const path of [`${file}/${file}.jpg`,`${org}/../${file}.jpg`,`https://example.com/${file}.png`,`${org}/${file}.svg`,null])assert.equal(validPhotoPath(org,path),false);
});
test('stream size is bounded with and without Content-Length',async()=>{
 assert.equal(await readBoundedBody(new Request('https://example.com',{method:'POST',body:'okay'}),4),'okay');
 await assert.rejects(readBoundedBody(new Request('https://example.com',{method:'POST',body:'oversized'}),4),/REQUEST_TOO_LARGE/);
 await assert.rejects(readBoundedBody(new Request('https://example.com',{method:'POST',body:'x',headers:{'content-length':'100'}}),4),/REQUEST_TOO_LARGE/);
});
