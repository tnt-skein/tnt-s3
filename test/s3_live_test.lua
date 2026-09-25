--- Драйвер против настоящего S3 — Garage стенда.
---
--- Двойник показывает, что мы правильно разговариваем сами с собой.
--- Настоящий сервер показывает, что нашу подпись сверяет кто-то ещё:
--- ключ с кириллицей, пробелом и `+`, заголовок host с портом, сведения
--- `x-amz-meta-*`, ссылка с подписью без ключа доступа, отказ подписи
--- и отказ прав. Сервер поднимается отдельно — `make s3-up`
--- (`test/stand/s3.sh`), — и если его нет, проверки честно пропускаются:
--- гейты не должны зависеть от докера.

local fio = require('fio')
local socket = require('socket')
local t = require('luatest')
local uuid = require('uuid')

local helper = dofile('test/helper.lua')

local g, world = helper.group('tnt.s3.live')

--- Окружение стенда — через `tnt-env`: мимо него окружение не читают
--- и проверки.
local env = helper.stand_env()

--- Где стоит сервер: тот же порт, что у скрипта стенда.
local PORT = env.int('STAND_S3_PORT', 19000)
local ENDPOINT = ('http://127.0.0.1:%d'):format(PORT)

--- Ключи стенда — те же, что заводит `test/stand/s3.sh`: с правами
--- чтения и записи и только для чтения.
local STAND_KEY = 'GK746e742d7374616e642d7277'
local STAND_SECRET = 'db299f3310a74ee703523bb4d3a6df11a031668814c5af9568008e879cc7106f'
local READER_KEY = 'GK746e742d726561646f6e6c79'
local READER_SECRET = 'b047f9d1b3f5b3da0c3a97983c6837cc4bcb9e98e09356708db69bc2e3768b64'

--- Опознаватель прогона: ключи прошлого прогона, упавшего на середине,
--- не мешают этому.
local RUN = uuid.str()

--- Отвечает ли кто-нибудь на порту стенда.
---@return boolean
local function listening()
    local connection = socket.tcp_connect('127.0.0.1', PORT, 0.3)

    if connection == nil then
        return false
    end

    connection:close()

    return true
end

--- Драйвер стенда. Род — `any`: проверка читает поля ответа сразу, а пустоту
--- на их месте ловит сверка, а не анализатор.
---@param overrides table|nil
---@return any
local function stand(overrides)
    return world.s3.new(helper.web.merged({
        endpoint = ENDPOINT,
        bucket = 'tnt-live',
        access_key = STAND_KEY,
        secret_key = STAND_SECRET,
    }, overrides))
end

--- Ключ этого прогона.
---@param name string
---@return string
local function key_of(name)
    return ('%s/%s'):format(RUN, name)
end

g.before_all(function()
    t.skip_if(not listening(), 'S3 не отвечает: поднимите его — make s3-up')
end)

