--- Файл в объект и объект в файл кусками: `put_file` и `get_file` драйвера.
---
--- Файл читает и пишет `tnt-fs` кусками, объект уходит загрузкой частями
--- (`tnt.s3.upload`) и приходит запросами с диапазоном (`tnt.s3.download`),
--- а переливает одно в другое `fs.pipe`: в памяти узла лежит одна часть,
--- сколько бы ни весил файл. Файл, забранный из ведра, подменяется целиком
--- в конце — читающий видит либо старый файл, либо новый.
---
--- Отказ файла — отказ `tnt-fs` как есть (`missing`, `denied`, `full`…),
--- а не `TntStorageFailure`: до хранилища дело не дошло либо дошло
--- удачно, и род файла вызывающему нужнее рода хранилища. Отличает их
--- `storage.failure.is(err)`.

local fs = require('tnt.fs')
local must = require('tnt.must')

local download = require('tnt.s3.download')
local upload = require('tnt.s3.upload')

local Module = {}

--- Кладёт файл объектом, кусками.
---
--- Файл меньше части уходит одним PUT, больше — загрузкой частями.
---@param client TntS3Client
---@param key string
---@param path string Путь к файлу
---@param opts TntS3WriterOptions|nil
---@return TntS3Stored|nil stored
---@return TntStorageFailure|TntFsFailure|nil err
function Module.put_file(client, key, path, opts)
    local writer = upload.open(client, key, opts, 2)

    must.at(2).string(path, 'путь')

    local reader, err = fs.reader(path)

    if reader == nil then
        -- Загрузка ещё не начата: в сеть бросание не ходит.
        writer:abort()

        return nil, err
    end

    return fs.pipe(reader, writer)
end

--- Забирает объект в файл, кусками: файл подменяется целиком в конце.
---
--- Объекта нет — `nil` без отказа, и файл не тронут.
---@param client TntS3Client
---@param key string
---@param path string Путь к файлу
---@param opts TntS3ReaderOptions|nil
---@return TntS3Info|nil info Сведения о записанном объекте
---@return TntStorageFailure|TntFsFailure|nil err
function Module.get_file(client, key, path, opts)
    must.at(2).string(path, 'путь')

    local reader, err = download.open(client, key, opts, 2)

    if reader == nil then
        return nil, err
    end

    local writer, unwritten = fs.writer(path)

    if writer == nil then
        reader:close()

        return nil, unwritten
    end

    local done, failed = fs.pipe(reader, writer)

    if not done then
        return nil, failed
    end

    return reader.info
end

return Module
