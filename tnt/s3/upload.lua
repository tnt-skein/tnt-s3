--- Запись объекта кусками: загрузка частями (multipart upload).
---
---     local writer = bucket:writer('exports/2026-09.csv', { content_type = 'text/csv' })
---
---     for _, rows in ipairs(pages) do
---         local written, failure = writer:write(csv_of(rows))
---
---         if not written then
---             return nil, failure       -- начатая загрузка уже снята
---         end
---     end
---
---     return writer:finish()             -- { etag, version }
---
--- Одним PUT S3 берёт не больше 5 ГБ, и тело PUT — строка в памяти узла.
--- Здесь куски копятся до `part_size` и уходят частью (`UploadPart`),
--- а `finish` собирает объект из частей (`CompleteMultipartUpload`):
--- в памяти лежит одна часть, сколько бы ни весил объект.
---
--- Загрузка начинается лениво — с первой полной частью. Объект меньше
--- части уходит одним PUT в `finish`, как у `put`: лишние три обращения
--- ради маленького объекта ничего не дают.
---
--- Отказ части или сборки снимает начатую загрузку (`AbortMultipartUpload`):
--- незаконченная загрузка невидима в списке, но место в ведре занимает,
--- пока её не снимут. Писатель после отказа отвечает тем же отказом.
---
--- Повторы — у каждого обращения свои, по согласию `idempotent`: часть
--- с тем же номером заменяет прежнюю, и её повтор безвреден. Сборка
--- после отправки не повторяется никогда: сборка, дошедшая до службы,
--- снимает загрузку, и повтор ответил бы «нет такой загрузки» на удачу.

local call = require('tnt.s3.call')
local failure = require('tnt.storage.failure')
local must = require('tnt.must')
local reply = require('tnt.s3.reply')

local Module = {}

--- Часть по умолчанию: 8 МБ.
Module.PART_SIZE = 8 * 1024 * 1024

--- Самая маленькая часть: 5 МБ. Меньше S3 не принимает ни у одной части,
--- кроме последней.
Module.MIN_PART = 5 * 1024 * 1024

--- Самая большая часть: 5 ГБ.
Module.MAX_PART = 5 * 1024 * 1024 * 1024

--- Сколько частей в одной загрузке: больше S3 не принимает.
Module.MAX_PARTS = 10000

--- Настройки записи кусками.
local OPTIONS = {
    timeout = '?number',
    idempotent = '?boolean',
    content_type = '?not_empty',
    metadata = '?table',
    part_size = '?integer',
}

--- Писатель открыт и принимает куски.
local OPEN = 'open'

--- Писатель кончил: объект записан либо запись брошена.
local DONE = 'done'

--- Писатель отказал: загрузка снята, отказ хранится.
local FAILED = 'failed'

---@class TntS3WriterOptions: TntS3PutOptions Настройки записи кусками
---@field part_size integer|nil Размер части: от 5 МБ до 5 ГБ; по умолчанию 8 МБ

---@class TntS3Upload Запись объекта кусками
---@field key string Ключ объекта
---@field client TntS3Client
---@field headers table<string, string> Вид содержимого и сведения: уходят в начало загрузки
---@field timeout number
---@field idempotent boolean
---@field part_size integer
---@field pieces string[] Куски, ждущие своей части
---@field buffered integer Сколько байт в них
---@field id string|nil Опознаватель загрузки, когда она начата
---@field parts string[] Метки содержимого отправленных частей по номерам
---@field state string open, done либо failed
---@field failure TntStorageFailure|nil
local Upload = {}
Upload.__index = Upload

--- Открывает запись объекта кусками. В сеть не ходит: загрузка начнётся
--- с первой полной частью.
---@param client TntS3Client
---@param key any
---@param opts TntS3WriterOptions|nil
---@param level integer Уровень вины в кадрах того, кто зовёт
---@return TntS3Upload
function Module.open(client, key, opts, level)
    call.check_key(key, level + 1)

    local timeout, idempotent = call.options(client, opts, OPTIONS, level + 1)
    local given = opts or {}
    local part_size = given.part_size or Module.PART_SIZE

    must.at(level + 1).between(part_size, 'part_size', Module.MIN_PART, Module.MAX_PART)

    return setmetatable({
        key = key,
        client = client,
        headers = call.put_headers(given, level + 1),
        timeout = timeout,
        idempotent = idempotent,
        part_size = part_size,
        pieces = {},
        buffered = 0,
        parts = {},
        state = OPEN,
    }, Upload)
end

--- Бросает, если писатель кончил: запись после `finish` или `abort` —
--- ошибка программиста.
---@param upload TntS3Upload
---@param action string
local function check_open(upload, action)
    if upload.state == DONE then
        error(('%s: писатель объекта %s уже закончен'):format(action, upload.key), 3)
    end
end

--- Обращение к загрузке: параметры строки запроса несут её опознаватель.
---@param upload TntS3Upload
---@param method string
---@param params table<string, string|nil>
---@param body string|nil
---@param headers table<string, string>|nil
---@return TntS3Call
local function to_upload(upload, method, params, body, headers)
    return call.object(upload.client, method, upload.key, headers, body, params)
end

