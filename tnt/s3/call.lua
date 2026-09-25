--- Обращение к S3: проверка аргументов, сборка, подпись, попытки и перевод
--- ответа в отказ.
---
--- Действия драйвера — `put`, `get`, загрузка частями, чтение кусками —
--- говорят со службой одним и тем же способом: один миг срока на вызов,
--- подпись на каждую попытку своя, повтор по приговору отказа, промах
--- «нет ключа» — `nil` без отказа. Способ живёт здесь один раз, а действия
--- собирают только обращение — метод, ключ, параметры, заголовки, тело.
---
--- Часы подписи — внешняя зависимость модуля: проверка ставит миг сама,
--- и подпись у неё одна и та же на всяком прогоне. Подменяет их фасад —
--- `s3._set_source({ now = … })`.

local clock = require('tnt.clock')
local codes = require('tnt.storage.codes')
local external = require('tnt.external')
local hash = require('tnt.hash')
local must = require('tnt.must')
local storage = require('tnt.storage')

local reply = require('tnt.s3.reply')
local sign = require('tnt.s3.sign')

local failure, within = storage.failure, storage.within

---@class TntS3CallModule
---@field _set_source fun(replacement: table|nil) Подмена часов подписи — для проверок; ставит её `external.install`
local Module = {}

--- Часы подписи: миг `x-amz-date`. Стенные, а не монотонные: S3 сверяет
--- его со своими часами и отказывает при расхождении больше 15 минут.
local source = external.install(Module, { now = clock.realtime })

--- Самый длинный ключ, который принимает S3: 1024 байта.
Module.MAX_KEY = 1024

--- Вид содержимого, когда его не назвали.
---
--- Ставится явно: без него libcurl пометил бы тело PUT как форму
--- (`application/x-www-form-urlencoded`), и S3 так бы его и записал.
Module.DEFAULT_TYPE = 'application/octet-stream'

--- Настройки обращений: срок и согласие на повтор после отправки.
Module.CALL = { timeout = '?number', idempotent = '?boolean' }

--- Код S3, с которым `get` объекта, которого нет, — промах, а не отказ.
local NO_SUCH_KEY = 'NoSuchKey'

--- Код ответа «нет такого».
Module.NOT_FOUND = 404

--- Знаки, которые можно поставить в заголовок: печатные ASCII.
---
--- Перевод строки в значении дописал бы запросу свой заголовок, а буквы
--- вне ASCII S3 хранит не так, как их прислали: закодировать их —
--- дело вызывающего (base64, RFC 2047).
local UNPRINTABLE = '[^\32-\126]'

---@class TntS3Call: TntS3Unsigned Обращение к S3 до подписи: подписываются его путь, параметры, заголовки
---@field body string|nil
---@field shown string Что назвать в отказе: ведро на узле и ключ
---@field miss boolean|nil Отсутствие объекта — промах, а не отказ
---@field confirm boolean|nil Итог — в теле: код 200 с отказом в теле — отказ

--- Миг подписи в виде `x-amz-date`.
---@return string
function Module.stamp()
    return sign.stamp(source().now())
end

--- Отказ закрытого драйвера: закрытие гонится с запросами при остановке
--- узла, и это «так бывает», а не ошибка кода.
---@param client TntS3Client
---@return TntStorageFailure
function Module.closed(client)
    return failure.new(failure.CLOSED, ('%s: драйвер закрыт'):format(client.name))
end

