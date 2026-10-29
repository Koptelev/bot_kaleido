-- Бот «Калейдоскоп вопросов» для Supabase. Собрано из репозитория игры (migrations/001, 002, 004, 005).
-- Идемпотентно: можно запускать повторно (SQL Editor → Run). Данные не теряются.

-- ===== 001_schema =====
-- Калейдоскоп вопросов: схема kaleido.
-- Идемпотентно: можно запускать сколько угодно раз. Другие схемы базы не трогает,
-- все имена квалифицированы, search_path не меняется.

create schema if not exists kaleido;

-- Настройки игры. Меняются запросом update, перезапуск не нужен.
create table if not exists kaleido.config (
  key    text primary key,
  value  text not null
);
insert into kaleido.config (key, value) values
  ('guest_allowed', 'true'),          -- вход без кода приглашения
  ('replay_allowed', 'true'),         -- можно ли начать заново после финиша
  ('session_days', '60'),             -- сколько живёт вход
  ('telegram_webapp_secret', ''),     -- производный ключ Telegram (npm run tg:secret), НЕ токен бота
  ('telegram_max_age', '86400')       -- сколько секунд действительна подпись Telegram
on conflict (key) do nothing;

-- Участники. provider: guest — без кода, code — по коду приглашения, telegram — через бота.
create table if not exists kaleido.players (
  id            uuid primary key default gen_random_uuid(),
  provider      text not null check (provider in ('guest', 'code', 'telegram')),
  external_id   text,                     -- id пользователя Telegram
  code_hash     text unique,              -- sha256 кода приглашения (сам код не храним)
  name          text,
  attendance    text check (attendance in ('online', 'offline')),
  is_test       boolean not null default false,
  created_at    timestamptz not null default now(),
  activated_at  timestamptz,
  last_seen_at  timestamptz not null default now()
);
create unique index if not exists players_provider_external
  on kaleido.players (provider, external_id) where external_id is not null;

-- Входы. Храним только sha256 токена. Один участник может войти с нескольких устройств.
create table if not exists kaleido.sessions (
  token_hash  text primary key,
  player_id   uuid not null references kaleido.players (id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null
);
create index if not exists sessions_player on kaleido.sessions (player_id);

-- Вопросы. Наполняются из 003_questions.sql (собирается из data/questions.json).
create table if not exists kaleido.questions (
  id              text primary key,
  position        int,
  kind            text not null check (kind in ('choice', 'open')),
  topic           text not null default '',
  prompt          text not null,
  options         jsonb,
  correct_option  int,
  points          int not null default 10,
  active          boolean not null default true,
  updated_at      timestamptz not null default now(),
  constraint questions_position_uniq unique (position) deferrable initially deferred,
  constraint questions_choice_valid check (kind = 'open' or (options is not null and correct_option is not null))
);

-- Партии. question_ids — снимок порядка вопросов на момент старта.
create table if not exists kaleido.games (
  id            uuid primary key default gen_random_uuid(),
  player_id     uuid not null references kaleido.players (id) on delete cascade,
  seed          bigint not null,
  question_ids  jsonb not null,
  total         int not null,
  status        text not null default 'active' check (status in ('active', 'finished', 'abandoned')),
  score         int not null default 0,
  correct       int not null default 0,
  answered      int not null default 0,
  created_at    timestamptz not null default now(),
  finished_at   timestamptz
);
create unique index if not exists games_one_active_per_player on kaleido.games (player_id) where status = 'active';
create index if not exists games_player on kaleido.games (player_id, created_at desc);

-- Ответы. Один ответ на вопрос в партии: открытый ответ переписать нельзя.
create table if not exists kaleido.answers (
  id             bigserial primary key,
  game_id        uuid not null references kaleido.games (id) on delete cascade,
  question_id    text not null references kaleido.questions (id),
  position       int not null,
  kind           text not null,
  option_index   int,
  is_correct     boolean,
  text_answer    text,
  text_length    int,
  share_consent  boolean not null default false,
  points         int not null,
  created_at     timestamptz not null default now(),
  unique (game_id, question_id),
  unique (game_id, position)
);
create index if not exists answers_question on kaleido.answers (question_id);

select jsonb_build_object('ok', true, 'step', '001_schema') as result;

-- ===== 002_api =====
-- Калейдоскоп вопросов: вся логика игры в одной функции kaleido.api(запрос jsonb) → ответ jsonb.
-- Её вызывает и вебхук n8n, и сервер Node.js — поведение одинаковое.
-- Только встроенные функции PostgreSQL 13+ (sha256, gen_random_uuid), расширения не нужны.
--
-- Запрос: {"action": "...", "token": "...", ...}. Ошибка: {"error": {"code", "message", "retryable"}}.

create or replace function kaleido.sha(t text) returns text
language sql immutable as $$ select encode(sha256(convert_to(t, 'UTF8')), 'hex') $$;

create or replace function kaleido.err(code text, message text, retryable boolean default false)
returns jsonb language sql immutable as $$
  select jsonb_build_object('error', jsonb_build_object('code', code, 'message', message, 'retryable', retryable))
$$;

create or replace function kaleido.cfg(k text, def text default '') returns text
language sql stable as $$ select coalesce((select value from kaleido.config where key = k), def) $$;

-- HMAC-SHA256 на встроенной sha256 (pgcrypto не нужен). Для проверки подписи Telegram.
create or replace function kaleido.hmac_sha256(k bytea, m bytea) returns bytea
language plpgsql immutable as $$
declare kp bytea; ipad bytea; opad bytea; i int;
begin
  if length(k) > 64 then k := sha256(k); end if;
  kp := k || decode(repeat('00', 64 - length(k)), 'hex');
  ipad := kp; opad := kp;
  for i in 0..63 loop
    ipad := set_byte(ipad, i, get_byte(kp, i) # 54);
    opad := set_byte(opad, i, get_byte(kp, i) # 92);
  end loop;
  return sha256(opad || sha256(ipad || m));
end $$;

-- lower() в базе с локалью C не трогает кириллицу — переводим явно.
create or replace function kaleido.lower_ru(t text) returns text
language sql immutable as $$
  select translate(lower(t), 'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ', 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя')
$$;

-- Баллы за открытый ответ: чем развёрнутее и содержательнее, тем больше. Формулу участникам не показываем.
--   эффективная длина < 15 → 10 % от максимума, 15+ → 25 %, 50+ → 50 %, 130+ → 75 %, 240+ → 100 %.
-- Повторы символов («ааааа») схлопываются, при бедном словаре длина урезается.
create or replace function kaleido.score_open(raw text, max_points int)
returns table (points int, clean text, text_length int)
language plpgsql immutable as $$
declare
  c text; sq text; letters int; nwords int; nunique int; diversity numeric; eff numeric; frac numeric;
begin
  c := btrim(regexp_replace(coalesce(raw, ''), '\s+', ' ', 'g'));
  if c = '' then points := 0; clean := ''; text_length := 0; return next; return; end if;
  sq := regexp_replace(c, '(.)\1{2,}', '\1\1', 'g');
  letters := length(regexp_replace(sq, '[^A-Za-zА-Яа-яЁё]', '', 'g'));
  select count(*), count(distinct w) into nwords, nunique
    from regexp_split_to_table(kaleido.lower_ru(sq), '[^a-zа-яё0-9]+') as w where length(w) >= 2;
  diversity := case when nwords > 0 then nunique::numeric / nwords else 0 end;
  eff := letters * least(1, 0.35 + diversity);
  if nunique < 3 then eff := least(eff, 14); end if;
  frac := case when eff >= 240 then 1 when eff >= 130 then 0.75 when eff >= 50 then 0.5 when eff >= 15 then 0.25 else 0.1 end;
  points := greatest(1, round(max_points * frac))::int;
  clean := c; text_length := length(c);
  return next;
end $$;

-- Выдать вход участнику.
create or replace function kaleido.new_session(p_player uuid) returns jsonb
language plpgsql as $$
declare v_token text; p kaleido.players;
begin
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into kaleido.sessions (token_hash, player_id, expires_at)
  values (kaleido.sha(v_token), p_player, now() + make_interval(days => kaleido.cfg('session_days', '60')::int));
  update kaleido.players set last_seen_at = now() where id = p_player returning * into p;
  return jsonb_build_object('token', v_token, 'player',
    jsonb_build_object('id', p.id, 'provider', p.provider, 'name', p.name, 'is_test', p.is_test));
end $$;

-- Создать участника с кодом приглашения (организаторы, через консоль n8n):
--   select kaleido.create_player('Анна Иванова', 'KALEIDO-7F3K');
create or replace function kaleido.create_player(p_name text, p_code text, p_test boolean default false, p_attendance text default null)
returns uuid language sql as $$
  insert into kaleido.players (provider, name, code_hash, is_test, attendance)
  values ('code', p_name, kaleido.sha(upper(btrim(p_code))), p_test, p_attendance)
  returning id
$$;

create or replace function kaleido.create_game(p_player uuid) returns kaleido.games
language plpgsql as $$
declare v_ids jsonb; g kaleido.games;
begin
  select coalesce(jsonb_agg(id order by position), '[]'::jsonb) into v_ids from kaleido.questions where active;
  if jsonb_array_length(v_ids) = 0 then raise exception 'В базе нет вопросов: выполните 003_questions'; end if;
  insert into kaleido.games (player_id, seed, question_ids, total)
  values (p_player, 1 + floor(random() * 2147483646)::bigint, v_ids, jsonb_array_length(v_ids))
  returning * into g;
  return g;
end $$;

-- Состояние партии для фронтенда. Правильные ответы сюда не попадают.
create or replace function kaleido.game_payload(g kaleido.games) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'game', jsonb_build_object('id', g.id, 'seed', g.seed, 'status', g.status, 'score', g.score,
      'correct', g.correct, 'answered', g.answered, 'total', g.total),
    'questions', (
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id', q.id, 'kind', q.kind, 'topic', q.topic, 'prompt', q.prompt,
        'options', case when q.kind = 'choice' then q.options end, 'points', q.points)) order by x.ord), '[]'::jsonb)
      from jsonb_array_elements_text(g.question_ids) with ordinality as x(qid, ord)
      join kaleido.questions q on q.id = x.qid),
    'answers', (
      select coalesce(jsonb_agg(jsonb_build_object('position', a.position, 'kind', a.kind,
        'isCorrect', a.is_correct, 'points', a.points) order by a.position), '[]'::jsonb)
      from kaleido.answers a where a.game_id = g.id),
    'allowReplay', kaleido.cfg('replay_allowed', 'true') = 'true')
