--- Копия на сервере, чтение кусками по диапазону, загрузка частями
--- и файлы через них — на двойнике libcurl.

local fio = require('fio')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local web = helper.web

local g, world = helper.group('tnt.s3.stream')

--- Ведро двойника на узле.
local BUCKET = 'http://127.0.0.1:9000/tnt-live'

--- Самая маленькая часть: 5 МБ.
local PART = 5 * 1024 * 1024

--- Ответ на начало загрузки частями.
---@param id string
---@return table
local function initiated(id)
    return web.answer(200, {
        body = '<?xml version="1.0" encoding="UTF-8"?>\n<InitiateMultipartUploadResult>'
            .. '<Bucket>tnt-live</Bucket><Key>k</Key><UploadId>'
            .. id
            .. '</UploadId></InitiateMultipartUploadResult>',
    })
end

--- Ответ с меткой содержимого в теле: копия и сборка частей.
---@param root string Корневой элемент
---@param etag string
---@param headers table|nil
---@return table
local function confirmed(root, etag, headers)
    return web.answer(200, {
        headers = headers or {},
        body = ('<?xml version="1.0" encoding="UTF-8"?>\n<%s><ETag>&quot;%s&quot;</ETag></%s>'):format(
            root,
            etag,
            root
        ),
    })
end

--- Отказ в теле ответа 200: так S3 кончает копию и сборку, которые
--- не удались после отправки заголовков.
---@return table
local function fault_in_200()
    local answer = helper.fault(200, 'InternalError', 'We encountered an internal error.')

    answer.status = 200

    return answer
end

--- Сведения объекта для открытия читателя.
---@param size integer
---@param etag string|nil
---@return table
local function object_head(size, etag)
    local headers = { ['Content-Length'] = tostring(size) }

    headers.ETag = etag and ('"%s"'):format(etag) or nil

    return web.answer(200, { headers = headers })
end

--- Все куски читателя до конца.
local drain = helper.drain

g.test_copy_is_done_by_the_service = function()
    local client, sent = helper.client({
        confirmed('CopyObjectResult', 'c0ffee', { ['x-amz-version-id'] = 'v2' }),
    })

    local stored, err = client:copy('отчёты/a b.csv', 'архив/a b.csv')

    t.assert_equals(err, nil)
    t.assert_equals(stored, { etag = 'c0ffee', version = 'v2' })
    t.assert_equals(sent[1].method, 'PUT')
    t.assert_equals(sent[1].url, BUCKET .. '/%D0%B0%D1%80%D1%85%D0%B8%D0%B2/a%20b.csv')
    t.assert_equals(sent[1].body, nil)
    t.assert_equals(
        sent[1].options.headers['x-amz-copy-source'],
        '/tnt-live/%D0%BE%D1%82%D1%87%D1%91%D1%82%D1%8B/a%20b.csv'
    )
    t.assert_str_contains(
        sent[1].options.headers.authorization,
        'SignedHeaders=host;x-amz-content-sha256;x-amz-copy-source;x-amz-date, Signature='
    )
end

g.test_copy_names_the_bucket_with_host_addressing = function()
    local client, sent = helper.client({ confirmed('CopyObjectResult', 'e') }, { addressing = 'host' })

    t.assert_equals(client:copy('a', 'b'), { etag = 'e' })
    t.assert_equals(sent[1].url, 'http://tnt-live.127.0.0.1:9000/b')
    t.assert_equals(sent[1].options.headers['x-amz-copy-source'], '/tnt-live/a')
end

