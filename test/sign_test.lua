--- Подпись SigV4: примеры из документации AWS сходятся дословно.
---
--- Примеры — «Signature Calculations for the Authorization Header»
--- и «Query String Authentication» Amazon S3: ключ `AKIAIOSFODNN7EXAMPLE`,
--- миг `20130524T000000Z`, ведро `examplebucket`. Подпись в них посчитана
--- AWS, а не нами, — сверка с ней и есть проверка против чужого счёта.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, world = helper.group('tnt.s3.sign')

--- Свёртка пустого тела.
local EMPTY = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

--- Узел примеров AWS.
local HOST = 'examplebucket.s3.amazonaws.com'

--- Миг примеров AWS.
local STAMP = '20130524T000000Z'

--- Начало заголовка authorization у примеров AWS.
local CREDENTIAL = 'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request'

---@param overrides table|nil
---@return TntS3Credentials
local function credentials(overrides)
    return helper.web.merged({
        access_key = helper.ACCESS_KEY,
        secret_key = helper.SECRET_KEY,
        region = 'us-east-1',
    }, overrides)
end

g.test_get_object_matches_aws = function()
    local headers = world.sign.headers(credentials(), {
        method = 'GET',
        path = world.sign.path('/test.txt'),
        query = '',
        headers = { host = HOST, range = 'bytes=0-9' },
        payload = EMPTY,
    }, STAMP)

    t.assert_equals(headers, {
        host = HOST,
        range = 'bytes=0-9',
        ['x-amz-date'] = STAMP,
        ['x-amz-content-sha256'] = EMPTY,
        authorization = CREDENTIAL
            .. ', SignedHeaders=host;range;x-amz-content-sha256;x-amz-date'
            .. ', Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
    })
end

g.test_put_object_matches_aws = function()
    local headers = world.sign.headers(credentials(), {
        method = 'PUT',
        path = world.sign.path('/test$file.text'),
        query = '',
        headers = {
            host = HOST,
            date = 'Fri, 24 May 2013 00:00:00 GMT',
            ['x-amz-storage-class'] = 'REDUCED_REDUNDANCY',
        },
        payload = '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072',
    }, STAMP)

    t.assert_equals(
        headers.authorization,
        CREDENTIAL
            .. ', SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class'
            .. ', Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd'
    )
end

g.test_subresource_and_list_match_aws = function()
    local lifecycle = world.sign.headers(credentials(), {
        method = 'GET',
        path = '/',
        query = world.sign.query({ lifecycle = '' }),
        headers = { host = HOST },
        payload = EMPTY,
    }, STAMP)
    local listing = world.sign.headers(credentials(), {
        method = 'GET',
        path = '/',
        query = world.sign.query({ ['max-keys'] = '2', prefix = 'J' }),
        headers = { host = HOST },
        payload = EMPTY,
    }, STAMP)

    t.assert_str_contains(
        lifecycle.authorization,
        'Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543'
    )
    t.assert_str_contains(
        listing.authorization,
        'Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7'
    )
end

g.test_presigned_url_matches_aws = function()
    local query = world.sign.presign(credentials(), { method = 'GET', path = '/test.txt', host = HOST }, STAMP, 86400)

    t.assert_equals(
        query,
        'X-Amz-Algorithm=AWS4-HMAC-SHA256'
            .. '&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request'
            .. '&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host'
            .. '&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404'
    )
end

g.test_presign_keeps_own_params_and_token = function()
    local query = world.sign.presign(
        credentials({ session_token = 'token/7', region = 'eu-central-1' }),
        { method = 'PUT', path = '/b/k', host = HOST, params = { ['x-id'] = 'PutObject' } },
        STAMP,
        60
    )

    t.assert_str_matches(
        query,
        'X%-Amz%-Algorithm=AWS4%-HMAC%-SHA256'
            .. '&X%-Amz%-Credential=AKIAIOSFODNN7EXAMPLE%%2F20130524%%2Feu%-central%-1%%2Fs3%%2Faws4_request'
            .. '&X%-Amz%-Date=20130524T000000Z&X%-Amz%-Expires=60'
            .. '&X%-Amz%-Security%-Token=token%%2F7&X%-Amz%-SignedHeaders=host&x%-id=PutObject'
            .. '&X%-Amz%-Signature=%x+'
    )
    -- Метод входит в подпись: та же ссылка на чтение подписана иначе.
    t.assert_not_equals(
        query:match('Signature=(%x+)'),
        world.sign
            .presign(
                credentials({ session_token = 'token/7', region = 'eu-central-1' }),
                { method = 'GET', path = '/b/k', host = HOST, params = { ['x-id'] = 'PutObject' } },
                STAMP,
                60
            )
            :match('Signature=(%x+)')
    )
end

g.test_session_token_is_signed = function()
    local headers = world.sign.headers(credentials({ session_token = 'FQoG/token' }), {
        method = 'GET',
        path = '/b/k',
        query = '',
        headers = { host = 'h' },
        payload = EMPTY,
    }, STAMP)

    t.assert_equals(headers['x-amz-security-token'], 'FQoG/token')
    t.assert_str_contains(
        headers.authorization,
        'SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature='
    )
end

g.test_header_values_are_trimmed_and_collapsed = function()
    local function authorization(value)
        return world.sign.headers(credentials(), {
            method = 'GET',
            path = '/b/k',
            query = '',
            headers = { host = 'h', ['x-amz-meta-note'] = value },
            payload = EMPTY,
        }, STAMP).authorization
    end

    -- Сервер подписывает значение без пробелов по краям и с одним пробелом
    -- вместо нескольких: подпись обязана выйти той же.
    t.assert_equals(authorization('  a   b  '), authorization('a b'))
    t.assert_not_equals(authorization('a  b'), authorization('ab'))
    t.assert_equals(authorization('\ta b\n'), authorization('a b'))
    t.assert_equals(authorization('   '), authorization(''))
end

g.test_path_encodes_segments_and_keeps_slashes = function()
    t.assert_equals(world.sign.path('/b/a b+c~(1).txt'), '/b/a%20b%2Bc~%281%29.txt')
    t.assert_equals(world.sign.path('/b/проба/x'), '/b/%D0%BF%D1%80%D0%BE%D0%B1%D0%B0/x')
    t.assert_equals(world.sign.path('/b//x/'), '/b//x/')
    t.assert_equals(world.sign.path('/'), '/')
end

g.test_query_orders_by_name_not_by_pair = function()
    -- «a» раньше «a-b», хотя «a-b=1» как строка меньше «a=2».
    t.assert_equals(world.sign.query({ ['a-b'] = '1', a = '2' }), 'a=2&a-b=1')
    t.assert_equals(
        world.sign.query({ z = '', ['list-type'] = '2', prefix = 'a/b c' }),
        'list-type=2&prefix=a%2Fb%20c&z='
    )
    t.assert_equals(world.sign.query({}), '')
end

g.test_stamp_is_utc_and_drops_fraction = function()
    t.assert_equals(world.sign.stamp(helper.NOW), STAMP)
    t.assert_equals(world.sign.stamp(helper.NOW + 3661.9), '20130524T010101Z')
end
