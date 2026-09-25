rockspec_format = '3.0'

package = 'tnt-s3'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-s3.git',
    branch = 'main',
}

description = {
    summary = 'Клиент S3 для Tarantool: подпись SigV4, объект целиком, список, ссылки, срок, повторы и отказ парой',
    detailed = [[
        Готового клиента S3 у Tarantool нет ни в ядре, ни среди
        официальных роков, а клиенты с luarocks.org ходят в сеть мимо
        файберов и останавливают узел целиком. Своего в пакете немного:
        подпись запросов AWS Signature Version 4 и чтение ответов S3.
        HTTP — libcurl со своим кэшем соединений, HMAC и свёртки,
        файлы, срок, отказ и повторы взяты готовыми.

        Драйвер привязан к одному ведру: put, get, head и delete объекта
        целиком, копия силами службы, чтение кусками запросами с Range
        и If-Match, запись кусками загрузкой частями, страница списка
        ListObjectsV2 с меткой продолжения, ссылка с подписью на GET или
        PUT для того, у кого ключа нет, файл в объект и объект в файл
        кусками с атомарной подменой файла. Сведения
        об объекте одного вида из заголовков и из списка: время —
        datetime в UTC, метка содержимого — без кавычек. Промах — nil
        без отказа, нет ведра — отказ. Транзакций нет
        (features.transaction = false). Работает с AWS, MinIO и всякой
        службой, которая понимает SigV4 и адресацию ведра путём.

        Отказ — пара nil, err с родом по коду ответа и словам libcurl,
        признаком отправки и приговором повтору; код S3 — в server_code.
        Срок один на вызов: попытки и паузы между ними — остатки одного
        мига. Повторяет драйвер, а не клиент HTTP, и все действия
        идемпотентны, поэтому обрыв после отправки повторяется без
        просьбы; несогласный ставит idempotent = false. Каждая попытка
        подписывается заново.

        Зависит от tnt-must (проверки аргументов), tnt-clock (часы
        подписи), tnt-date (время из ответа), tnt-fs (файлы), tnt-hash
        (HMAC и свёртки), tnt-http (запросы через libcurl), tnt-retry
        (повторы), tnt-external (подмена часов в проверках) и tnt-storage
        (срок и отказ с родом). Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-s3',
    issues_url = 'https://github.com/tnt-skein/tnt-s3/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 's3', 'sigv4', 'storage', 'driver', 'http' },
}

dependencies = {
    'lua >= 5.1',
    -- Проверки настроек, ключа и аргументов на строке вызывающего.
    'tnt-must',
    -- Стенные часы мига подписи: S3 сверяет его со своими.
    'tnt-clock',
    -- Время из ответа: HTTP-дата заголовков и ISO 8601 списка.
    'tnt-date',
    -- Файл в объект и объект в файл кусками, с атомарной подменой файла.
    'tnt-fs',
    -- HMAC-SHA256 подписи и свёртки тела.
    'tnt-hash',
    -- Запросы к службе и кодирование пути и параметров.
    'tnt-http',
    -- Повторы вызова по полю retriable отказа.
    'tnt-retry',
    -- Подмена часов подписи в проверках.
    'tnt-external',
    -- Срок вызова и отказ с родом по коду ответа.
    'tnt-storage',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.s3'] = 'tnt/s3.lua',
        ['tnt.s3.call'] = 'tnt/s3/call.lua',
        ['tnt.s3.download'] = 'tnt/s3/download.lua',
        ['tnt.s3.reply'] = 'tnt/s3/reply.lua',
        ['tnt.s3.settings'] = 'tnt/s3/settings.lua',
        ['tnt.s3.sign'] = 'tnt/s3/sign.lua',
        ['tnt.s3.transfer'] = 'tnt/s3/transfer.lua',
        ['tnt.s3.upload'] = 'tnt/s3/upload.lua',
        ['tnt.s3.xml'] = 'tnt/s3/xml.lua',
    },
}