--- Проверяет ключ объекта.
---
--- Отрезок `.` или `..` не пропускается: libcurl сворачивает такой путь
--- по RFC 3986 (`a/../b` уходит как `b`), и запрос попал бы не в тот
--- объект — а подпись, посчитанная по несвёрнутому пути, не сошлась бы.
---@param key any
---@param level integer Уровень вины, как у `error`, в кадрах того, кто зовёт
---@param name string|nil Как назвать ключ в отказе; по умолчанию «ключ»
function Module.check_key(key, level, name)
    name = name or 'ключ'

    must.at(level + 1).not_empty(key, name)

    if #key > Module.MAX_KEY then
        error(('%s длиннее %d байт: %d'):format(name, Module.MAX_KEY, #key), level + 1)
    end

    if ('/' .. key .. '/'):find('/%.%.?/') ~= nil then
        error(
            ('%s с отрезком «.» или «..» libcurl свернул бы: «%s»'):format(name, key),
            level + 1
        )
    end
end

--- Проверяет значение заголовка: только печатные ASCII.
---@param value string
---@param name string Как назвать значение в отказе
---@param level integer
local function check_header(value, name, level)
    if value:find(UNPRINTABLE) ~= nil then
        error(
            ('%s — только печатные знаки ASCII: закодируйте его, а не «%s»'):format(
                name,
                value
            ),
            level + 1
        )
    end
end

--- Срок и согласие на повтор из настроек вызова.
---@param client TntS3Client
---@param opts table|nil
---@param spec table Какие ключи годятся
---@param level integer
---@return number timeout
---@return boolean idempotent
function Module.options(client, opts, spec, level)
    must.at(level + 1).optional.options(opts, 'настройки вызова', spec)

    local given = opts or {}

    return within.timeout(given.timeout, client.settings.limits, level + 1), given.idempotent ~= false
end

--- Заголовки записи: вид содержимого и пользовательские сведения.
---@param opts table
---@param level integer
---@return table<string, string>
function Module.put_headers(opts, level)
    local content_type = opts.content_type or Module.DEFAULT_TYPE

    check_header(content_type, 'content_type', level + 1)

    local headers = { ['content-type'] = content_type }

    for name, value in pairs(opts.metadata or {}) do
        if type(name) ~= 'string' or name == '' or name:find('[^%w%-]') ~= nil then
            error(
                ('имя в metadata — латинские буквы, цифры и дефисы, а не «%s»'):format(
                    tostring(name)
                ),
                level + 1
            )
        end

        must.at(level + 1).string(value, ('metadata.%s'):format(name))
        check_header(value, ('metadata.%s'):format(name), level + 1)

        headers['x-amz-meta-' .. name:lower()] = value
    end

    return headers
end

--- Отказ прошлой попытки, у которой срок кончился раньше следующей.
---
--- Род и текст — её, повтора нет: пауза `tnt-retry` меряет свой срок
--- от своего начала и могла в него уложиться, не уложившись в миг
--- вызова.
---@param last TntStorageFailure
---@return TntStorageFailure
local function final(last)
    return failure.new(last.kind, last.message, {
        retriable = false,
        sent = last.sent,
        reason = last.reason,
        server_code = last.server_code,
    })
end

--- Отказ по ответу S3.
---
--- Род — по коду ответа (`codes.status`), код S3 — в `server_code`,
--- а без него (у HEAD тела нет) — сам код ответа. В журнальную причину
--- ключ не попадает: имена объектов бывают личными данными.
---@param call TntS3Call
---@param status integer Код ответа, по которому выбирается род
---@param body string Тело ответа: в нём код и слова S3
---@param idempotent boolean
---@return TntStorageFailure
local function refusal(call, status, body, idempotent)
    local code, text = reply.fault(body)
    local said = tostring(status)

    if code ~= nil then
        said = ('%s %s'):format(said, code)
    end

    if text ~= nil then
        said = ('%s: %s'):format(said, text)
    end

    return failure.new(codes.status(status), ('%s %s: %s'):format(call.method, call.shown, said), {
        server_code = code or status,
        idempotent = idempotent,
        reason = ('%s: %s'):format(call.method, said),
    })
end

--- Ответ «нет такого объекта», который промах, а не отказ.
---
--- У HEAD тела нет, и отсутствие ведра от отсутствия ключа не отличить:
--- 404 у HEAD — промах всегда.
---@param call TntS3Call
---@param answer TntHttpResponse
---@return boolean
local function missing(call, answer)
    return call.miss == true
        and answer.status == Module.NOT_FOUND
        and (call.method == 'HEAD' or reply.fault(answer.body) == NO_SUCH_KEY)
end

--- Отказ в теле ответа 200 у действия, которое подтверждает итог телом:
--- копии и завершения загрузки частями.
---
--- S3 шлёт заголовки сразу, а долгую работу доделывает, пока идёт тело, —
--- и если она не удалась, пишет отказ в тело ответа с кодом 200.
---@param call TntS3Call
---@param answer TntHttpResponse
---@return boolean
local function faulted(call, answer)
    return call.confirm == true and reply.fault(answer.body) ~= nil
end

--- Одна попытка: подписать, отправить, прочитать исход.
---
--- Подпись — на каждую попытку своя: миг `x-amz-date` у повтора новый,
--- и S3 не спутает его с перехваченным старым запросом.
---@param client TntS3Client
---@param call TntS3Call
---@param deadline number
---@param idempotent boolean
---@param last TntStorageFailure|nil Отказ прошлой попытки
---@return TntHttpResponse|nil answer Ответ 2xx либо промах 404
---@return TntStorageFailure|nil err
local function attempt(client, call, deadline, idempotent, last)
    if client.closed then
        return nil, Module.closed(client)
    end

    local left = within.left(deadline)

    if left <= 0 and last ~= nil then
        return nil, final(last)
    end

    -- Попытки не было, а срок уже вышел: запрос не ушёл вовсе.
    if left <= 0 then
        return nil,
            failure.new(
                failure.TIMEOUT,
                'срок вызова вышел до отправки запроса',
                { sent = false }
            )
    end

    local target = client.settings.origin .. call.path

    if call.query ~= '' then
        target = ('%s?%s'):format(target, call.query)
    end

    local answer, err = client.http:request({
        method = call.method,
        url = target,
        headers = sign.headers(client.settings.credentials, call, Module.stamp()),
        body = call.body,
        -- Остаток вызова — сроком обращения: клиент HTTP режет им свой
        -- срок, и libcurl ждёт ровно до мига вызова.
        retry = { deadline = left },
    })

    if answer == nil then
        ---@cast err TntHttpFailure
        return nil, failure.http(err, { idempotent = idempotent })
    end

    if missing(call, answer) or answer:ok() and not faulted(call, answer) then
        return answer
    end

    -- Отказ в теле ответа 200 читается как 500: время его лечит, и повтор
    -- решается по согласию вызывающего.
    return nil, refusal(call, answer:ok() and 500 or answer.status, answer.body, idempotent)
end

--- Вызов целиком: один миг срока, попытки по приговору отказа.
---@param client TntS3Client
---@param call TntS3Call
---@param timeout number
---@param idempotent boolean
---@return TntHttpResponse|nil answer
---@return TntStorageFailure|nil err
function Module.run(client, call, timeout, idempotent)
    local deadline = within.deadline(timeout)
    local last = nil

    return client.retry:run(function()
        local answer, err = attempt(client, call, deadline, idempotent, last)

        last = err

        return answer, err
    end, { deadline = timeout })
end

--- Обращение к объекту.
---@param client TntS3Client
---@param method string
---@param key string
---@param headers table<string, string>|nil
---@param body string|nil
---@param params table<string, string|nil>|nil Параметры строки запроса
---@return TntS3Call
function Module.object(client, method, key, headers, body, params)
    local settings = client.settings

    headers = headers or {}
    headers.host = settings.host

    return {
        method = method,
        path = settings.root .. sign.path('/' .. key),
        query = params and sign.query(params) or '',
        headers = headers,
        body = body,
        payload = hash.digest('sha256', body or ''),
        shown = ('%s/%s'):format(settings.where, key),
    }
end

--- Кладёт объект одним PUT: аргументы уже проверены.
---@param client TntS3Client
---@param key string
---@param body string
---@param timeout number
---@param idempotent boolean
---@param headers table<string, string>
---@return TntS3Stored|nil stored
---@return TntStorageFailure|nil err
function Module.store(client, key, body, timeout, idempotent, headers)
    local answer, err = Module.run(client, Module.object(client, 'PUT', key, headers, body), timeout, idempotent)

    if answer == nil then
        return nil, err
    end

    local info = reply.info(answer.headers)

    return { etag = info.etag, version = info.version }
end

return Module