g.test_object_round_trip = function()
    local client = stand()
    local key = key_of('проба/a b+c~(1).txt')

    local stored, err = client:put(key, 'привет', { content_type = 'text/plain', metadata = { Author = 'Anna' } })

    t.assert_equals(err, nil)
    t.assert_equals(#stored.etag, 32)

    local body, info = client:get(key)

    t.assert_equals(body, 'привет')
    t.assert_equals(info.size, 12)
    t.assert_equals(info.etag, stored.etag)
    t.assert_equals(info.type, 'text/plain')
    t.assert_equals(info.metadata, { author = 'Anna' })
    t.assert_equals(info.modified.year >= 2026, true)

    local head = client:head(key)

    t.assert_equals(head.size, 12)
    t.assert_equals(head.etag, stored.etag)

    t.assert_equals(client:delete(key), true)
    t.assert_equals({ client:get(key) }, {})
    t.assert_equals({ client:head(key) }, {})
    -- Удаление того, чего нет, — не отказ: так отвечает сам S3.
    t.assert_equals(client:delete(key), true)
end

g.test_list_pages_and_prefixes = function()
    local client = stand()

    for _, name in ipairs({ 'list/a', 'list/b', 'list/c', 'list/dir/d' }) do
        t.assert_equals(client:put(key_of(name), name) ~= nil, true)
    end

    local first = client:list({ prefix = key_of('list/'), delimiter = '/', limit = 2 })

    t.assert_equals(#first.items, 2)
    t.assert_equals(first.items[1].key, key_of('list/a'))
    t.assert_equals(first.items[1].size, 6)
    t.assert_not_equals(first.next, nil)

    local second = client:list({ prefix = key_of('list/'), delimiter = '/', limit = 2, after = first.next })
    local keys = {}

    for _, item in ipairs(second.items) do
        table.insert(keys, item.key)
    end

    t.assert_equals(keys, { key_of('list/c') })
    t.assert_equals(second.prefixes, { key_of('list/dir/') })
    t.assert_equals(second.next, nil)
end

g.test_presigned_links_work_without_keys = function()
    local client = stand()
    local key = key_of('ссылка.txt')
    ---@type any
    local http = require('http.client')

    local upload = client:presign(key, { method = 'PUT', expires = 60 })
    local put = http.put(upload, 'по ссылке')

    t.assert_equals(put.status, 200)

    local download = http.get(client:presign(key))

    t.assert_equals(download.status, 200)
    t.assert_equals(download.body, 'по ссылке')
end

g.test_files = function()
    local client = stand()
    local dir = fio.tempdir()
    local source = fio.pathjoin(dir, 'source.snap')
    local target = fio.pathjoin(dir, 'target.snap')

    world.fs.write(source, ('снимок'):rep(1000))

    local stored = client:put_file(key_of('snap'), source)
    local info = client:get_file(key_of('snap'), target)

    t.assert_equals(info.etag, stored.etag)
    t.assert_equals(world.fs.read(target), ('снимок'):rep(1000))

    fio.rmtree(dir)
end

g.test_big_objects_go_in_parts_and_come_back_in_ranges = function()
    local client = stand({ timeout = 30 })
    local key = key_of('частями.bin')
    local writer = client:writer(key, { content_type = 'application/x-test', part_size = 5 * 1024 * 1024 })
    local chunk = ('0123456789abcdef'):rep(4096)

    for _ = 1, 200 do
        t.assert_equals({ writer:write(chunk) }, { true })
    end

    local stored, err = writer:finish()

    t.assert_equals(err, nil)
    -- Метка собранного объекта — свёртка меток частей и их число.
    t.assert_str_matches(stored.etag, '%x+%-3')

    local reader = client:reader(key, { piece = 3 * 1024 * 1024 })

    t.assert_equals({ reader.info.size, reader.info.type }, { 200 * #chunk, 'application/x-test' })

    local total, pieces = 0, 0

    while true do
        local piece = reader:read()

        if piece == nil then
            break
        end

        t.assert_equals(piece:sub(1, 16), '0123456789abcdef')
        total, pieces = total + #piece, pieces + 1
    end

    t.assert_equals({ total, pieces }, { 200 * #chunk, 5 })
    t.assert_equals(client:delete(key), true)
end

g.test_a_body_over_a_megabyte_keeps_its_tag = function()
    local client = stand()
    local key = key_of('мегабайт.bin')
    -- libcurl шлёт такое тело с `Expect: 100-continue`; метка содержимого
    -- в ответе обязана дойти до вызывающего.
    local stored = client:put(key, ('x'):rep(2 * 1024 * 1024))

    t.assert_equals(#stored.etag, 32)
    t.assert_equals(client:head(key).etag, stored.etag)
end

g.test_copy_and_the_reader_of_what_is_not_there = function()
    local client = stand()
    local source = key_of('копия/источник.txt')

    client:put(source, 'данные', { content_type = 'text/plain' })

    local copied = client:copy(source, key_of('копия/копия.txt'))

    t.assert_equals(#copied.etag, 32)
    t.assert_equals((client:get(key_of('копия/копия.txt'))), 'данные')
    t.assert_equals(client:head(key_of('копия/копия.txt')).type, 'text/plain')

    local _, missing = client:copy(key_of('копия/нет'), key_of('копия/куда'))

    t.assert_equals({ missing.kind, missing.server_code }, { 'rejected', 'NoSuchKey' })
    t.assert_equals({ client:reader(key_of('копия/нет')) }, {})

    local _, bucket = stand({ bucket = 'no-such-bucket' }):reader(key_of('x'))

    t.assert_equals(bucket.server_code, 'NoSuchBucket')

    local empty = key_of('копия/пусто')

    client:put(empty, '')
    t.assert_equals({ client:reader(empty):read() }, {})
end

g.test_refusals = function()
    local _, signature = stand({ secret_key = 'wrong' }):get(key_of('x'))

    t.assert_equals(signature.kind, 'denied')
    -- Неверную подпись Garage называет общим AccessDenied, а не
    -- SignatureDoesNotMatch. Что отказала подпись, а не ключ, видно
    -- по словам сервера: на незнакомый ключ код тот же.
    t.assert_equals(signature.server_code, 'AccessDenied')
    t.assert_str_contains(signature.message, 'Invalid signature')
    t.assert_equals(signature.retriable, false)

    local _, bucket = stand({ bucket = 'no-such-bucket' }):get(key_of('x'))

    t.assert_equals(bucket.kind, 'rejected')
    t.assert_equals(bucket.server_code, 'NoSuchBucket')

    local reader = stand({ access_key = READER_KEY, secret_key = READER_SECRET })
    local _, rights = reader:put(key_of('x'), 'y')

    t.assert_equals(rights.kind, 'denied')
    t.assert_equals(rights.server_code, 'AccessDenied')
    -- Читать ключу можно: отказ был в правах, а не во входе.
    t.assert_equals({ reader:get(key_of('absent')) }, {})
end

g.test_unreachable_endpoint = function()
    local _, err = stand({ endpoint = 'http://127.0.0.1:1', timeout = 1, retry = { attempts = 1 } }):get('x')

    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.sent, false)
end
