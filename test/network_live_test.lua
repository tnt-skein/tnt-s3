--- Отказ сети драйвера S3 на настоящем libcurl, без стенда S3.
---
--- Слова libcurl, по которым решается, ушёл ли запрос, у двойника
--- пересказаны, а у настоящего libcurl меняются от выпуска к выпуску.
--- Поэтому закрытый порт и сервер, который читает запись и сбрасывает
--- соединение, проверяются вживую: сервер — на сокете Tarantool прямо
--- в проверке, и без стенда проверки не пропускаются.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, world = helper.group('tnt.s3.network_live')

--- Поднятый проверкой сервер.
---@type table|nil
local listening

g.after_each(function()
    if listening ~= nil then
        listening.close()
        listening = nil
    end
end)

--- Клиент к указанному узлу: три попытки без пауз.
---@param endpoint string
---@return any
local function client_at(endpoint)
    helper.web.instant_retries()

    return world.s3.new(helper.options({ endpoint = endpoint, retry = { attempts = 3 } }))
end

g.test_nobody_listening_means_the_object_was_not_sent = function()
    local _, err = client_at('http://127.0.0.1:1'):put('k', 'v', { idempotent = false })

    t.assert_equals(err.kind, 'unreachable')
    t.assert_equals(err.sent, false)
    t.assert_equals(err.retriable, true)
end

g.test_a_reset_after_the_request_was_read_is_not_repeated_without_consent = function()
    listening = helper.web.resetting()

    local _, err = client_at(listening.url):put('k', 'v', { idempotent = false })

    t.assert_equals(err.kind, 'broken')
    t.assert_equals(err.sent, true)
    t.assert_equals(err.retriable, false)
    t.assert_equals(listening.received(), 1)
end