$$;

create or replace function kaleido.api(b jsonb) returns jsonb
language plpgsql as $$
declare
  act text := coalesce(b->>'action', '');
  p kaleido.players;
  g kaleido.games;
  q kaleido.questions;
  v_hash text; v_calc text; v_secret text; v_user jsonb; v_name text;
  v_expected text; v_ok boolean; v_points int; v_text text; v_len int; v_opt int;
  v_answered int; v_finished boolean;
begin
  -- ---------- без входа ----------
  if act = 'health' then
    return jsonb_build_object('ok', true, 'questions', (select count(*) from kaleido.questions where active));
  end if;

  if act = 'config' then
    return jsonb_build_object('guest', kaleido.cfg('guest_allowed') = 'true',
      'telegram', kaleido.cfg('telegram_webapp_secret') <> '', 'allowReplay', kaleido.cfg('replay_allowed') = 'true',
      -- отпечаток ключа (8 символов sha256): по нему страница настройки бота сверяет, от того ли он токена
      'telegramKeyId', case when kaleido.cfg('telegram_webapp_secret') <> ''
        then left(encode(sha256(convert_to(kaleido.cfg('telegram_webapp_secret'), 'UTF8')), 'hex'), 8) end);
  end if;

  if act = 'auth_guest' then
    if kaleido.cfg('guest_allowed', 'true') <> 'true' then
      return kaleido.err('GUEST_DISABLED', 'Вход по коду приглашения');
    end if;
    insert into kaleido.players (provider, attendance)
    values ('guest', case when b->>'attendance' in ('online', 'offline') then b->>'attendance' end)
    returning * into p;
    return kaleido.new_session(p.id);
  end if;

  if act = 'activate' then
    select * into p from kaleido.players
      where code_hash = kaleido.sha(upper(btrim(coalesce(b->>'code', '')))) and provider = 'code';
    if not found then return kaleido.err('INVALID_CODE', 'Такого кода нет. Проверь, нет ли опечатки.'); end if;
    update kaleido.players set activated_at = coalesce(activated_at, now()) where id = p.id;
    return kaleido.new_session(p.id);
  end if;

  -- Подпись Telegram. Строку для проверки (tg.dcs) собирает вызывающая сторона из initData,
  -- подпись проверяется здесь производным ключом. Токен бота в базе не хранится.
  if act = 'auth_telegram' then
    v_secret := kaleido.cfg('telegram_webapp_secret');
    if v_secret !~ '^[0-9a-fA-F]{64}$' then return kaleido.err('TELEGRAM_DISABLED', 'Вход через Telegram не настроен'); end if;
    v_hash := lower(coalesce(b#>>'{tg,hash}', ''));
    if v_hash !~ '^[0-9a-f]{64}$' or coalesce(b#>>'{tg,dcs}', '') = '' then
      return kaleido.err('BAD_INIT_DATA', 'Не удалось подтвердить вход через Telegram');
    end if;
    v_calc := encode(kaleido.hmac_sha256(decode(v_secret, 'hex'), convert_to(b#>>'{tg,dcs}', 'UTF8')), 'hex');
    if v_calc <> v_hash then return kaleido.err('BAD_INIT_DATA', 'Не удалось подтвердить вход через Telegram'); end if;
    if coalesce((b#>>'{tg,auth_date}')::bigint, 0) < extract(epoch from now()) - kaleido.cfg('telegram_max_age', '86400')::bigint then
      return kaleido.err('BAD_INIT_DATA', 'Вход устарел — открой игру из бота заново');
    end if;
    v_user := (b#>>'{tg,user}')::jsonb;
    if v_user->>'id' is null then return kaleido.err('BAD_INIT_DATA', 'Не удалось подтвердить вход через Telegram'); end if;
    v_name := nullif(btrim(concat_ws(' ', v_user->>'first_name', v_user->>'last_name')), '');
    insert into kaleido.players (provider, external_id, name, activated_at)
    values ('telegram', v_user->>'id', coalesce(v_name, v_user->>'username'), now())
    on conflict (provider, external_id) where external_id is not null
    do update set name = excluded.name, last_seen_at = now()
    returning * into p;
    return kaleido.new_session(p.id);
  end if;

  -- ---------- дальше только с входом ----------
  select pl.* into p from kaleido.sessions s join kaleido.players pl on pl.id = s.player_id
    where s.token_hash = kaleido.sha(coalesce(b->>'token', '')) and s.expires_at > now();
  if not found then return kaleido.err('AUTH_REQUIRED', 'Нужно войти заново'); end if;

  if act = 'me' then
    return jsonb_build_object('player', jsonb_build_object('id', p.id, 'provider', p.provider, 'name', p.name, 'is_test', p.is_test));
  end if;

  if act = 'game' then
    select * into g from kaleido.games where player_id = p.id and status in ('active', 'finished')
      order by (status = 'active') desc, created_at desc limit 1;
    if not found then
      begin
        g := kaleido.create_game(p.id);
      exception when unique_violation then
        select * into g from kaleido.games where player_id = p.id and status = 'active';
      end;
    end if;
    return kaleido.game_payload(g);
  end if;

  if act = 'new_game' then
    if kaleido.cfg('replay_allowed', 'true') <> 'true' and not p.is_test
       and exists (select 1 from kaleido.games where player_id = p.id and status = 'finished') then
      return kaleido.err('REPLAY_DISABLED', 'Повторная игра выключена организаторами');
    end if;
    update kaleido.games set status = 'abandoned' where player_id = p.id and status = 'active';
    g := kaleido.create_game(p.id);
    return kaleido.game_payload(g);
  end if;

  if act = 'answer' then
    select * into g from kaleido.games where id::text = coalesce(b->>'game_id', '') and player_id = p.id for update;
    if not found then return kaleido.err('GAME_NOT_FOUND', 'Партия не найдена'); end if;
    if g.status <> 'active' then return kaleido.err('GAME_FINISHED', 'Партия уже завершена'); end if;
    v_expected := g.question_ids->>g.answered;
    if v_expected is distinct from b->>'question_id' then
      return kaleido.err('OUT_OF_ORDER', 'Игра открыта в другом окне — обновляю');
    end if;
    select * into q from kaleido.questions where id = v_expected;

    if q.kind = 'choice' then
      if coalesce(jsonb_typeof(b->'option_index'), '') <> 'number' then return kaleido.err('BAD_OPTION', 'Выбери вариант ответа'); end if;
      v_opt := (b->>'option_index')::int;
      if v_opt < 0 or v_opt >= jsonb_array_length(q.options) then return kaleido.err('BAD_OPTION', 'Выбери вариант ответа'); end if;
      v_ok := v_opt = q.correct_option;
      v_points := case when v_ok then q.points else 0 end;
    else
      if length(coalesce(b->>'text', '')) > 3000 then return kaleido.err('TOO_LONG', 'Ответ слишком длинный: до 3000 символов'); end if;
      select s.points, s.clean, s.text_length into v_points, v_text, v_len from kaleido.score_open(b->>'text', q.points) s;
      if v_text = '' then return kaleido.err('EMPTY_TEXT', 'Напиши хотя бы пару слов'); end if;
    end if;

    begin
      insert into kaleido.answers (game_id, question_id, position, kind, option_index, is_correct,
        text_answer, text_length, share_consent, points)
      values (g.id, q.id, g.answered + 1, q.kind, v_opt, v_ok, v_text, v_len,
        q.kind = 'open' and coalesce((b->>'share_consent')::boolean, false), v_points);
    exception when unique_violation then
      return kaleido.err('ALREADY_ANSWERED', 'Ответ уже принят');
    end;

    v_answered := g.answered + 1;
    v_finished := v_answered >= g.total;
    update kaleido.games set answered = v_answered, score = score + v_points,
      correct = correct + case when v_ok then 1 else 0 end,
      status = case when v_finished then 'finished' else status end,
      finished_at = case when v_finished then now() else finished_at end
    where id = g.id returning * into g;

    return jsonb_strip_nulls(jsonb_build_object(
      'kind', q.kind, 'isCorrect', v_ok,
      'correctOptionIndex', case when q.kind = 'choice' then q.correct_option end,
      'points', v_points, 'maxPoints', q.points,
      'score', g.score, 'answered', g.answered, 'finished', g.status = 'finished'));
  end if;

  return kaleido.err('UNKNOWN_ACTION', 'Неизвестное действие');
end $$;

select jsonb_build_object('ok', true, 'step', '002_api') as result;

-- ===== 004_bot =====
-- Бот Telegram: вся логика в kaleido.bot(запрос) → один метод Bot API, который n8n отдаёт
-- Telegram в ответе на вебхук. Токен бота для ответов не нужен.
-- Рассылки (kaleido.bot_due) отправляет n8n Telegram-нодой с credential «Telegram API».
-- Тексты и программа — в kaleido.bot_content (005_bot_content.sql из data/bot.json).
-- Идемпотентно.

insert into kaleido.config (key, value) values
  ('webapp_url', 'https://kaleidoscope-36408a.gitlab-pages.kontur.host/'),  -- адрес игры (GitLab Pages)
  ('bot_images_base', ''),            -- пусто = webapp_url + 'bot/'
  ('bot_webhook_secret', ''),         -- задаёт Kaleido_Telegram_Setup, сверяется с заголовком Telegram
  ('bot_admins', ''),                 -- user_id через запятую: им доступна /stats
  ('reminder_minutes', '10'),         -- за сколько минут напоминать о блоках с notify
  ('program_reminders', 'true'),
  ('bot_score_mode', 'game')          -- game: счёт из таблиц игры; link: бот без базы игры (Supabase) — кнопка в игру
on conflict (key) do nothing;

create table if not exists kaleido.bot_content (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now()
);

-- Все, кто писал боту. Рассылки — только subscribed и не blocked.
create table if not exists kaleido.bot_chats (
  chat_id       bigint primary key,
  user_id       bigint,
  name          text,
  username      text,
  subscribed    boolean not null default true,
  blocked       boolean not null default false,
  started_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);

-- Оценки (кнопки ★1…★5 в рассылке «оцените доклад»). topic — что оцениваем.
create table if not exists kaleido.bot_ratings (
  topic       text not null,
  chat_id     bigint not null,
  stars       int not null check (stars between 1 and 5),
  created_at  timestamptz not null default now(),
  primary key (topic, chat_id)
);

-- Рассылки. kind: message — текст + картинка + кнопка «Играть»; rating — вопрос + кнопки ★1…★5.
-- audience: all, not_started (не открывали игру), unfinished (бросили на середине), finished.
create table if not exists kaleido.bot_broadcasts (
  id           bigserial primary key,
  kind         text not null default 'message' check (kind in ('message', 'rating')),
  text         text not null,
  image        text,                      -- имя картинки из public/bot/ или полный https-адрес
  button_text  text,                      -- для message; пусто — «🎮 Играть»
  topic        text,                      -- для rating
  audience     text not null default 'all' check (audience in ('all', 'not_started', 'unfinished', 'finished')),
  send_at      timestamptz not null default now(),
  sent_at      timestamptz,
  sent_count   int,
  created_at   timestamptz not null default now()
);
create index if not exists bot_broadcasts_due on kaleido.bot_broadcasts (send_at) where sent_at is null;

-- Какие напоминания о программе уже ушли.
create table if not exists kaleido.bot_program_sent (
  item_key  text primary key,
  sent_at   timestamptz not null default now()
);

-- ---------- помощники ----------

create or replace function kaleido.esc(t text) returns text
language sql immutable as $$ select replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') $$;

create or replace function kaleido.bot_c() returns jsonb
language sql stable as $$ select coalesce((select value from kaleido.bot_content where key = 'content'), '{}'::jsonb) $$;

-- Текст из data/bot.json с подстановкой {переменных}.
create or replace function kaleido.bot_t(k text, vars jsonb default '{}'::jsonb) returns text
language plpgsql stable as $$
declare t text := coalesce(kaleido.bot_c()#>>array['texts', k], ''); r record;
begin
  for r in select key, value from jsonb_each_text(vars || jsonb_build_object(
      'date_text', kaleido.bot_c()#>>'{conference,date_text}',
      'timezone_text', kaleido.bot_c()#>>'{conference,timezone_text}')) loop
    t := replace(t, '{' || r.key || '}', coalesce(r.value, ''));
  end loop;
  return t;
end $$;

create or replace function kaleido.plural(n bigint, one text, few text, many text) returns text
language sql immutable as $$
  select n || ' ' || case
    when n % 10 = 1 and n % 100 <> 11 then one
    when n % 10 between 2 and 4 and n % 100 not between 12 and 14 then few
    else many end
$$;

create or replace function kaleido.bot_img(name text) returns text
language sql stable as $$
  select case
    when coalesce(name, '') = '' then null
    when name ~ '^https://' then name
    else coalesce(nullif(kaleido.cfg('bot_images_base'), ''), kaleido.cfg('webapp_url') || 'bot/') || name
  end
$$;

-- Программа с настоящими временами начала и конца.
create or replace function kaleido.bot_items()
returns table (n int, time_text text, starts timestamptz, ends timestamptz, icon text, title text, note text, notify boolean)
language sql stable as $$
  with c as (select kaleido.bot_c() as c)
  select x.ord::int, x.item->>'time',
    ((c.c#>>'{conference,date}')::date + split_part(x.item->>'time', '–', 1)::time) at time zone (c.c#>>'{conference,timezone}'),
    ((c.c#>>'{conference,date}')::date + split_part(x.item->>'time', '–', 2)::time) at time zone (c.c#>>'{conference,timezone}'),
    coalesce(x.item->>'icon', '•'), x.item->>'title', x.item->>'note', coalesce((x.item->>'notify')::boolean, false)
  from c, jsonb_array_elements(c.c->'program') with ordinality as x(item, ord)
$$;

-- Нижняя клавиатура: главное меню.
create or replace function kaleido.bot_keyboard() returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'keyboard', jsonb_build_array(
      jsonb_build_array(jsonb_build_object('text', '🎮 Играть в калейдоскоп', 'web_app', jsonb_build_object('url', kaleido.cfg('webapp_url')))),
      jsonb_build_array(jsonb_build_object('text', '🗓 Программа'), jsonb_build_object('text', '⏱ Что сейчас')),
      jsonb_build_array(jsonb_build_object('text', '✨ О конференции'), jsonb_build_object('text', '⭐ Мой счёт')),
      jsonb_build_array(jsonb_build_object('text', '🎯 Как играть'), jsonb_build_object('text', '❓ Помощь'))),
    'resize_keyboard', true, 'is_persistent', true, 'input_field_placeholder', 'Выбери раздел')
$$;

create or replace function kaleido.bot_play(label text default '🎮 Играть') returns jsonb
language sql stable as $$
  select jsonb_build_object('inline_keyboard', jsonb_build_array(jsonb_build_array(
    jsonb_build_object('text', label, 'web_app', jsonb_build_object('url', kaleido.cfg('webapp_url'))))))
$$;

-- Сообщение: HTML-текст и картинка-превью над текстом (если картинка недоступна, текст всё равно придёт).
create or replace function kaleido.bot_send(p_chat bigint, p_html text, p_img text, p_markup jsonb default null)
returns jsonb language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'method', 'sendMessage', 'chat_id', p_chat, 'text', p_html, 'parse_mode', 'HTML',
    'link_preview_options', case when kaleido.bot_img(p_img) is null then jsonb_build_object('is_disabled', true)
      else jsonb_build_object('url', kaleido.bot_img(p_img), 'prefer_large_media', true, 'show_above_text', true) end,
    'reply_markup', p_markup))
$$;

-- ---------- разделы ----------

create or replace function kaleido.bot_program_text() returns text
language plpgsql stable as $$
declare c jsonb := kaleido.bot_c(); part jsonb; it record; out text; now_ts timestamptz := now();
begin
  out := '<b>🗓 Программа · ' || kaleido.esc(c#>>'{conference,date_text}') || '</b>\n<i>' || kaleido.esc(c#>>'{conference,timezone_text}') || '</i>';
  for part in select * from jsonb_array_elements(c->'parts') loop
    out := out || '\n\n<b>' || kaleido.esc(part->>'title') || '</b>';
    for it in select * from kaleido.bot_items() where n between (part->>'from')::int and (part->>'to')::int order by n loop
      out := out || '\n' || case when now_ts >= it.starts and now_ts < it.ends then '▶️ ' else '' end
        || '<code>' || split_part(it.time_text, '–', 1) || '</code> ' || it.icon || ' ' || kaleido.esc(it.title);
    end loop;
  end loop;
  return replace(out, '\n', chr(10));
end $$;

create or replace function kaleido.bot_now_text() returns text
language plpgsql stable as $$
declare cur record; nxt record; first_it record; days int; out text; has_cur boolean; has_nxt boolean;
begin
  select * into first_it from kaleido.bot_items() order by n limit 1;
  if not found then return 'Программа пока не загружена.'; end if;
  if now() < first_it.starts then
    days := ceil(extract(epoch from first_it.starts - now()) / 86400.0);
    return kaleido.bot_t('before', jsonb_build_object('days', kaleido.plural(days, 'день', 'дня', 'дней'),
      'first_time', split_part(first_it.time_text, '–', 1)));
  end if;
  select * into cur from kaleido.bot_items() where now() >= starts and now() < ends order by n limit 1;
  has_cur := found;
  select * into nxt from kaleido.bot_items() where starts > now() order by starts limit 1;
  has_nxt := found;
  if not has_cur and not has_nxt then return kaleido.bot_t('after'); end if;
  out := '';
  if has_cur then
    out := '<b>Сейчас</b> · до ' || split_part(cur.time_text, '–', 2) || chr(10) || cur.icon || ' <b>' || kaleido.esc(cur.title) || '</b>'
      || coalesce(chr(10) || '<i>' || kaleido.esc(cur.note) || '</i>', '');
  end if;
  if has_nxt then
    out := out || case when out = '' then '' else chr(10) || chr(10) end
      || '<b>Дальше</b> · в ' || split_part(nxt.time_text, '–', 1)
      || ' (через ' || kaleido.plural(ceil(extract(epoch from nxt.starts - now()) / 60.0)::bigint, 'минуту', 'минуты', 'минут') || ')'
      || chr(10) || nxt.icon || ' ' || kaleido.esc(nxt.title);
  end if;
  return out;
end $$;

create or replace function kaleido.bot_bar(frac numeric, width int default 10) returns text
language sql immutable as $$
  select repeat('▰', round(greatest(0, least(1, frac)) * width)::int) || repeat('▱', width - round(greatest(0, least(1, frac)) * width)::int)
$$;

create or replace function kaleido.bot_score_text(p_user bigint) returns text
language plpgsql stable as $$
declare g kaleido.games; v_open int; v_rank int; v_total int; v_best int;
begin
  if kaleido.cfg('bot_score_mode', 'game') = 'link' then return kaleido.bot_t('score_link'); end if;
  select gm.* into g from kaleido.players pl join kaleido.games gm on gm.player_id = pl.id
    where pl.provider = 'telegram' and pl.external_id = p_user::text and gm.status in ('active', 'finished')
    order by (gm.status = 'active') desc, gm.created_at desc limit 1;
  if not found then return kaleido.bot_t('score_none'); end if;
  select count(*) into v_open from kaleido.answers where game_id = g.id and kind = 'open';
  -- место по лучшему результату среди всех участников
  with best as (select player_id, max(score) s from kaleido.games where status in ('active', 'finished') group by player_id)
  select count(*) filter (where s > g.score) + 1, count(*) into v_rank, v_total from best;
  return '<b>⭐ ' || g.score || ' ' || case when g.score % 10 = 1 and g.score % 100 <> 11 then 'балл' when g.score % 10 between 2 and 4 and g.score % 100 not between 12 and 14 then 'балла' else 'баллов' end || '</b>'
    || chr(10) || kaleido.bot_bar(g.answered::numeric / greatest(g.total, 1)) || ' ' || round(100.0 * g.answered / greatest(g.total, 1)) || '%'
    || chr(10) || 'Отвечено ' || g.answered || ' из ' || g.total || ' · верных ' || g.correct || ' · открытых ' || v_open
    || chr(10) || chr(10) || '🏅 Место: <b>' || v_rank || '</b> из ' || v_total
    || case when g.status = 'finished' then chr(10) || chr(10) || 'Калейдоскоп собран ✨' else '' end;
end $$;

create or replace function kaleido.bot_stats_text() returns text
language plpgsql stable as $$
declare out text; r record;
begin
  select '<b>📊 Статистика</b>' || chr(10)
    || 'В боте: ' || (select count(*) from kaleido.bot_chats) || ' · с уведомлениями: '
    || (select count(*) from kaleido.bot_chats where subscribed and not blocked)
    || case when kaleido.cfg('bot_score_mode', 'game') = 'link' then '' else chr(10)
    || 'Играют: ' || (select count(*) from kaleido.games where status = 'active')
    || ' · закончили: ' || (select count(*) from kaleido.games where status = 'finished') || chr(10)
    || 'Средний счёт: ' || coalesce((select round(avg(score))::text from kaleido.games where status = 'finished'), '—') end
  into out;
  for r in select topic, count(*) n, round(avg(stars), 1) a from kaleido.bot_ratings group by topic order by max(created_at) desc limit 8 loop
    out := out || chr(10) || chr(10) || kaleido.esc(r.topic) || chr(10) || kaleido.bot_bar(r.a / 5.0) || ' ' || r.a || ' ★ (' || r.n || ')';
  end loop;
  return out;
end $$;

-- Секрет вебхука из ключа входа: sha256('kaleido-webhook:' || telegram_webapp_secret).
create or replace function kaleido.bot_derived_secret() returns text
language sql stable as $$
  select case when kaleido.cfg('telegram_webapp_secret') ~ '^[0-9a-f]{64}$'
    then encode(sha256(convert_to('kaleido-webhook:' || kaleido.cfg('telegram_webapp_secret'), 'UTF8')), 'hex') end
$$;

-- ---------- главный обработчик ----------
-- Вход: {"secret": "<заголовок X-Telegram-Bot-Api-Secret-Token>", "update": {...}}.
-- Выход: метод Bot API ({"method": ...}) или {} — ничего не отвечать.
create or replace function kaleido.bot(b jsonb) returns jsonb
language plpgsql as $$
declare
  u jsonb := b->'update'; m jsonb; cq jsonb; v_chat bigint; v_user bigint; v_text text; v_cmd text;
  v_name text; v_parts text[]; v_stars int; v_is_admin boolean;
begin
  -- Секрет вебхука: заданный формой (bot_webhook_secret) или производный от ключа входа —
  -- его вычисляет страница tools/telegram-setup.html в браузере, без доступа к базе.
  if coalesce(b->>'secret', '') = '' or not ((b->>'secret') = any (array_remove(array[
      nullif(kaleido.cfg('bot_webhook_secret'), ''), kaleido.bot_derived_secret()], null))) then
    return '{}'::jsonb;
  end if;

  -- бота заблокировали / разблокировали
  if u ? 'my_chat_member' then
    update kaleido.bot_chats set blocked = (u#>>'{my_chat_member,new_chat_member,status}') in ('kicked', 'left')
      where chat_id = (u#>>'{my_chat_member,chat,id}')::bigint;
    return '{}'::jsonb;
  end if;

  -- нажатие инлайн-кнопки
  if u ? 'callback_query' then
    cq := u->'callback_query';
    v_parts := string_to_array(coalesce(cq->>'data', ''), ':');
    if v_parts[1] = 'rate' and array_length(v_parts, 1) >= 3 then
      v_stars := least(5, greatest(1, v_parts[array_length(v_parts, 1)]::int));
      insert into kaleido.bot_ratings (topic, chat_id, stars)
      values (array_to_string(v_parts[2:array_length(v_parts, 1) - 1], ':'), (cq#>>'{from,id}')::bigint, v_stars)
      on conflict (topic, chat_id) do update set stars = excluded.stars, created_at = now();
      return jsonb_build_object('method', 'answerCallbackQuery', 'callback_query_id', cq->>'id',
        'text', kaleido.bot_t('rated', jsonb_build_object('stars', repeat('★', v_stars) || repeat('☆', 5 - v_stars))));
    end if;
    return jsonb_build_object('method', 'answerCallbackQuery', 'callback_query_id', cq->>'id');
  end if;

  m := u->'message';
  if m is null or m#>>'{chat,type}' <> 'private' then return '{}'::jsonb; end if;
  v_chat := (m#>>'{chat,id}')::bigint;
  v_user := (m#>>'{from,id}')::bigint;
  v_name := nullif(btrim(concat_ws(' ', m#>>'{from,first_name}', m#>>'{from,last_name}')), '');
  insert into kaleido.bot_chats (chat_id, user_id, name, username)
  values (v_chat, v_user, v_name, m#>>'{from,username}')
  on conflict (chat_id) do update set name = excluded.name, username = excluded.username, last_seen_at = now(), blocked = false;

  v_text := btrim(coalesce(m->>'text', ''));
  v_cmd := lower(split_part(split_part(v_text, ' ', 1), '@', 1));
  v_is_admin := v_user::text = any (string_to_array(replace(kaleido.cfg('bot_admins'), ' ', ''), ','));

  if v_cmd in ('/start', '/menu') then
    return kaleido.bot_send(v_chat, kaleido.bot_t('welcome', jsonb_build_object('name', kaleido.esc(coalesce(m#>>'{from,first_name}', 'друг')))),
      'welcome.jpg', kaleido.bot_keyboard());
  elsif v_cmd = '/program' or v_text = '🗓 Программа' then
    return kaleido.bot_send(v_chat, kaleido.bot_program_text(), 'program.jpg');
  elsif v_cmd = '/now' or v_text = '⏱ Что сейчас' then
    return kaleido.bot_send(v_chat, kaleido.bot_now_text(), 'now.jpg');
  elsif v_cmd = '/about' or v_text = '✨ О конференции' then
    return kaleido.bot_send(v_chat, kaleido.bot_t('about'), 'about.jpg');
  elsif v_cmd = '/score' or v_text = '⭐ Мой счёт' then
    return kaleido.bot_send(v_chat, kaleido.bot_score_text(v_user), 'score.jpg',
      kaleido.bot_play(case when kaleido.cfg('bot_score_mode', 'game') = 'link' then '🎮 Открыть игру' else '🎮 Продолжить игру' end));
  elsif v_cmd in ('/howto', '/game') or v_text = '🎯 Как играть' then
    return kaleido.bot_send(v_chat, kaleido.bot_t('howto'), 'howto.jpg', kaleido.bot_play());
  elsif v_cmd = '/help' or v_text = '❓ Помощь' then
    return kaleido.bot_send(v_chat, kaleido.bot_t('help'), 'help.jpg');
  elsif v_cmd = '/stop' then
    update kaleido.bot_chats set subscribed = false where chat_id = v_chat;
    return kaleido.bot_send(v_chat, kaleido.bot_t('stop'), null);
  elsif v_cmd = '/notify' then
    update kaleido.bot_chats set subscribed = true where chat_id = v_chat;
    return kaleido.bot_send(v_chat, kaleido.bot_t('notify'), null);
  elsif v_cmd = '/stats' and v_is_admin then
    return kaleido.bot_send(v_chat, kaleido.bot_stats_text(), null);
  end if;
  return kaleido.bot_send(v_chat, kaleido.bot_t('fallback'), null, kaleido.bot_keyboard());
end $$;

-- ---------- рассылки ----------
-- Забирает всё, что пора отправить, и раскладывает по получателям. Вызывается раз в минуту.
create or replace function kaleido.bot_due() returns setof jsonb
language plpgsql as $$
declare bc record; it record; v_min int := kaleido.cfg('reminder_minutes', '10')::int; v_n int;
begin
  -- автоматические напоминания о блоках программы с notify: true
  if kaleido.cfg('program_reminders', 'true') = 'true' then
    for it in select * from kaleido.bot_items()
        where notify and starts - make_interval(mins => v_min) <= now() and starts > now() loop
      insert into kaleido.bot_program_sent (item_key) values (it.time_text || ' ' || it.title) on conflict do nothing;
      if found then
        insert into kaleido.bot_broadcasts (kind, text, image, audience, send_at)
        values ('message', kaleido.bot_t('reminder', jsonb_build_object('minutes', v_min, 'title', kaleido.esc(it.title)))
          || coalesce(chr(10) || '<i>' || kaleido.esc(it.note) || '</i>', ''), 'reminder.jpg', 'all', now());
      end if;
    end loop;
  end if;

  for bc in update kaleido.bot_broadcasts set sent_at = now()
      where id in (select id from kaleido.bot_broadcasts where sent_at is null and send_at <= now() order by send_at for update skip locked)
      returning * loop
    v_n := 0;
    return query
      select jsonb_build_object(
        'broadcast_id', bc.id, 'kind', bc.kind, 'chat_id', c.chat_id,
        -- картинка: невидимая ссылка в начале → Telegram показывает её превью
        'text', case when kaleido.bot_img(bc.image) is not null
          then '<a href="' || kaleido.bot_img(bc.image) || '">&#8205;</a>' else '' end || bc.text,
        'button_text', coalesce(nullif(bc.button_text, ''), '🎮 Играть'),
        'webapp_url', kaleido.cfg('webapp_url'),
        'topic', left(coalesce(bc.topic, 'general'), 40))
      from kaleido.bot_chats c
      left join kaleido.players pl on pl.provider = 'telegram' and pl.external_id = c.user_id::text
      left join lateral (select g.status, g.answered from kaleido.games g where g.player_id = pl.id
                         order by (g.status = 'active') desc, g.created_at desc limit 1) gm on true
      where c.subscribed and not c.blocked and (
        bc.audience = 'all'
        or (bc.audience = 'not_started' and coalesce(gm.answered, 0) = 0)
        or (bc.audience = 'unfinished' and gm.status = 'active' and gm.answered > 0)
        or (bc.audience = 'finished' and gm.status = 'finished'));
    get diagnostics v_n = row_count;
    update kaleido.bot_broadcasts set sent_count = v_n where id = bc.id;
  end loop;
end $$;

create or replace function kaleido.bot_mark_blocked(p_chat bigint) returns void
language sql as $$ update kaleido.bot_chats set blocked = true where chat_id = p_chat $$;

-- Настройка бота (Kaleido_Telegram_Setup): новый секрет вебхука + всё, что нужно передать в Bot API.
create or replace function kaleido.bot_setup() returns jsonb
language plpgsql as $$
declare v_secret text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  update kaleido.config set value = v_secret where key = 'bot_webhook_secret';
  return jsonb_build_object(
    'secret', v_secret,
    'webapp_url', kaleido.cfg('webapp_url'),
    'commands', jsonb_build_array(
      jsonb_build_object('command', 'menu', 'description', 'Главное меню'),
      jsonb_build_object('command', 'program', 'description', 'Программа конференции'),
      jsonb_build_object('command', 'now', 'description', 'Что идёт сейчас'),
      jsonb_build_object('command', 'score', 'description', 'Мой счёт в игре'),
      jsonb_build_object('command', 'about', 'description', 'О конференции'),
      jsonb_build_object('command', 'help', 'description', 'Помощь')),
    'description', 'Бот конференции УРСП «Год, в котором произошло всё»: программа, напоминания и игра «Калейдоскоп вопросов». Нажми «Начать».',
    'short_description', 'Программа конференции УРСП и игра «Калейдоскоп вопросов»');
end $$;

select jsonb_build_object('ok', true, 'step', '004_bot') as result;

-- ===== 005_bot_content =====
-- Тексты и программа бота. ФАЙЛ СОБИРАЕТСЯ АВТОМАТИЧЕСКИ из data/bot.json (npm run build) — правьте JSON.

insert into kaleido.bot_content (key, value, updated_at)
values ('content', $bot8ed4d521${"conference":{"name":"Конференция УРСП","date":"2026-12-08","date_text":"8 декабря","timezone":"Asia/Yekaterinburg","timezone_text":"время екатеринбургское"},"texts":{"welcome":"<b>Привет, {name}!</b>\n\nЭто бот конференции УРСП «Год, в котором произошло всё» — {date_text}.\n\nЗдесь программа, что идёт прямо сейчас, напоминания о главных блоках и игра <b>«Калейдоскоп вопросов»</b>: отвечай, прокручивай калейдоскоп и собирай свой узор.\n\nВыбирай раздел на клавиатуре внизу 👇","about":"<b>Год, в котором произошло всё</b>\n\nВ этом году изменений было больше, чем когда-либо. И все они сложились в одну большую картину.\n\nМы все разные и смотрим на неё с разных сторон — как стёклышки в калейдоскопе: по отдельности это кусочки цвета, а вместе — узор.\n\n<b>Что будет</b>\n🎤 Большие кейсы — один результат глазами нескольких ролей\n⚡ Pecha Kucha «Так исторически складывалось» — много коротких историй\n🤫 Секретный доклад\n🪞 Блоки о том, как мы видим себя и как видят нас\n🛠 Мастер-классы\n🏆 Премия «Герои УРСП»\n\n<b>Для онлайна</b> — своя игра внутри конференции: онлайн-бинго и «Калейдоскоп вопросов».","howto":"<b>Как играть в «Калейдоскоп вопросов»</b>\n\n1️⃣ Отвечай на вопрос — за верный ответ 10 ★\n2️⃣ Прокрути калейдоскоп пальцем — новый кристалл встанет на место, узор станет ярче\n3️⃣ В открытых вопросах пиши развёрнуто: чем подробнее, тем больше баллов, до 20 ★\n4️⃣ На финале — твой собственный узор, его можно сохранить картинкой\n\nПрогресс сохраняется: можно закрыть и продолжить позже.","help":"<b>Помощь</b>\n\nКнопки внизу — главное меню. Если клавиатура пропала, отправь /menu.\n\n/program — программа\n/now — что идёт сейчас\n/score — мой счёт в игре\n/stop — отключить напоминания, /notify — включить снова\n\nВопросы по конференции — организаторам: [черновик: контакт уточняется].","fallback":"Я пока не умею отвечать на сообщения 🙂\nВыбери раздел на клавиатуре внизу или отправь /menu.","score_none":"Ты ещё не начинал игру.\nНажми «🎮 Играть» — первый кристалл ждёт.","score_link":"Счёт, прогресс и место среди участников — в самой игре.\nНажми «🎮 Открыть игру».","stop":"Напоминания выключены. Включить снова — /notify.","notify":"Напоминания включены 🔔 Пришлю, когда начнутся главные блоки.","before":"До конференции — <b>{days}</b>.\nНачинаем {date_text} в {first_time} ({timezone_text}).","after":"Конференция завершилась. Спасибо, что были с нами! ✨\nКартина года сложилась — а калейдоскоп можно доиграть.","rated":"Спасибо! Твоя оценка: {stars}","reminder":"⏰ Через {minutes} минут: <b>{title}</b>"},"parts":[{"title":"Утро","from":1,"to":7},{"title":"До обеда","from":8,"to":14},{"title":"После обеда","from":15,"to":18},{"title":"Мастер-классы и финал","from":19,"to":25}],"program":[{"time":"10:00–10:06","icon":"🎬","title":"Видеооткрытие «Год, в котором произошло всё»","note":"Весь год — один большой калейдоскоп","notify":true},{"time":"10:06–10:09","icon":"🎙","title":"Ведущий: приветствие, бинго и игра"},{"time":"10:09–10:29","icon":"🎤","title":"Открытие. Лилия — «Картина целиком»","note":"Почему система менялась, какой эффект получили и куда идём"},{"time":"10:29–10:46","icon":"⚡","title":"Pecha Kucha «Так исторически складывалось»: ИИ-трансформация","note":"Много маленьких историй — одна большая картина"},{"time":"10:46–10:48","icon":"🎙","title":"Ведущий: новый формат докладов"},{"time":"10:48–11:08","icon":"🎤","title":"Большой кейс №1: «Свободная касса»","note":"Один результат глазами нескольких ролей","notify":true},{"time":"11:08–11:25","icon":"⚡","title":"Pecha Kucha «Так исторически складывалось»: УРР"},{"time":"11:25–11:55","icon":"☕","title":"Перерыв · онлайн-бинго · нетворкинг","note":"Первые итоги бинго для онлайна, общение — для зала","notify":true},{"time":"11:55–12:15","icon":"🎤","title":"Большой кейс №2: «ИИ-продавец»","notify":true},{"time":"12:15–12:32","icon":"⚡","title":"Pecha Kucha «Так исторически складывалось»: СКПП"},{"time":"12:32–12:34","icon":"🎙","title":"Ведущий"},{"time":"12:34–12:55","icon":"🤫","title":"Секретный доклад","note":"Взгляд с высоты всей системы продаж","notify":true},{"time":"12:55–13:10","icon":"🎲","title":"Онлайн-бинго: новые итоги и анонсы"},{"time":"13:10–14:00","icon":"🍽","title":"Обед","note":"В перерыве — номинанты премии «Герои УРСП»"},{"time":"14:00–14:25","icon":"🪞","title":"Тёплый блок «А что мы сами о себе думаем?»","notify":true},{"time":"14:25–14:50","icon":"🔥","title":"Острый блок: «Что думают о нас» и «Как я сломал систему»"},{"time":"14:50–15:15","icon":"🧩","title":"Блок про устойчивость [черновик: тема уточняется]"},{"time":"15:15–15:30","icon":"☕","title":"Перерыв · онлайн-бинго · нетворкинг"},{"time":"15:30–17:00","icon":"🛠","title":"Мастер-классы","notify":true},{"time":"17:00–17:20","icon":"☕","title":"Возвращение в зал"},{"time":"17:20–17:30","icon":"🎲","title":"Онлайн-бинго: награждение победителей","notify":true},{"time":"17:30–17:35","icon":"🎬","title":"Видео «Герои УРСП»"},{"time":"17:35–18:00","icon":"🏆","title":"Премия «Герои УРСП»","note":"Люди, которые создавали картину года","notify":true},{"time":"18:00–18:05","icon":"✨","title":"Финал","note":"Отойти назад и увидеть общую картину"},{"time":"18:05–20:00","icon":"🎉","title":"Неформальная часть [черновик: программа уточняется]"}]}$bot8ed4d521$::jsonb, now())
on conflict (key) do update set value = excluded.value, updated_at = now();

select jsonb_build_object('ok', true, 'step', '005_bot_content', 'program', jsonb_array_length(kaleido.bot_c()->'program')) as result;

-- ===== настройки для Supabase =====
-- Бот не видит базу игры (она в сети Контура): «Мой счёт» — кнопка в игру.
update kaleido.config set value = 'link' where key = 'bot_score_mode';
-- Картинки — из GitHub (Telegram не достаёт до GitLab Pages Контура).
update kaleido.config set value = 'https://raw.githubusercontent.com/Koptelev/bot_kaleido/main/images/' where key = 'bot_images_base';
-- Схема kaleido не открыта через Data API; закрываем и от ролей API на всякий случай.
revoke all on schema kaleido from anon, authenticated;
select jsonb_build_object('ok', true, 'step', 'supabase') as result;
