--- Общие средства проверок драйвера S3.
---
--- Клиент HTTP — настоящий `tnt-http`, а подменён под ним только libcurl
--- (двойник ниже, `helper.web`): так видно, что уходит на сервер до байта —
--- адрес, заголовки подписи, срок обращения, — и что клиент HTTP отдаёт
--- драйверу на каждый ответ сервера. Поведение настоящего S3 проверяет
--- `s3_live_test.lua` против Garage стенда.
---
--- Исходники пакета читаются с диска, а не через `require`: у Tarantool
--- свой загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.clock`, `tnt.date`, `tnt.fs`, `tnt.hash`,
--- `tnt.http`, `tnt.retry`, `tnt.external`, `tnt.storage`, а проверкам ещё
--- `tnt.env` — берутся из `.rocks` обычным `require`: проверяется этот
--- пакет, а не они.
---
--- Оснастка в `test/testing/` — загрузчик исходников, часы, которые
--- двигает проверка, и сценарий ответов — грузится так же, файлами, и один
--- раз на процесс: второй экземпляр загрузчика не знал бы, что вытеснил
--- первый, и не вернул бы вытесненное на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- там, где пакет живёт рядом со своими зависимостями.

local fiber = require('fiber')
local fio = require('fio')
--- Сеть. Через any: сервер со сбросом заводит голый сокет вызовом самого
--- модуля и зовёт методы такого сокета, а объявленных типов ни на то,
--- ни на другое нет.
---@type any
local socket = require('socket')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
    { name = 'tnt.testing.protocol', path = 'test/testing/protocol.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
    module = package.loaded['tnt.testing.sources'].module,
    clock = package.loaded['tnt.testing.clock'].new,
    script = package.loaded['tnt.testing.protocol'].script,
}

local helper = {
    --- Модули пакета в порядке зависимостей.
    MODULES = {
        { name = 'tnt.s3.xml', path = 'tnt/s3/xml.lua' },
        { name = 'tnt.s3.sign', path = 'tnt/s3/sign.lua' },
        { name = 'tnt.s3.reply', path = 'tnt/s3/reply.lua' },
        { name = 'tnt.s3.settings', path = 'tnt/s3/settings.lua' },
        { name = 'tnt.s3.call', path = 'tnt/s3/call.lua' },
        { name = 'tnt.s3.download', path = 'tnt/s3/download.lua' },
        { name = 'tnt.s3.upload', path = 'tnt/s3/upload.lua' },
        { name = 'tnt.s3.transfer', path = 'tnt/s3/transfer.lua' },
        { name = 'tnt.s3', path = 'tnt/s3.lua' },
    },
}

--- Двойник libcurl под `tnt-http` и ответы сервера.
local web = {}

--- Настройки проверки поверх умолчаний: новая таблица, умолчания целы.
---@param defaults table
---@param overrides table|nil
---@return table
function web.merged(defaults, overrides)
    local merged = {}

    for _, given in ipairs({ defaults, overrides or {} }) do
        for name, value in pairs(given) do
            merged[name] = value
        end
    end

    return merged
end

--- Ответ, который отдал бы настоящий сервер.
---
--- Заголовки приходят как есть, в том числе с заглавными буквами: чужой
--- сервер пишет их как вздумается, и приведение к нижнему регистру —
--- работа клиента, а не проверки.
---@param status integer
---@param overrides table|nil Поля поверх умолчаний
---@return table
function web.answer(status, overrides)
    return web.merged({ status = status, reason = 'Ok', headers = {}, body = '' }, overrides)
end

--- Ответ, которого не было: так `http.client` сообщает об отказе сети
--- до отправки — имя не разрешилось, соединение не открылось.
---
--- Заголовков нет вовсе, и это единственная надёжная примета: код 595
--- libcurl придумывает сам, и такой же мог бы придумать чужой сервер.
--- Слова по умолчанию — libcurl 8.11 статической сборки Tarantool 3.8
--- для Linux; до 8.9 libcurl писал «Couldn't resolve host name».
---@param reason string|nil
---@return table
function web.no_answer(reason)
    return { status = 595, reason = reason or 'Could not resolve hostname' }
end

--- Бросок libcurl: так `http.client` 3.8 сообщает об отказах без
--- придуманного кода — и до отправки (негодный адрес, рукопожатие TLS),
--- и после неё (сброс соединения, оборванное тело, мусор вместо ответа).
---
--- Текст — как у настоящего: `curl:`, слова libcurl и errno словами,
--- которое `http.client` дописывает сам.
---@param words string Слова libcurl
---@param cause string|nil errno словами
---@return table
function web.thrown(words, cause)
    return { raises = ('curl: %s: %s'):format(words, cause or 'Invalid argument') }
end

--- Переход на другой адрес.
---@param status integer
---@param location string
---@return table
function web.moved(status, location)
    return web.answer(status, { headers = { Location = location } })
end

--- Сервер, который дочитывает заголовки запроса и сбрасывает соединение.
---
--- Так выглядит служба, упавшая с запросом в руках: запрос дошёл, ответа
--- нет, и libcurl бросает «Failure when receiving data from the peer».
--- Сервер на голом сокете, а не на `tcp_server`: тот закрывает соединение
--- сам и мягко, и вместо сброса libcurl видел бы пустой ответ (код 444).
---@return table server url — начало адреса; received() — сколько запросов дошло; close()
function web.resetting()
    local listener = socket('AF_INET', 'SOCK_STREAM', 'tcp')

    assert(listener:bind('127.0.0.1', 0))
    assert(listener:listen(16))

    local received = 0

    local worker = fiber.create(function()
        while listener:readable() do
            local peer = listener:accept()

            if peer ~= nil then
                if peer:read('\r\n\r\n', 2) ~= nil then
                    received = received + 1
                end

                -- Ноль секунд задержки при закрытии — это сброс (RST), а не FIN.
                peer:linger(true, 0)
                peer:close()
            end
        end
    end)

    return {
        url = ('http://127.0.0.1:%d'):format(listener:name().port),
        received = function()
            return received
        end,
        close = function()
            worker:cancel()
            listener:close()
        end,
    }
end

--- Часы повторов: двойник оснастки, заводится заново на каждую проверку.
---
--- Заведены и до первой проверки: ответ двойника сервера с `takes` двигает
--- их и там, где повторы остались настоящими.
---@type TntTestingClock
local clock = testing.clock()

--- Двигает часы повторов вперёд.
---@param seconds number
function web.passes(seconds)
    clock.advance(seconds)
end

--- Повторы без настоящего ожидания.
---
--- Пауза перед повтором доходит до секунд, и проверка трёх попыток
--- стоила бы секунд вместо миллисекунд. Часы здесь двигает сама пауза:
--- сколько попросили поспать, на столько они и ушли вперёд. Отметка цикла
--- событий идёт вровень с ними — работы без уступки у двойника нет.
---@return number[] slept Длительности пауз по порядку
function web.instant_retries()
    clock = testing.clock()

    testing.module('tnt.retry.runner')._set_source({
        now = clock.monotonic,
        scheduler_now = clock.scheduler_now,
        sleep = clock.sleep,
    })

    return clock.slept
end

--- Ставит двойник libcurl на место настоящего.
---
--- Двойник помнит, о чём его просили, и отдаёт заранее написанные ответы
--- по порядку. Настоящий сокет для этого не нужен, а вот порядок
--- обращений — нужен весь: повторы только по нему и видны. Ответ с `takes`
--- двигает часы повторов: так видно, сколько срока остаётся следующему
--- обращению.
---@param script table[] Ответы по порядку; `raises` в ответе — брошенное
---@return table sent Что уходило на сервер
function web.serving(script)
    local sent = {}
    local answers = testing.script(script)

    local handle = {
        request = function(_, method, url, body, options)
            table.insert(sent, { method = method, url = url, body = body, options = options })

            -- Кончившийся сценарий — ошибка проверки: клиент, сходивший
            -- к серверу лишний раз, обязан об этом сказать.
            local answer = answers.next()

            if answer.takes ~= nil then
                web.passes(answer.takes)
            end

            if answer.raises ~= nil then
                error(answer.raises, 0)
            end

            return answer
        end,
    }

    testing.module('tnt.http.transport')._set_source({
        client = function()
            return handle
        end,
    })

    return sent
end

--- Части пакета и зависимости текущей проверки: заполняются заново перед
--- каждой.
---
--- Таблица одна на файл, а не ссылки, взятые при загрузке: исходники
--- грузятся заново перед каждой проверкой, и драйвер, собранный из прошлой
--- загрузки, остался бы со ссылками на прежние модули.
---@type table
local world = {}

--- Загружает исходники заново и раскладывает части по `world`.
---@return table world
function helper.fresh()
    world.s3 = testing.load_sources(helper.MODULES, 'tnt.s3')
    world.sign = testing.module('tnt.s3.sign')
    world.xml = testing.module('tnt.s3.xml')
    world.reply = testing.module('tnt.s3.reply')
    world.settings = testing.module('tnt.s3.settings')
    world.failure = testing.module('tnt.storage.failure')
    world.within = testing.module('tnt.storage.within')
    world.fs = testing.module('tnt.fs')
    world.upload = testing.module('tnt.s3.upload')

    return world
end

--- Двойник libcurl и ответы сервера.
helper.web = web

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Все куски читателя до конца: договор читателя у ведра тот же, что
--- у файла, и читается он тем же.
---@param reader any
---@return string[] chunks
---@return any err Чем кончилось чтение
function helper.drain(reader)
    local chunks = {}
    local chunk, err = reader:read()

    while chunk ~= nil do
        table.insert(chunks, chunk)
        chunk, err = reader:read()
    end

    return chunks, err
end

--- Чтение окружения для настроек живых проверок: порт стенда.
---
--- `tnt-env` приходит из `.rocks`: сам пакет окружения не читает,
--- и его зависимостью он не объявлен — его ставит `make deps`.
---@return table
function helper.stand_env()
    return require('tnt.env')
end

--- Ключ из примеров AWS: подпись с ним сверяется с документацией дословно.
helper.ACCESS_KEY = 'AKIAIOSFODNN7EXAMPLE'
helper.SECRET_KEY = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'

--- Миг подписи проверок: 2013-05-24T00:00:00Z, как в примерах AWS.
helper.NOW = 1369353600

--- Настройки драйвера проверок.
---@param overrides table|nil
---@return table
function helper.options(overrides)
    return web.merged({
        endpoint = 'http://127.0.0.1:9000',
        bucket = 'tnt-live',
        access_key = helper.ACCESS_KEY,
        secret_key = helper.SECRET_KEY,
    }, overrides)
end

--- Ставит двойник сервера и заводит драйвер поверх него.
---
--- Часы подписи стоят на `NOW`: подпись у проверки одна и та же на всяком
--- прогоне, и её можно сверять целиком.
---@param script table[] Ответы сервера по порядку
---@param overrides table|nil Настройки драйвера поверх `options`
---@return TntS3Client client
---@return table sent Что уходило на сервер
function helper.client(script, overrides)
    local sent = web.serving(script)

    world.s3._set_source({
        now = function()
            return helper.NOW
        end,
    })

    return world.s3.new(helper.options(overrides)), sent
end

--- Ответ S3 с отказом.
---@param status integer
---@param code string
---@param message string
---@return table
function helper.fault(status, code, message)
    return web.answer(status, {
        headers = { ['Content-Type'] = 'application/xml' },
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>%s</Code><Message>%s</Message>'
            .. '<RequestId>4442587FB7D0A2F9</RequestId></Error>'
        ):format(code, message),
    })
end

--- Внешние зависимости, которые подменяют проверки: часы срока, libcurl и паузы повторов.
---
--- Снимаются все разом и по списку: снятую поимённо зависимость однажды забудут,
--- и следующая проверка пойдёт с чужим двойником.
local SEAMS = { 'tnt.storage.within', 'tnt.http.transport', 'tnt.retry.runner' }

--- Возвращает пакету и зависимостям настоящие часы, сеть и паузы
--- и убирает исходники: следующая проверка грузит их заново.
function helper.restore()
    world.s3._set_source(nil)

    for _, name in ipairs(SEAMS) do
        testing.module(name)._set_source(nil)
    end

    testing.unload_sources(helper.MODULES)
end

--- Группа проверок: исходники грузятся перед каждой проверкой
--- и убираются после.
---@param name string
---@return table group Группа luatest
---@return table world Части пакета текущей проверки
function helper.group(name)
    local group = t.group(name)

    group.before_each(helper.fresh)
    group.after_each(helper.restore)

    return group, world
end

return helper
