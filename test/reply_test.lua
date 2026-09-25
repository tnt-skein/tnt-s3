--- Чтение ответов S3: элементы XML, сведения об объекте, страница списка
--- и слова отказа.
---
--- Тела ответов — такие, какие пишут AWS и MinIO: с заголовком XML,
--- пространством имён у корня, `ETag` в `&quot;` и пустым `<Prefix/>`.

local t = require('luatest')
local utf8 = require('utf8')

local helper = dofile('test/helper.lua')

local g, world = helper.group('tnt.s3.reply')

--- Страница списка, как её отдаёт MinIO на `delimiter = '/'`.
local PAGE = [[<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>tnt-live</Name><Prefix/><KeyCount>3</KeyCount>
<MaxKeys>2</MaxKeys><Delimiter>/</Delimiter><IsTruncated>true</IsTruncated>
<NextContinuationToken>1ZfXk/+Q==</NextContinuationToken>
<Contents><Key>a &amp; b &lt;1&gt;.txt</Key><LastModified>2026-09-19T20:10:58.087Z</LastModified>
<ETag>&quot;608333adc72f545078ede3aad71bfe74&quot;</ETag><Size>12</Size><StorageClass>STANDARD</StorageClass></Contents>
<Contents><Key>&#1078;&#x436;</Key><LastModified>not a date</LastModified><ETag>bare</ETag><Size>0</Size></Contents>
<CommonPrefixes><Prefix>logs/</Prefix></CommonPrefixes><CommonPrefixes><Prefix>проба/</Prefix></CommonPrefixes>
</ListBucketResult>]]

g.test_text_decodes_entities = function()
    t.assert_equals(world.xml.decode('a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;'), 'a & b <c> "d" \'e\'')
    t.assert_equals(world.xml.decode('&#1078;&#x436;&#X436;&#65;'), 'жжжA')
    -- Незнакомое и негодное остаётся как было: разбор не отказывает.
    t.assert_equals(world.xml.decode('&nbsp; &#x110000; &#1a;'), '&nbsp; &#x110000; &#1a;')
    t.assert_equals(world.xml.decode('&#x10FFFF;'), utf8.char(0x10FFFF))
    t.assert_equals(world.xml.decode('&#1;&#x1;'), '\1\1')
    t.assert_equals(world.xml.decode('&#0; &#-1; &#x-1; &#x; &#; &; &AMP;'), '&#0; &#-1; &#x-1; &#x; &#; &; &AMP;')
    -- Голый `&` перед сущностью её не прячет.
    t.assert_equals(world.xml.decode('a & b &lt;'), 'a & b <')
end

g.test_text_reads_first_element = function()
    t.assert_equals(world.xml.text('<a><B>x</B><B>y</B></a>', 'B'), 'x')
    t.assert_equals(world.xml.text('<B></B>', 'B'), '')
    t.assert_equals(world.xml.text('<B/>', 'B'), '')
    t.assert_equals(world.xml.text('<Bx>1</Bx>', 'B'), nil)
    t.assert_equals(world.xml.text('<B-/>', 'B'), nil)
    t.assert_equals(world.xml.text('', 'B'), nil)
end

g.test_blocks_keep_order = function()
    t.assert_equals(world.xml.blocks('<r><C>1</C><D>x</D><C>2</C></r>', 'C'), { '1', '2' })
    t.assert_equals(world.xml.blocks('<r/>', 'C'), {})
end

g.test_page_reads_items_prefixes_and_next = function()
    local page = world.reply.page(PAGE)

    t.assert_equals(page.prefixes, { 'logs/', 'проба/' })
    t.assert_equals(page.next, '1ZfXk/+Q==')
    t.assert_equals(#page.items, 2)
    t.assert_equals(page.items[1].key, 'a & b <1>.txt')
    t.assert_equals(page.items[1].size, 12)
    t.assert_equals(page.items[1].etag, '608333adc72f545078ede3aad71bfe74')
    t.assert_equals(tostring(page.items[1].modified), '2026-09-19T20:10:58.087Z')
    t.assert_equals(page.items[2], { key = 'жж', size = 0, etag = 'bare' })
end

g.test_page_without_truncation_has_no_next = function()
    -- MinIO пишет метку продолжения и на последней странице.
    local page = world.reply.page(PAGE:gsub('<IsTruncated>true', '<IsTruncated>false'))

    t.assert_equals(page.next, nil)
    t.assert_equals(world.reply.page('<ListBucketResult/>'), { items = {}, prefixes = {} })
end

g.test_info_reads_headers = function()
    local info = world.reply.info({
        ['content-length'] = '12',
        ['content-type'] = 'text/plain',
        etag = '"608333adc72f545078ede3aad71bfe74"',
        ['last-modified'] = 'Sat, 19 Sep 2026 20:10:58 GMT',
        ['x-amz-version-id'] = 'v7',
        ['x-amz-meta-author'] = 'Anna',
        ['x-amz-meta-'] = 'пусто',
        ['x-amz-request-id'] = '1863',
    })

    t.assert_equals(tostring(info.modified), '2026-09-19T20:10:58Z')
    info.modified = nil
    t.assert_equals(info, {
        size = 12,
        type = 'text/plain',
        etag = '608333adc72f545078ede3aad71bfe74',
        version = 'v7',
        metadata = { author = 'Anna' },
    })
end

g.test_info_prefers_body_size_and_tolerates_gaps = function()
    t.assert_equals(world.reply.info({ ['content-length'] = '12', etag = 'W/"x"' }, 5), {
        size = 5,
        etag = 'W/"x"',
        metadata = {},
    })
    t.assert_equals(world.reply.info({ ['last-modified'] = 'yesterday' }), { metadata = {} })
    -- Кавычки снимаются только парой по краям.
    t.assert_equals(world.reply.info({ etag = '""' }).etag, '')
    t.assert_equals(world.reply.info({ etag = '"' }).etag, '"')
    t.assert_equals(world.reply.info({ etag = '"a' }).etag, '"a')
    t.assert_equals(world.reply.info({ etag = 'a"' }).etag, 'a"')
end

g.test_fault_reads_code_and_message = function()
    local answer = helper.fault(404, 'NoSuchKey', 'The specified key does not exist.')

    t.assert_equals({ world.reply.fault(answer.body) }, { 'NoSuchKey', 'The specified key does not exist.' })
    t.assert_equals({ world.reply.fault('<html>502 Bad Gateway</html>') }, { nil, nil })
    t.assert_equals({ world.reply.fault('') }, { nil, nil })
end
