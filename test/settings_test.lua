--- Настройки драйвера: умолчания, адресация ведра и отказ на негодном —
--- исключением на строке того, кто завёл драйвер.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, world = helper.group('tnt.s3.settings')

--- Настройки, какими их проверил и дополнил драйвер.
---
--- Через `s3.new`, а не `settings.check` напрямую: вина броска
--- отсчитывается от строки того, кто завёл драйвер, на два кадра выше
--- `check`. Позванная из проверки, `check` отдала бы бросок на годных
--- настройках кадру luatest, и прогон назвал бы его отказом запуска,
--- а не упавшей проверкой.
---@param overrides table|nil Настройки поверх `helper.options`
---@return TntS3Settings
local function checked_of(overrides)
    return world.s3.new(helper.options(overrides)).settings
end

g.test_defaults = function()
    local checked = checked_of()

    t.assert_equals(checked, {
        name = 's3',
        bucket = 'tnt-live',
        where = '127.0.0.1:9000/tnt-live',
        origin = 'http://127.0.0.1:9000',
        host = '127.0.0.1:9000',
        root = '/tnt-live',
        credentials = {
            access_key = helper.ACCESS_KEY,
            secret_key = helper.SECRET_KEY,
            region = 'us-east-1',
        },
        limits = { timeout = 5, max_timeout = 60 },
        max_bytes = 16 * 1024 * 1024,
        http = {},
        retry = {},
    })
    t.assert_equals(world.settings.DEFAULT_REGION, 'us-east-1')
end

g.test_everything_given = function()
    local checked = checked_of({
        endpoint = 'HTTPS://s3.eu-central-1.amazonaws.com/',
        region = 'eu-central-1',
        bucket = 'backups.2026',
        session_token = 'token',
        addressing = 'host',
        timeout = 2,
        max_timeout = 30,
        max_bytes = 1024,
        verify = false,
        ca_file = '/etc/ca.pem',
        ca_path = '/etc/ca',
        max_connections = 4,
        retry = { attempts = 5 },
        name = 'archive',
    })

    t.assert_equals(checked, {
        name = 'archive',
        bucket = 'backups.2026',
        where = 's3.eu-central-1.amazonaws.com/backups.2026',
        origin = 'https://backups.2026.s3.eu-central-1.amazonaws.com',
        host = 'backups.2026.s3.eu-central-1.amazonaws.com',
        root = '',
        credentials = {
            access_key = helper.ACCESS_KEY,
            secret_key = helper.SECRET_KEY,
            session_token = 'token',
            region = 'eu-central-1',
        },
        limits = { timeout = 2, max_timeout = 30 },
        max_bytes = 1024,
        http = { verify = false, ca_file = '/etc/ca.pem', ca_path = '/etc/ca', max_connections = 4 },
        retry = { attempts = 5 },
    })
    t.assert_equals(checked_of({ addressing = 'path' }).root, '/tnt-live')
end

g.test_bucket_names_by_s3_rules = function()
    for _, bucket in ipairs({ 'abc', 'a-b.c9', ('a'):rep(63), '1bucket', 'a.b' }) do
        t.assert_equals(checked_of({ bucket = bucket }).bucket, bucket)
    end
end

g.test_wrong_settings_blame_the_caller = function()
    local bucket_rule = 'настройки s3.bucket — 3–63 знака: строчные латинские буквы, цифры, точки и дефисы, '
        .. 'по краям буква либо цифра, а не «%s»'
    local endpoint_rule =
        'настройки s3.endpoint — адрес вида http(s)://узел[:порт] без пути, а не «%s»'

    helper.assert_blamed({
        {
            function()
                world.s3.new(nil)
            end,
            'настройки s3 — таблица, а не nil',
        },
        {
            function()
                world.s3.new(helper.options({ secret_kye = 'x' }))
            end,
            'настройки s3: ключа «secret_kye» нет, есть access_key, addressing, bucket, ca_file, ca_path, '
                .. 'endpoint, max_bytes, max_connections, max_timeout, name, region, retry, secret_key, '
                .. 'session_token, timeout, verify',
        },
        {
            function()
                world.s3.new(helper.options({ endpoint = 'ftp://h' }))
            end,
            endpoint_rule:format('ftp://h'),
        },
        {
            function()
                world.s3.new(helper.options({ endpoint = 'http://h/prefix' }))
            end,
            endpoint_rule:format('http://h/prefix'),
        },
        {
            function()
                world.s3.new(helper.options({ endpoint = 'http://user:pass@h' }))
            end,
            endpoint_rule:format('http://user:pass@h'),
        },
        {
            function()
                world.s3.new(helper.options({ endpoint = 'h:9000' }))
            end,
            endpoint_rule:format('h:9000'),
        },
        {
            function()
                world.s3.new(helper.options({ bucket = 'ab' }))
            end,
            bucket_rule:format('ab'),
        },
        {
            function()
                world.s3.new(helper.options({ bucket = '.abc' }))
            end,
            bucket_rule:format('.abc'),
        },
        {
            function()
                world.s3.new(helper.options({ bucket = 'abc.' }))
            end,
            bucket_rule:format('abc.'),
        },
        {
            function()
                world.s3.new(helper.options({ bucket = '-abc' }))
            end,
            bucket_rule:format('-abc'),
        },
        {
            function()
                world.s3.new(helper.options({ endpoint = 'http://' }))
            end,
            endpoint_rule:format('http://'),
        },
        {
            function()
                world.s3.new(helper.options({ endpoint = 'http://h//' }))
            end,
            endpoint_rule:format('http://h//'),
        },
        {
            function()
                world.s3.new(helper.options({ bucket = ('a'):rep(64) }))
            end,
            bucket_rule:format(('a'):rep(64)),
        },
        {
            function()
                world.s3.new(helper.options({ bucket = 'Backups' }))
            end,
            bucket_rule:format('Backups'),
        },
        {
            function()
                world.s3.new(helper.options({ bucket = 'backups-' }))
            end,
            bucket_rule:format('backups-'),
        },
        {
            function()
                world.s3.new(helper.options({ bucket = 'my_bucket' }))
            end,
            bucket_rule:format('my_bucket'),
        },
        {
            function()
                world.s3.new(helper.options({ max_bytes = 0 }))
            end,
            'настройки s3.max_bytes — число больше 0, а не 0',
        },
        {
            function()
                world.s3.new(helper.options({ max_connections = 0 }))
            end,
            'настройки s3.max_connections — число больше 0, а не 0',
        },
        {
            function()
                world.s3.new(helper.options({ addressing = 'virtual' }))
            end,
            'настройки s3.addressing — одно из «path», «host», а не «virtual»',
        },
        {
            function()
                world.s3.new(helper.options({ timeout = 90 }))
            end,
            'timeout 90 с длиннее потолка max_timeout 60 с',
        },
        {
            function()
                world.s3.new(helper.options({ retry = { attempts = 0 } }))
            end,
            'настройки повторов: настройка attempts — целое число от 1, а пришло: 0',
        },
    })
end
