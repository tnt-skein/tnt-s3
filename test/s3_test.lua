--- Драйвер S3 на двойнике libcurl: что уходит на сервер, как читается
--- ответ, какой отказ получает вызывающий и когда драйвер повторяет.

local fio = require('fio')
local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local web = helper.web

local g, world = helper.group('tnt.s3')

--- Свёртка пустого тела.
local EMPTY = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

--- Свёртка тела `hello`.
local HELLO = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'

--- Начало заголовка authorization у всех проверок.
local CREDENTIAL = 'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request'

--- Узел двойника.
local HOST = '127.0.0.1:9000'

--- Ведро двойника на узле.
local BUCKET = 'http://127.0.0.1:9000/tnt-live'

--- Ответ с отказом NoSuchBucket.
local function no_bucket()
    return helper.fault(404, 'NoSuchBucket', 'The specified bucket does not exist')
end

--- Сверяет отказ хранилища целиком.
---@param err any
---@param expected table
local function assert_failure(err, expected)
    t.assert(world.failure.is(err), tostring(err))
    t.assert_equals({
        kind = err.kind,
        message = err.message,
        reason = err.reason,
        retriable = err.retriable,
        sent = err.sent,
        server_code = err.server_code,
    }, expected)
end

g.test_put_signs_and_sends_the_object = function()
    local client, sent = helper.client({
        web.answer(200, { headers = { ETag = '"abc"', ['x-amz-version-id'] = 'v1' } }),
    }, { session_token = 'FQoG/token' })

    local stored, err = client:put('a b/c.txt', 'hello', {
        content_type = 'text/plain',
        metadata = { Author = 'Anna', ['Content-Kind'] = 'report' },
    })

    t.assert_equals(err, nil)
    t.assert_equals(stored, { etag = 'abc', version = 'v1' })
    t.assert_equals(#sent, 1)
    t.assert_equals(sent[1].method, 'PUT')
    t.assert_equals(sent[1].url, BUCKET .. '/a%20b/c.txt')
    t.assert_equals(sent[1].body, 'hello')
    t.assert_equals(sent[1].options.accept_encoding, 'identity')
    t.assert_equals(sent[1].options.follow_location, false)
    local headers = sent[1].options.headers
    local authorization = headers.authorization

    headers.authorization = nil
    t.assert_equals(headers, {
        host = HOST,
        ['content-type'] = 'text/plain',
        ['x-amz-meta-author'] = 'Anna',
        ['x-amz-meta-content-kind'] = 'report',
        ['x-amz-date'] = '20130524T000000Z',
        ['x-amz-content-sha256'] = HELLO,
        ['x-amz-security-token'] = 'FQoG/token',
        ['user-agent'] = 'tnt-s3',
        -- Ожидание 100 выключает клиент HTTP: после него `http.client`
        -- теряет заголовки ответа, а с ними метку части и версию объекта.
        expect = '',
    })
    t.assert_str_matches(
        authorization,
        CREDENTIAL:gsub('%-', '%%-')
            .. ', SignedHeaders=content%-type;host;x%-amz%-content%-sha256;x%-amz%-date;x%-amz%-meta%-author;'
            .. 'x%-amz%-meta%-content%-kind;x%-amz%-security%-token, Signature='
            .. ('%x'):rep(64)
    )
end

g.test_put_defaults = function()
    local client, sent = helper.client({ web.answer(200) })

    t.assert_equals({ client:put('k', '') }, { {} })
    t.assert_equals(sent[1].options.headers['content-type'], 'application/octet-stream')
    t.assert_equals(sent[1].options.headers['x-amz-content-sha256'], EMPTY)
    t.assert_equals(sent[1].options.headers['x-amz-security-token'], nil)
    t.assert_str_contains(
        sent[1].options.headers.authorization,
        'SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature='
    )
end

g.test_longest_key_and_dots_inside_names_pass = function()
    local client, sent = helper.client({ web.answer(200), web.answer(200), web.answer(200), web.answer(200) })
    local longest = ('k'):rep(world.s3.MAX_KEY)

    t.assert_equals({ client:put(longest, 'x') }, { {} })
    t.assert_equals({ client:put('a..b/.hidden/c.', 'x') }, { {} })
    t.assert_equals({ client:put('/lead//double', 'x') }, { {} })
    t.assert_equals({ client:put('x/.../y', 'x', { metadata = { note = '' } }) }, { {} })
    t.assert_equals(sent[4].options.headers['x-amz-meta-note'], '')
    t.assert_equals(sent[1].url, BUCKET .. '/' .. longest)
    t.assert_equals(sent[2].url, BUCKET .. '/a..b/.hidden/c.')
    t.assert_equals(sent[3].url, BUCKET .. '//lead//double')
end

g.test_get_returns_body_and_info = function()
    local client, sent = helper.client({
        web.answer(200, {
            headers = {
                ['Content-Length'] = '99',
                ['Content-Type'] = 'text/plain',
                ETag = '"abc"',
                ['Last-Modified'] = 'Sat, 19 Sep 2026 20:10:58 GMT',
                ['X-Amz-Meta-Author'] = 'Anna',
            },
            body = 'привет',
        }),
    })

    local body, info = client:get('проба')

    t.assert_equals(body, 'привет')
    t.assert_equals(tostring(info.modified), '2026-09-19T20:10:58Z')
    info.modified = nil
    t.assert_equals(info, { size = 12, type = 'text/plain', etag = 'abc', metadata = { author = 'Anna' } })
    t.assert_equals(sent[1].method, 'GET')
    t.assert_equals(sent[1].url, BUCKET .. '/%D0%BF%D1%80%D0%BE%D0%B1%D0%B0')
    t.assert_equals(sent[1].body, nil)
    t.assert_equals(sent[1].options.headers['x-amz-content-sha256'], EMPTY)
end

g.test_missing_object_is_nil_without_failure = function()
    local client, sent = helper.client({
        helper.fault(404, 'NoSuchKey', 'The specified key does not exist.'),
        web.answer(404),
    })

    t.assert_equals({ client:get('k') }, {})
    t.assert_equals({ client:head('k') }, {})
    t.assert_equals(sent[2].method, 'HEAD')
    t.assert_equals(#sent, 2)
end

g.test_missing_bucket_is_failure = function()
    local client = helper.client({ no_bucket(), no_bucket(), web.answer(404) })

    local body, err = client:get('k')

    t.assert_equals(body, nil)
    assert_failure(err, {
        kind = 'rejected',
        message = 'GET 127.0.0.1:9000/tnt-live/k: 404 NoSuchBucket: The specified bucket does not exist',
        reason = 'GET: 404 NoSuchBucket: The specified bucket does not exist',
        retriable = false,
        sent = true,
        server_code = 'NoSuchBucket',
    })

    -- Удаление промаха не знает: 404 у DELETE — отказ и с телом, и без.
    local _, deleting = client:delete('k')

    t.assert_equals(deleting.server_code, 'NoSuchBucket')

    local _, bare = client:delete('k')

    assert_failure(bare, {
        kind = 'rejected',
        message = 'DELETE 127.0.0.1:9000/tnt-live/k: 404',
        reason = 'DELETE: 404',
        retriable = false,
        sent = true,
        server_code = 404,
    })
end

g.test_head_reads_headers = function()
    local client, sent = helper.client({
        web.answer(200, { headers = { ['Content-Length'] = '12', ETag = '"e"', ['x-amz-version-id'] = 'v2' } }),
    })

    t.assert_equals(client:head('k'), { size = 12, etag = 'e', version = 'v2', metadata = {} })
    t.assert_equals(sent[1].method, 'HEAD')
end

g.test_delete = function()
    local client, sent = helper.client({ web.answer(204) })

    t.assert_equals({ client:delete('dir/k') }, { true })
    t.assert_equals(sent[1].method, 'DELETE')
    t.assert_equals(sent[1].url, BUCKET .. '/dir/k')
end

g.test_list_sends_params_and_reads_page = function()
    local client, sent = helper.client({
        web.answer(200, {
            body = '<ListBucketResult><IsTruncated>true</IsTruncated>'
                .. '<NextContinuationToken>next</NextContinuationToken>'
                .. '<Contents><Key>a/1</Key><Size>3</Size><ETag>&quot;e&quot;</ETag></Contents>'
                .. '<CommonPrefixes><Prefix>a/b/</Prefix></CommonPrefixes></ListBucketResult>',
        }),
    }, { session_token = 'FQoG/token' })

    local page = client:list({ prefix = 'a/', delimiter = '/', after = 'tok', limit = 2 })

    t.assert_equals(page, { items = { { key = 'a/1', size = 3, etag = 'e' } }, prefixes = { 'a/b/' }, next = 'next' })
    t.assert_equals(sent[1].method, 'GET')
    t.assert_equals(sent[1].url, BUCKET .. '?continuation-token=tok&delimiter=%2F&list-type=2&max-keys=2&prefix=a%2F')
    t.assert_equals(
        sent[1].options.headers.authorization,
        CREDENTIAL
            .. ', SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token'
            .. ', Signature=35d566e98919562ecfd6a46fee1e90d098a3bd9d688b962395c21a53262e4841'
    )
    t.assert_equals(sent[1].options.headers['x-amz-content-sha256'], EMPTY)
end

g.test_list_defaults_and_edges = function()
    local client, sent = helper.client({
        web.answer(200, { body = '<ListBucketResult/>' }),
        web.answer(200, { body = '<ListBucketResult/>' }),
        web.answer(200, { body = '<ListBucketResult/>' }),
    })

    t.assert_equals(client:list(), { items = {}, prefixes = {} })
    t.assert_equals(client:list({ limit = 1 }), { items = {}, prefixes = {} })
    t.assert_equals(client:list({ limit = 1000, prefix = '' }), { items = {}, prefixes = {} })
    t.assert_equals(sent[1].url, BUCKET .. '?list-type=2&max-keys=1000')
    t.assert_equals(sent[2].url, BUCKET .. '?list-type=2&max-keys=1')
    t.assert_equals(sent[3].url, BUCKET .. '?list-type=2&max-keys=1000&prefix=')
end

g.test_host_addressing_puts_bucket_into_host = function()
    local client, sent = helper.client({ web.answer(200, { body = '<ListBucketResult/>' }), web.answer(200) }, {
        endpoint = 'https://s3.example.org',
        addressing = 'host',
    })

    client:list()
    client:get('k')

    t.assert_equals(sent[1].url, 'https://tnt-live.s3.example.org/?list-type=2&max-keys=1000')
    t.assert_equals(sent[1].options.headers.host, 'tnt-live.s3.example.org')
    t.assert_equals(sent[2].url, 'https://tnt-live.s3.example.org/k')
end

g.test_denied_is_not_retried = function()
    local client, sent = helper.client({ helper.fault(403, 'AccessDenied', 'Access Denied.') })

    local _, err = client:put('k', 'v')

    assert_failure(err, {
        kind = 'denied',
        message = 'PUT 127.0.0.1:9000/tnt-live/k: 403 AccessDenied: Access Denied.',
        reason = 'PUT: 403 AccessDenied: Access Denied.',
        retriable = false,
        sent = false,
        server_code = 'AccessDenied',
    })
    t.assert_equals(#sent, 1)
end

g.test_code_without_message = function()
    local client = helper.client({
        web.answer(400, { body = '<Error><Code>InvalidArgument</Code></Error>' }),
    })

    local _, err = client:get('k')

    t.assert_equals(err.message, 'GET 127.0.0.1:9000/tnt-live/k: 400 InvalidArgument')
end

g.test_busy_is_retried_until_success = function()
    web.instant_retries()

    local client, sent = helper.client({
        helper.fault(503, 'SlowDown', 'Please reduce your request rate.'),
        web.answer(200, { body = 'x' }),
    })

    t.assert_equals((client:get('k')), 'x')
    t.assert_equals(#sent, 2)
end

g.test_broken_is_retried_only_when_idempotent = function()
    web.instant_retries()

    local client, sent = helper.client({
        helper.fault(500, 'InternalError', 'We encountered an internal error.'),
        web.answer(200),
        helper.fault(500, 'InternalError', 'We encountered an internal error.'),
    })

    t.assert_equals({ client:put('k', 'v') }, { {} })
    t.assert_equals(#sent, 2)

    local _, err = client:put('k', 'v', { idempotent = false })

    assert_failure(err, {
        kind = 'broken',
        message = 'PUT 127.0.0.1:9000/tnt-live/k: 500 InternalError: We encountered an internal error.',
        reason = 'PUT: 500 InternalError: We encountered an internal error.',
        retriable = false,
        sent = true,
        server_code = 'InternalError',
    })
    t.assert_equals(#sent, 3)
end

g.test_network_failures_by_libcurl_words = function()
    web.instant_retries()

    -- Соединение не открылось — кодом 595, с libcurl 8.9 «Could not»,
    -- до неё «Couldn't»; сброс после отправки — броском libcurl.
    local client, sent = helper.client({
        web.no_answer('Could not connect to server'),
        web.no_answer("Couldn't connect to server"),
        web.no_answer('Could not connect to server'),
        web.no_answer('Timeout was reached'),
        web.thrown('Failure when receiving data from the peer', 'Connection reset by peer'),
    }, { retry = { attempts = 3 } })

    local _, unreachable = client:get('k')

    t.assert_equals(unreachable.kind, 'unreachable')
    t.assert_equals(unreachable.sent, false)
    t.assert_equals(#sent, 3)

    local _, timeout = client:get('k', { idempotent = false })

    t.assert_equals(timeout.kind, 'timeout')
    t.assert_equals(timeout.retriable, false)
    t.assert_equals(#sent, 4)

    -- Сервер прочитал запись и сбросил соединение: без согласия второй
    -- раз она не уходит.
    local _, reset = client:put('k', 'v', { idempotent = false })

    t.assert_equals({ reset.kind, reset.sent, reset.retriable }, { 'broken', true, false })
    t.assert_equals(#sent, 5)
end

g.test_redirect_is_a_refusal = function()
    local client, sent = helper.client({ web.moved(301, 'http://elsewhere/') })

    local _, err = client:get('k')

    t.assert_equals(err.kind, 'rejected')
    t.assert_equals(err.server_code, 301)
    t.assert_equals(#sent, 1)
end

g.test_answer_over_the_limit_is_rejected = function()
    local client = helper.client({ web.answer(200, { body = 'hello' }) }, { max_bytes = 4 })

    local body, err = client:get('k')

    t.assert_equals(body, nil)
    t.assert_equals(err.kind, 'rejected')
    t.assert_str_contains(err.message, 'ответ в 5 байт больше предела в 4')
end

g.test_deadline_reaches_libcurl = function()
    local client, sent = helper.client({ web.answer(200), web.answer(200), web.answer(200) }, { timeout = 2 })

    -- Часы — двойники, и срок сверяется точно. На настоящих в него входило
    -- отставание отметки цикла от настоящих часов, а под нагрузкой оно
    -- выходит за любой допуск. Отставание здесь задано: 0,25 с у срока
    -- вызова и ноль у повторов клиента HTTP.
    web.instant_retries()
    world.within._set_source({
        monotonic = function()
            return 100
        end,
        scheduler_now = function()
            return 99.75
        end,
    })

    client:get('k', { timeout = 0.5 })
    client:get('k')
    -- Срок клиента HTTP — потолок драйвера: долгий вызов им не режется.
    client:get('k', { timeout = 59 })

    -- Миг срока отмечен настоящими часами, а остаток посчитан от отметки
    -- цикла и длиннее срока на её отставание: ожидание ответа отсчитает
    -- его от той же отметки.
    t.assert_equals(
        { sent[1].options.timeout, sent[2].options.timeout, sent[3].options.timeout },
        { 0.75, 2.25, 59.25 }
    )
end

g.test_tls_and_connections_reach_the_http_client = function()
    local client, sent = helper.client({ web.answer(200), web.answer(200) }, {
        endpoint = 'https://s3.example.org',
        verify = false,
        ca_file = '/etc/ca.pem',
        ca_path = '/etc/ca',
        max_connections = 3,
    })

    client:get('k')

    t.assert_equals(sent[1].options.verify_peer, false)
    t.assert_equals(sent[1].options.verify_host, false)
    t.assert_equals(sent[1].options.ca_file, '/etc/ca.pem')
    t.assert_equals(sent[1].options.ca_path, '/etc/ca')
    t.assert_equals(client.http:status().max_connections, 3)
    t.assert_equals(client.http:status().max_body, 16 * 1024 * 1024)
end

g.test_deadline_gone_before_the_first_attempt = function()
    local client, sent = helper.client({})

    world.within._set_source({
        monotonic = function()
            return 0
        end,
        scheduler_now = function()
            return 5
        end,
    })

    local _, err = client:get('k')

    assert_failure(err, {
        kind = 'timeout',
        message = 'срок вызова вышел до отправки запроса',
        reason = 'срок вызова вышел до отправки запроса',
        retriable = false,
        sent = false,
    })
    t.assert_equals(#sent, 0)
end

--- Первая попытка укладывается в срок, а ко второй от срока остаётся
--- `left` секунд: отказ — прошлой попытки, и повтора нет.
---@param left number Остаток ко второй попытке: ноль либо меньше
local function assert_gone_after_a_failed_attempt(left)
    web.instant_retries()

    local client, sent = helper.client({ helper.fault(503, 'SlowDown', 'Reduce your request rate.') })
    local asked = 0

    -- Срок вызова по умолчанию — 5 с от нуля монотонных часов.
    world.within._set_source({
        monotonic = function()
            return 0
        end,
        scheduler_now = function()
            asked = asked + 1

            return asked == 1 and 0 or 5 - left
        end,
    })

    local _, err = client:get('k')

    assert_failure(err, {
        kind = 'busy',
        message = 'GET 127.0.0.1:9000/tnt-live/k: 503 SlowDown: Reduce your request rate.',
        reason = 'GET: 503 SlowDown: Reduce your request rate.',
        retriable = false,
        sent = false,
        server_code = 'SlowDown',
    })
    t.assert_equals(#sent, 1)
end

g.test_deadline_gone_after_a_failed_attempt = function()
    -- Остаток ровно ноль — граница.
    assert_gone_after_a_failed_attempt(0)
    -- Срок перебран с запасом: остаток меньше нуля, а отказ всё тот же —
    -- прошлой попытки, а не срок до отправки.
    assert_gone_after_a_failed_attempt(-2)
end

g.test_closed_driver_refuses = function()
    local client, sent = helper.client({})

    t.assert_equals(client:close(), true)

    local again, closed = client:close()

    t.assert_equals(again, false)
    assert_failure(closed, {
        kind = 'closed',
        message = 's3: драйвер закрыт',
        reason = 's3: драйвер закрыт',
        retriable = false,
        sent = false,
    })

    for _, call in ipairs({
        function()
            return client:get('k')
        end,
        function()
            return client:put('k', 'v')
        end,
        function()
            return client:list()
        end,
        function()
            return client:presign('k')
        end,
    }) do
        local value, err = call()

        t.assert_equals(value, nil)
        t.assert_equals(err.kind, 'closed')
    end

    t.assert_equals(#sent, 0)
end

g.test_presign = function()
    local client, sent = helper.client({}, { session_token = 'FQoG/token' })

    --- Ссылка на объект `a b/c.txt` с этим сроком и подписью.
    local function link(expires, signature)
        return BUCKET
            .. '/a%20b/c.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256'
            .. '&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request'
            .. '&X-Amz-Date=20130524T000000Z&X-Amz-Expires='
            .. expires
            .. '&X-Amz-Security-Token=FQoG%2Ftoken&X-Amz-SignedHeaders=host&X-Amz-Signature='
            .. signature
    end

    t.assert_equals(
        client:presign('a b/c.txt'),
        link(900, '22d241e15d7a4d4b811e272e55bd318d83c1084e0da7715c772bb6966acda862')
    )
    t.assert_equals(
        client:presign('a b/c.txt', { method = 'PUT', expires = 60 }),
        link(60, '8e26ad046e75350f3dc27359833773c0762c15754f98614b929b8f5dfe02d8a3')
    )
    t.assert_str_contains(client:presign('k', { expires = 1 }), 'X-Amz-Expires=1&')
    t.assert_str_contains(client:presign('k', { expires = world.s3.MAX_EXPIRES }), 'X-Amz-Expires=604800&')
    t.assert_equals(#sent, 0)
end

g.test_files = function()
    local dir = fio.tempdir()
    local client, sent = helper.client({
        web.answer(200, { headers = { ETag = '"f"' } }),
        web.answer(200, { headers = { ETag = '"g"', ['Content-Length'] = '12' } }),
        web.answer(206, { body = 'снимок' }),
        web.answer(404),
        helper.fault(404, 'NoSuchKey', 'The specified key does not exist.'),
        web.answer(200, { headers = { ETag = '"g"', ['Content-Length'] = '12' } }),
    })
    local source = fio.pathjoin(dir, 'source.snap')
    local target = fio.pathjoin(dir, 'target.snap')

    world.fs.write(source, 'данные')

    local ok, stored = pcall(function()
        return client:put_file('snap', source, { content_type = 'application/x-snap' })
    end)

    t.assert(ok, stored)
    t.assert_equals(stored, { etag = 'f' })
    t.assert_equals(sent[1].method, 'PUT')
    t.assert_equals(sent[1].body, 'данные')
    t.assert_equals(sent[1].options.headers['content-type'], 'application/x-snap')

    t.assert_equals(client:get_file('snap', target), { size = 12, etag = 'g', metadata = {} })
    t.assert_equals(world.fs.read(target), 'снимок')
    t.assert_equals({ sent[2].method, sent[3].method }, { 'HEAD', 'GET' })
    t.assert_equals(sent[3].options.headers.range, 'bytes=0-11')
    t.assert_equals(sent[3].options.headers['if-match'], '"g"')

    -- Промах файла не трогает.
    t.assert_equals({ client:get_file('gone', target) }, {})
    t.assert_equals(world.fs.read(target), 'снимок')
    t.assert_equals(sent[5].options.headers.range, 'bytes=0-0')

    -- Отказ файла — отказ tnt-fs как есть, и в сеть дело не доходит.
    local _, unread = client:put_file('snap', fio.pathjoin(dir, 'absent'))

    t.assert_equals(unread.kind, 'missing')
    t.assert_equals(world.failure.is(unread), false)

    local _, unwritten = client:get_file('snap', fio.pathjoin(dir, 'absent', 'target'))

    t.assert_equals(unwritten.kind, 'missing')
    t.assert_equals(#sent, 6)
    t.assert_items_equals(fio.listdir(dir), { 'source.snap', 'target.snap' })

    fio.rmtree(dir)
end

g.test_stats_and_features_hold_no_secrets = function()
    local client = helper.client({}, { session_token = 'FQoG/token' })
    local stats = client:stats()

    t.assert_equals(client.name, 's3')
    t.assert_equals(client.bucket, 'tnt-live')
    t.assert_equals(client.features, { transaction = false })
    t.assert_equals(stats.name, 's3')
    t.assert_equals(stats.where, '127.0.0.1:9000/tnt-live')
    t.assert_equals(stats.region, 'us-east-1')
    t.assert_equals(stats.closed, false)
    t.assert_equals(stats.retry.scope, 's3')

    local shown = json.encode(stats)

    t.assert_not_str_contains(shown, helper.SECRET_KEY)
    t.assert_not_str_contains(shown, 'FQoG')
end

g.test_wrong_calls_blame_the_caller = function()
    local client = helper.client({})
    local key_rule = 'ключ с отрезком «.» или «..» libcurl свернул бы: «%s»'

    helper.assert_blamed({
        {
            function()
                client:get(helper.wrong(7))
            end,
            'ключ — непустая строка, а не число',
        },
        {
            function()
                client:head('')
            end,
            'ключ — непустая строка, а не пустая',
        },
        {
            function()
                client:delete(('k'):rep(world.s3.MAX_KEY + 1))
            end,
            'ключ длиннее 1024 байт: 1025',
        },
        {
            function()
                client:put('a/../b', 'v')
            end,
            key_rule:format('a/../b'),
        },
        {
            function()
                client:put('.', 'v')
            end,
            key_rule:format('.'),
        },
        {
            function()
                client:presign('x/..')
            end,
            key_rule:format('x/..'),
        },
        {
            function()
                client:get_file('./k', '/tmp/x')
            end,
            key_rule:format('./k'),
        },
        {
            function()
                client:put('k', helper.wrong(7))
            end,
            'тело — строка, а не число',
        },
        {
            function()
                client:put('k', 'v', { content_type = 'text/plain\r\nx-evil: 1' })
            end,
            'content_type — только печатные знаки ASCII: закодируйте его, а не «text/plain\r\nx-evil: 1»',
        },
        {
            function()
                client:put('k', 'v', { metadata = { ['bad name'] = 'x' } })
            end,
            'имя в metadata — латинские буквы, цифры и дефисы, а не «bad name»',
        },
        {
            function()
                client:put('k', 'v', { metadata = { [''] = 'x' } })
            end,
            'имя в metadata — латинские буквы, цифры и дефисы, а не «»',
        },
        {
            function()
                client:put('k', 'v', { metadata = { 'x' } })
            end,
            'имя в metadata — латинские буквы, цифры и дефисы, а не «1»',
        },
        {
            function()
                client:put('k', 'v', { metadata = { author = helper.wrong(7) } })
            end,
            'metadata.author — строка, а не число',
        },
        {
            function()
                client:put('k', 'v', { metadata = { author = 'Анна' } })
            end,
            'metadata.author — только печатные знаки ASCII: закодируйте его, а не «Анна»',
        },
        {
            function()
                client:put('k', 'v', { tiemout = 1 })
            end,
            'настройки вызова: ключа «tiemout» нет, есть content_type, idempotent, metadata, timeout',
        },
        {
            function()
                client:get('k', { timeout = 0 })
            end,
            'timeout — число секунд больше нуля и меньше бесконечности, а не 0',
        },
        {
            function()
                client:list({ limit = 0 })
            end,
            'limit — число от 1 до 1000, а не 0',
        },
        {
            function()
                client:list({ limit = 1001 })
            end,
            'limit — число от 1 до 1000, а не 1001',
        },
        {
            function()
                client:list({ after = '' })
            end,
            'настройки вызова.after — непустая строка, а не пустая',
        },
        {
            function()
                client:presign('k', { expires = 0 })
            end,
            'expires — число от 1 до 604800, а не 0',
        },
        {
            function()
                client:presign('k', { expires = world.s3.MAX_EXPIRES + 1 })
            end,
            'expires — число от 1 до 604800, а не 604801',
        },
        {
            function()
                client:presign('k', { method = 'POST' })
            end,
            'настройки ссылки.method — одно из «GET», «PUT», а не «POST»',
        },
        {
            function()
                client:put_file('k', helper.wrong(7))
            end,
            'путь — строка, а не число',
        },
        {
            function()
                client:get_file('k', helper.wrong(7))
            end,
            'путь — строка, а не число',
        },
    })
end

g.test_refusals_reach_head_and_get_file = function()
    -- У HEAD тела нет: нет ведра переспрашивается первым байтом.
    local client = helper.client({ helper.fault(403, 'AccessDenied', 'Access Denied.'), web.answer(404), no_bucket() })

    local info, denied = client:head('k')

    t.assert_equals(info, nil)
    t.assert_equals(denied.kind, 'denied')

    local written, missing = client:get_file('k', '/tmp/never-written')

    t.assert_equals(written, nil)
    t.assert_equals(missing.server_code, 'NoSuchBucket')
end

g.test_deadline_below_zero_and_below_a_second = function()
    web.instant_retries()

    local client, sent = helper.client({
        helper.fault(503, 'SlowDown', 'Reduce your request rate.'),
        web.answer(200, { body = 'x' }),
    })

    -- Остаток меньше секунды: повтор всё ещё идёт.
    t.assert_equals((client:get('k', { timeout = 0.5 })), 'x')
    t.assert_equals(#sent, 2)

    world.within._set_source({
        monotonic = function()
            return 0
        end,
        scheduler_now = function()
            return 7
        end,
    })

    local _, err = client:get('k')

    t.assert_equals(err.kind, 'timeout')
    t.assert_equals(err.sent, false)
    t.assert_equals(#sent, 2)
end

g.test_file_and_delete_blame_the_caller = function()
    local client = helper.client({})

    helper.assert_blamed({
        {
            function()
                client:put_file('', '/tmp/x')
            end,
            'ключ — непустая строка, а не пустая',
        },
        {
            function()
                client:put_file('k', '/tmp/x', { tiemout = 1 })
            end,
            'настройки вызова: ключа «tiemout» нет, есть content_type, idempotent, metadata, part_size, timeout',
        },
        {
            function()
                client:delete('k', { tiemout = 1 })
            end,
            'настройки вызова: ключа «tiemout» нет, есть idempotent, timeout',
        },
    })
end