--- Снимает начатую загрузку. Отказ снятия — пара: загрузка осталась
--- и занимает место, пока её не снимет правило жизненного цикла ведра.
---@param upload TntS3Upload
---@return true|nil ok
---@return TntStorageFailure|nil err
local function cancel(upload)
    local answer, err =
        call.run(upload.client, to_upload(upload, 'DELETE', { uploadId = upload.id }), upload.timeout, true)

    if answer == nil then
        return nil, err
    end

    return true
end

--- Кончает запись отказом: начатая загрузка снимается, отказ хранится.
---
--- Отказ снятия не заслоняет причину: вызывающему важнее, почему запись
--- не удалась, чем то, что за ней не убрали.
---@param upload TntS3Upload
---@param err any Отказ: у удачной на вид попытки его не бывает
---@return nil
---@return TntStorageFailure
local function fail(upload, err)
    if upload.id ~= nil then
        cancel(upload)
    end

    upload.state = FAILED
    upload.failure = err

    return nil, err
end

--- Начинает загрузку: служба выдаёт её опознаватель.
---@param upload TntS3Upload
---@return true|nil ok
---@return TntStorageFailure|nil err
local function begin(upload)
    local headers = table.copy(upload.headers)
    local started = to_upload(upload, 'POST', { uploads = '' }, nil, headers)
    local answer, err = call.run(upload.client, started, upload.timeout, upload.idempotent)

    if answer == nil then
        return nil, err
    end

    upload.id = reply.upload_id(answer.body)

    if upload.id == nil then
        return nil,
            failure.new(
                failure.BROKEN,
                ('POST %s: служба не назвала опознаватель загрузки'):format(
                    started.shown
                ),
                { idempotent = false }
            )
    end

    return true
end

--- Отправляет накопленное частью.
---@param upload TntS3Upload
---@return true|nil ok
---@return TntStorageFailure|nil err
local function send(upload)
    local number = #upload.parts + 1

    if number > Module.MAX_PARTS then
        return fail(
            upload,
            failure.new(
                failure.REJECTED,
                ('%s: частей больше %d — возьмите part_size больше'):format(
                    upload.key,
                    Module.MAX_PARTS
                )
            )
        )
    end

    if upload.id == nil then
        local started, err = begin(upload)

        if not started then
            return fail(upload, err)
        end
    end

    local body = table.concat(upload.pieces)

    upload.pieces = {}
    upload.buffered = 0

    local part = to_upload(upload, 'PUT', { partNumber = tostring(number), uploadId = upload.id }, body)
    local answer, err = call.run(upload.client, part, upload.timeout, upload.idempotent)

    if answer == nil then
        return fail(upload, err)
    end

    local etag = reply.info(answer.headers).etag

    -- Без метки часть не назвать в сборке, а сборка без неё собрала бы
    -- объект без части.
    if etag == nil then
        return fail(
            upload,
            failure.new(
                failure.BROKEN,
                ('PUT %s: служба не назвала метку части %d'):format(part.shown, number),
                { idempotent = false }
            )
        )
    end

    upload.parts[number] = etag

    return true
end

--- Дописывает кусок: полная часть уходит службе.
---@param chunk string
---@return true|nil ok
---@return TntStorageFailure|nil err
function Upload:write(chunk)
    must.at(2).string(chunk, 'кусок')
    check_open(self, 'write')

    if self.state == FAILED then
        return nil, self.failure
    end

    table.insert(self.pieces, chunk)
    self.buffered = self.buffered + #chunk

    if self.buffered < self.part_size then
        return true
    end

    return send(self)
end

--- Тело сборки: номера частей и их метки содержимого по порядку.
---@param parts string[]
---@return string
local function manifest(parts)
    local lines = { '<CompleteMultipartUpload>' }

    for number, etag in ipairs(parts) do
        table.insert(lines, ('<Part><PartNumber>%d</PartNumber><ETag>"%s"</ETag></Part>'):format(number, etag))
    end

    table.insert(lines, '</CompleteMultipartUpload>')

    return table.concat(lines)
end

--- Кончает запись: остаток уходит последней частью, служба собирает объект.
---
--- Загрузка не начата — объект меньше части и уходит одним PUT.
---@return TntS3Stored|nil stored Метка содержимого и версия
---@return TntStorageFailure|nil err
function Upload:finish()
    check_open(self, 'finish')

    if self.state == FAILED then
        return nil, self.failure
    end

    if self.id == nil then
        local body = table.concat(self.pieces)
        local stored, err = call.store(self.client, self.key, body, self.timeout, self.idempotent, self.headers)

        self.state = err and FAILED or DONE
        self.failure = err

        return stored, err
    end

    if self.buffered > 0 then
        local sent, err = send(self)

        if not sent then
            return nil, err
        end
    end

    local assemble = to_upload(
        self,
        'POST',
        { uploadId = self.id },
        manifest(self.parts),
        { ['content-type'] = 'application/xml' }
    )

    assemble.confirm = true

    local answer, err = call.run(self.client, assemble, self.timeout, false)

    if answer == nil then
        return fail(self, err)
    end

    self.state = DONE

    return reply.confirmed(answer.body, answer.headers)
end

--- Бросает запись: начатая загрузка снимается, объекта не будет.
---
--- Звать можно при всяком исходе и сколько угодно раз: после отказа
--- и после `finish` — ничего не делает. Отказ самого снятия — пара.
---@return true|nil ok
---@return TntStorageFailure|nil err
function Upload:abort()
    local started = self.state == OPEN and self.id ~= nil

    self.state = DONE

    if started then
        return cancel(self)
    end

    return true
end

return Module