g.test_copy_failed_inside_a_200_is_retried = function()
    web.instant_retries()

    local client, sent = helper.client({ fault_in_200(), confirmed('CopyObjectResult', 'e') })

    t.assert_equals(client:copy('a', 'b'), { etag = 'e' })
    t.assert_equals(#sent, 2)
end

g.test_copy_failed_inside_a_200_is_a_failure_without_consent = function()
    local client, sent = helper.client({ fault_in_200() })
    local stored, err = client:copy('a', 'b', { idempotent = false })

    t.assert_equals(stored, nil)
    t.assert_equals({ err.kind, err.server_code, err.message }, {
        'broken',
        'InternalError',
        'PUT 127.0.0.1:9000/tnt-live/b: 500 InternalError: We encountered an internal error.',
    })
    t.assert_equals(#sent, 1)
end

g.test_copy_of_a_missing_source_is_a_failure = function()
    local client = helper.client({ helper.fault(404, 'NoSuchKey', 'The specified key does not exist.') })
    local stored, err = client:copy('none', 'b')

    t.assert_equals(stored, nil)
    t.assert_equals({ err.kind, err.server_code }, { 'rejected', 'NoSuchKey' })
end

g.test_reader_asks_the_object_by_ranges_of_the_same_version = function()
    local client, sent = helper.client({
        object_head(10, 'e'),
        web.answer(206, { body = 'abcd' }),
        web.answer(206, { body = 'efgh' }),
        web.answer(206, { body = 'ij' }),
    })

    local reader = client:reader('k', { piece = 4 })

    t.assert_equals({ reader.key, reader.info.size, reader.info.etag }, { 'k', 10, 'e' })

    local chunks, err = drain(reader)

    t.assert_equals(chunks, { 'abcd', 'efgh', 'ij' })
    t.assert_equals(err, nil)
    t.assert_equals({ reader:read() }, {})
    t.assert_equals(sent[1].method, 'HEAD')

    local asked = {}

    for index = 2, 4 do
        table.insert(
            asked,
            { sent[index].method, sent[index].options.headers.range, sent[index].options.headers['if-match'] }
        )
    end

    t.assert_equals(asked, {
        { 'GET', 'bytes=0-3', '"e"' },
        { 'GET', 'bytes=4-7', '"e"' },
        { 'GET', 'bytes=8-9', '"e"' },
    })
    t.assert_equals(#sent, 4)
end

g.test_reader_of_an_empty_object_asks_nothing_more = function()
    local client, sent = helper.client({ object_head(0, 'e') })

    t.assert_equals({ client:reader('k'):read() }, {})
    t.assert_equals(#sent, 1)
end

g.test_reader_without_a_tag_asks_without_a_condition = function()
    local client, sent = helper.client({ object_head(1), web.answer(206, { body = 'x' }) })

    t.assert_equals(client:reader('k'):read(), 'x')
    t.assert_equals(sent[2].options.headers['if-match'], nil)
end

g.test_reader_piece_is_limited_by_the_answer_limit = function()
    local client, sent = helper.client({ object_head(5000, 'e'), web.answer(206, { body = ('x'):rep(1000) }) }, {
        max_bytes = 1000,
    })

    t.assert_equals(#client:reader('k'):read(), 1000)
    t.assert_equals(sent[2].options.headers.range, 'bytes=0-999')
end

g.test_reader_piece_is_8_megabytes_by_default = function()
    local client, sent = helper.client({ object_head(10 * 1024 * 1024, 'e'), web.answer(206, { body = 'x' }) })

    client:reader('k'):read()

    t.assert_equals(world.s3.PIECE, 8 * 1024 * 1024)
    t.assert_equals(sent[2].options.headers.range, 'bytes=0-8388607')
end

g.test_reader_of_a_missing_object_is_nil = function()
    local client, sent = helper.client({
        web.answer(404),
        helper.fault(404, 'NoSuchKey', 'The specified key does not exist.'),
    })

    t.assert_equals({ client:reader('k') }, {})
    t.assert_equals({ sent[2].method, sent[2].options.headers.range }, { 'GET', 'bytes=0-0' })
end

g.test_reader_of_a_missing_bucket_is_a_failure = function()
    local client = helper.client({
        web.answer(404),
        helper.fault(404, 'NoSuchBucket', 'The specified bucket does not exist'),
    })
    local reader, err = client:reader('k')

    t.assert_equals(reader, nil)
    t.assert_equals({ err.kind, err.server_code }, { 'rejected', 'NoSuchBucket' })
end

g.test_reader_refused_at_opening_is_a_failure = function()
    local client = helper.client({ helper.fault(403, 'AccessDenied', 'Access Denied.') })
    local reader, err = client:reader('k')

    t.assert_equals(reader, nil)
    t.assert_equals(err.kind, 'denied')
end

g.test_reader_needs_the_size = function()
    local client = helper.client({ web.answer(200, { headers = { ETag = '"e"' } }) })
    local reader, err = client:reader('k')

    t.assert_equals(reader, nil)
    t.assert_equals({ err.kind, err.retriable, err.message }, {
        'broken',
        false,
        'HEAD 127.0.0.1:9000/tnt-live/k: служба не назвала размер объекта',
    })
end

g.test_reader_refuses_a_piece_of_the_wrong_length = function()
    local client, sent = helper.client({ object_head(10, 'e'), web.answer(200, { body = 'abcdefghij' }) })
    local reader = client:reader('k', { piece = 4 })
    local chunk, err = reader:read()

    t.assert_equals(chunk, nil)
    t.assert_equals(
        { err.kind, err.retriable, err.message },
        { 'broken', false, 'GET 127.0.0.1:9000/tnt-live/k: вместо 4 байт с 0 пришло 10' }
    )
    t.assert_is(select(2, reader:read()), err)
    t.assert_equals(#sent, 2)
end

g.test_reader_of_a_replaced_object_is_a_conflict = function()
    local client = helper.client({
        object_head(8, 'e'),
        web.answer(206, { body = 'abcd' }),
        helper.fault(412, 'PreconditionFailed', 'At least one of the pre-conditions you specified did not hold'),
    })
    local reader = client:reader('k', { piece = 4 })

    t.assert_equals(reader:read(), 'abcd')

    local chunk, err = reader:read()

    t.assert_equals(chunk, nil)
    t.assert_equals({ err.kind, err.server_code }, { 'conflict', 'PreconditionFailed' })
end

g.test_reader_close_forbids_reading = function()
    local client = helper.client({ object_head(8, 'e') })
    local reader = client:reader('k')

    t.assert_equals(reader:close(), true)
    helper.assert_blamed({
        {
            function()
                reader:read()
            end,
            'read: читатель объекта k уже закрыт',
        },
    })
end

g.test_writer_under_a_part_puts_the_object_at_once = function()
    local client, sent = helper.client({ web.answer(200, { headers = { ETag = '"w"', ['x-amz-version-id'] = 'v1' } }) })
    local writer = client:writer('k', { content_type = 'text/csv', metadata = { author = 'anna' } })

    t.assert_equals({ writer:write('a;b\n') }, { true })
    t.assert_equals({ writer:write('1;2\n') }, { true })
    t.assert_equals(#sent, 0)
    t.assert_equals(writer:finish(), { etag = 'w', version = 'v1' })
    t.assert_equals({ sent[1].method, sent[1].url, sent[1].body }, { 'PUT', BUCKET .. '/k', 'a;b\n1;2\n' })
    t.assert_equals(sent[1].options.headers['content-type'], 'text/csv')
    t.assert_equals(sent[1].options.headers['x-amz-meta-author'], 'anna')
    t.assert_equals(writer.key, 'k')
end

g.test_writer_of_nothing_puts_an_empty_object = function()
    local client, sent = helper.client({ web.answer(200) })

    t.assert_equals(client:writer('k'):finish(), {})
    t.assert_equals(sent[1].body, '')
end

g.test_writer_sends_full_parts_and_assembles_them = function()
    local client, sent = helper.client({
        initiated('U1'),
        web.answer(200, { headers = { ETag = '"p1"' } }),
        web.answer(200, { headers = { ETag = '"p2"' } }),
        confirmed('CompleteMultipartUploadResult', 'whole-2', { ['x-amz-version-id'] = 'v7' }),
    })
    local writer = client:writer('k', { content_type = 'text/csv', part_size = PART })
    local half = ('x'):rep(PART / 2)

    t.assert_equals({ writer:write(half) }, { true })
    t.assert_equals(#sent, 0)
    t.assert_equals({ writer:write(half) }, { true })
    t.assert_equals(#sent, 2)
    t.assert_equals({ writer:write('хвост') }, { true })

    t.assert_equals(writer:finish(), { etag = 'whole-2', version = 'v7' })

    t.assert_equals({ sent[1].method, sent[1].url, sent[1].body }, { 'POST', BUCKET .. '/k?uploads=', nil })
    t.assert_equals(sent[1].options.headers['content-type'], 'text/csv')
    t.assert_equals({ sent[2].method, sent[2].url, #sent[2].body }, {
        'PUT',
        BUCKET .. '/k?partNumber=1&uploadId=U1',
        PART,
    })
    t.assert_equals(sent[2].options.headers['content-type'], nil)
    t.assert_equals({ sent[3].url, sent[3].body }, { BUCKET .. '/k?partNumber=2&uploadId=U1', 'хвост' })
    t.assert_equals({ sent[4].method, sent[4].url, sent[4].body }, {
        'POST',
        BUCKET .. '/k?uploadId=U1',
        '<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>"p1"</ETag></Part>'
            .. '<Part><PartNumber>2</PartNumber><ETag>"p2"</ETag></Part></CompleteMultipartUpload>',
    })
    t.assert_equals(sent[4].options.headers['content-type'], 'application/xml')
end

g.test_writer_ending_on_a_part_boundary_sends_no_empty_part = function()
    local client, sent = helper.client({
        initiated('U1'),
        web.answer(200, { headers = { ETag = '"p1"' } }),
        confirmed('CompleteMultipartUploadResult', 'whole-1'),
    })
    local writer = client:writer('k', { part_size = PART })

    writer:write(('x'):rep(PART))

    t.assert_equals(writer:finish(), { etag = 'whole-1' })
    t.assert_equals(#sent, 3)
    t.assert_equals(sent[3].method, 'POST')
end

g.test_writer_part_is_8_megabytes_by_default = function()
    local client, sent = helper.client({ web.answer(200) })
    local writer = client:writer('k')

    writer:write(('x'):rep(8 * 1024 * 1024 - 1))
    writer:finish()

    t.assert_equals(world.s3.PART_SIZE, 8 * 1024 * 1024)
    t.assert_equals(sent[1].method, 'PUT')
end

g.test_a_failed_part_cancels_the_upload = function()
    local client, sent = helper.client({
        initiated('U1'),
        helper.fault(403, 'AccessDenied', 'Access Denied.'),
        web.answer(204),
    })
    local writer = client:writer('k', { part_size = PART })
    local written, err = writer:write(('x'):rep(PART))

    t.assert_equals(written, nil)
    t.assert_equals(err.kind, 'denied')
    t.assert_equals({ sent[3].method, sent[3].url }, { 'DELETE', BUCKET .. '/k?uploadId=U1' })

    -- Дальше писатель отвечает тем же отказом и в сеть не ходит.
    t.assert_is(select(2, writer:write('y')), err)
    t.assert_is(select(2, writer:finish()), err)
    t.assert_equals(writer:abort(), true)
    t.assert_equals(#sent, 3)
end

g.test_a_failed_start_has_nothing_to_cancel = function()
    local client, sent = helper.client({ helper.fault(403, 'AccessDenied', 'Access Denied.') })
    local writer = client:writer('k', { part_size = PART })
    local written, err = writer:write(('x'):rep(PART))

    t.assert_equals({ written, err.kind }, { nil, 'denied' })
    t.assert_equals(#sent, 1)
end

g.test_a_start_without_an_upload_id_is_broken = function()
    local client, sent = helper.client({ web.answer(200, { body = '<InitiateMultipartUploadResult/>' }) })
    local writer = client:writer('k', { part_size = PART })
    local _, err = writer:write(('x'):rep(PART))

    t.assert_equals({ err.kind, err.retriable, err.message }, {
        'broken',
        false,
        'POST 127.0.0.1:9000/tnt-live/k: служба не назвала опознаватель загрузки',
    })
    t.assert_equals(#sent, 1)
end

g.test_assembly_is_never_repeated_after_sending = function()
    web.instant_retries()

    local client, sent = helper.client({
        initiated('U1'),
        web.answer(200, { headers = { ETag = '"p1"' } }),
        helper.fault(500, 'InternalError', 'We encountered an internal error.'),
        web.answer(204),
    })
    local writer = client:writer('k', { part_size = PART })

    writer:write(('x'):rep(PART))

    local stored, err = writer:finish()

    t.assert_equals({ stored, err.kind, err.retriable }, { nil, 'broken', false })
    t.assert_equals({ sent[4].method, sent[4].url }, { 'DELETE', BUCKET .. '/k?uploadId=U1' })
    t.assert_equals(#sent, 4)
end

g.test_assembly_failed_inside_a_200_is_a_failure = function()
    local client, sent = helper.client({
        initiated('U1'),
        web.answer(200, { headers = { ETag = '"p1"' } }),
        fault_in_200(),
        web.answer(204),
    })
    local writer = client:writer('k', { part_size = PART })

    writer:write(('x'):rep(PART))

    local stored, err = writer:finish()

    t.assert_equals({ stored, err.kind, err.server_code }, { nil, 'broken', 'InternalError' })
    t.assert_equals(#sent, 4)
end

g.test_the_last_part_failing_fails_the_finish = function()
    local client, sent = helper.client({
        initiated('U1'),
        web.answer(200, { headers = { ETag = '"p1"' } }),
        helper.fault(403, 'AccessDenied', 'Access Denied.'),
        web.answer(204),
    })
    local writer = client:writer('k', { part_size = PART })

    writer:write(('x'):rep(PART))
    writer:write('хвост')

    local stored, err = writer:finish()

    t.assert_equals({ stored, err.kind }, { nil, 'denied' })
    t.assert_equals(sent[4].method, 'DELETE')
end

g.test_a_part_without_a_tag_is_broken = function()
    local client, sent = helper.client({ initiated('U1'), web.answer(200), web.answer(204) })
    local writer = client:writer('k', { part_size = PART })
    local written, err = writer:write(('x'):rep(PART))

    t.assert_equals(written, nil)
    t.assert_equals(
        { err.kind, err.retriable, err.message },
        { 'broken', false, 'PUT 127.0.0.1:9000/tnt-live/k: служба не назвала метку части 1' }
    )
    t.assert_equals(sent[3].method, 'DELETE')
end

g.test_the_limits_of_parts_are_those_of_s3 = function()
    t.assert_equals(
        { world.upload.MAX_PARTS, world.upload.MIN_PART, world.upload.MAX_PART },
        { 10000, 5 * 1024 * 1024, 5 * 1024 * 1024 * 1024 }
    )
end

g.test_cancelling_is_repeated_after_a_broken_answer = function()
    web.instant_retries()

    local client, sent = helper.client({
        initiated('U1'),
        helper.fault(403, 'AccessDenied', 'Access Denied.'),
        helper.fault(500, 'InternalError', 'We encountered an internal error.'),
        web.answer(204),
    })
    local writer = client:writer('k', { part_size = PART })
    local written, err = writer:write(('x'):rep(PART))

    t.assert_equals({ written, err.kind }, { nil, 'denied' })
    -- Снятие — DELETE: его повтор безвреден, и загрузка не остаётся в ведре
    -- из-за одного оборванного ответа.
    t.assert_equals({ sent[3].method, sent[4].method, #sent }, { 'DELETE', 'DELETE', 4 })
end

g.test_too_many_parts_is_a_failure = function()
    local client, sent = helper.client({
        initiated('U1'),
        web.answer(200, { headers = { ETag = '"p1"' } }),
        web.answer(204),
    })

    world.upload.MAX_PARTS = 1

    local writer = client:writer('k', { part_size = PART })

    t.assert_equals({ writer:write(('x'):rep(PART)) }, { true })

    local written, err = writer:write(('y'):rep(PART))

    t.assert_equals(written, nil)
    t.assert_equals(
        { err.kind, err.retriable, err.message },
        { 'rejected', false, 'k: частей больше 1 — возьмите part_size больше' }
    )
    t.assert_equals(sent[3].method, 'DELETE')
end

g.test_abort_cancels_a_started_upload_once = function()
    local client, sent =
        helper.client({ initiated('U1'), web.answer(200, { headers = { ETag = '"p1"' } }), web.answer(204) })
    local writer = client:writer('k', { part_size = PART })

    writer:write(('x'):rep(PART))

    t.assert_equals(writer:abort(), true)
    t.assert_equals(writer:abort(), true)
    t.assert_equals({ sent[3].method, sent[3].url }, { 'DELETE', BUCKET .. '/k?uploadId=U1' })
    t.assert_equals(#sent, 3)
end

g.test_abort_refused_is_a_pair = function()
    local client = helper.client({
        initiated('U1'),
        web.answer(200, { headers = { ETag = '"p1"' } }),
        helper.fault(403, 'AccessDenied', 'Access Denied.'),
    })
    local writer = client:writer('k', { part_size = PART })

    writer:write(('x'):rep(PART))

    local ok, err = writer:abort()

    t.assert_equals({ ok, err.kind }, { nil, 'denied' })
end

g.test_abort_before_the_start_and_after_the_finish_asks_nothing = function()
    local client, sent = helper.client({ web.answer(200) })
    local writer = client:writer('k')

    t.assert_equals(writer:abort(), true)

    local finished = client:writer('k')

    finished:finish()

    t.assert_equals(finished:abort(), true)
    t.assert_equals(#sent, 1)
end

g.test_writing_after_the_end_blames_the_caller = function()
    local client = helper.client({ web.answer(200) })
    local writer = client:writer('k')

    writer:finish()

    local aborted = client:writer('k')

    aborted:abort()

    helper.assert_blamed({
        {
            function()
                writer:write('x')
            end,
            'write: писатель объекта k уже закончен',
        },
        {
            function()
                aborted:finish()
            end,
            'finish: писатель объекта k уже закончен',
        },
    })
end

g.test_a_failed_single_put_is_kept = function()
    local client = helper.client({ helper.fault(403, 'AccessDenied', 'Access Denied.') })
    local writer = client:writer('k')
    local stored, err = writer:finish()

    t.assert_equals({ stored, err.kind }, { nil, 'denied' })
    t.assert_is(select(2, writer:write('x')), err)
end

g.test_put_file_over_a_part_goes_in_parts = function()
    local dir = fio.tempdir()
    local path = fio.pathjoin(dir, 'big.bin')
    local client, sent = helper.client({
        initiated('U1'),
        web.answer(200, { headers = { ETag = '"p1"' } }),
        web.answer(200, { headers = { ETag = '"p2"' } }),
        confirmed('CompleteMultipartUploadResult', 'whole-2'),
    })

    world.fs.write(path, ('x'):rep(PART) .. 'y')

    t.assert_equals(client:put_file('big', path, { part_size = PART }), { etag = 'whole-2' })

    local methods = {}

    for index, request in ipairs(sent) do
        methods[index] = request.method
    end

    t.assert_equals(methods, { 'POST', 'PUT', 'PUT', 'POST' })
    t.assert_equals({ #sent[2].body, sent[3].body }, { PART, 'y' })

    fio.rmtree(dir)
end

g.test_get_file_failing_midway_keeps_the_old_file = function()
    local dir = fio.tempdir()
    local path = fio.pathjoin(dir, 'target.bin')
    local client = helper.client({
        object_head(8, 'e'),
        web.answer(206, { body = 'abcd' }),
        helper.fault(403, 'AccessDenied', 'Access Denied.'),
    })

    world.fs.write(path, 'старое')

    local info, err = client:get_file('k', path, { piece = 4 })

    t.assert_equals({ info, err.kind }, { nil, 'denied' })
    t.assert_equals(world.fs.read(path), 'старое')
    t.assert_equals(fio.listdir(dir), { 'target.bin' })

    fio.rmtree(dir)
end

g.test_wrong_calls_blame_the_caller = function()
    local client = helper.client({})
    local writer = client:writer('k')

    helper.assert_blamed({
        {
            function()
                client:copy('', 'b')
            end,
            'откуда — непустая строка, а не пустая',
        },
        {
            function()
                client:copy('a', 'x/../b')
            end,
            'куда с отрезком «.» или «..» libcurl свернул бы: «x/../b»',
        },
        {
            function()
                client:copy('a', ('k'):rep(world.s3.MAX_KEY + 1))
            end,
            'куда длиннее 1024 байт: 1025',
        },
        {
            function()
                client:copy('a', 'b', { tiemout = 1 })
            end,
            'настройки вызова: ключа «tiemout» нет, есть idempotent, timeout',
        },
        {
            function()
                client:reader('./k')
            end,
            'ключ с отрезком «.» или «..» libcurl свернул бы: «./k»',
        },
        {
            function()
                client:reader('k', { piece = 0 })
            end,
            'piece — число от 1 до 16777216, а не 0',
        },
        {
            function()
                client:reader('k', { piece = 16 * 1024 * 1024 + 1 })
            end,
            'piece — число от 1 до 16777216, а не 16777217',
        },
        {
            function()
                client:reader('k', { size = 1 })
            end,
            'настройки вызова: ключа «size» нет, есть idempotent, piece, timeout',
        },
        {
            function()
                client:writer('')
            end,
            'ключ — непустая строка, а не пустая',
        },
        {
            function()
                client:writer('k', { part_size = PART - 1 })
            end,
            'part_size — число от 5242880 до 5368709120, а не 5242879',
        },
        {
            function()
                client:writer('k', { part_size = 5 * 1024 * 1024 * 1024 + 1 })
            end,
            'part_size — число от 5242880 до 5368709120, а не 5368709121',
        },
        {
            function()
                client:writer('k', { content_type = 'a\nb' })
            end,
            'content_type — только печатные знаки ASCII: закодируйте его, а не «a\nb»',
        },
        {
            function()
                writer:write(helper.wrong(7))
            end,
            'кусок — строка, а не число',
        },
    })
end

g.test_the_largest_part_and_piece_are_accepted = function()
    local client = helper.client({ object_head(0, 'e') })

    t.assert_equals(client:writer('k', { part_size = 5 * 1024 * 1024 * 1024 }).key, 'k')
    t.assert_equals(client:reader('k', { piece = 16 * 1024 * 1024 }).key, 'k')
end
