# Бот конференции УРСП · «Калейдоскоп вопросов»

Telegram: [@Kaleidoscope_of_URSP_bot](https://t.me/Kaleidoscope_of_URSP_bot)

Бот живёт в Supabase, потому что Telegram не может достучаться до серверов Контура. Игра остаётся в Контуре: кнопка «🎮 Играть» открывает её на телефоне участника, а участник для этого должен быть в VPN.

Что умеет бот:
- **Меню:** «Играть», «Программа», «Что сейчас», «О конференции», «Мой счёт», «Как играть», «Помощь».
- **Напоминания** за 10 минут до блоков программы.
- **Рассылки** по расписанию.
- **Оценки докладов** звёздами.
- **/stats** для админов.

## Как устроено

```
Telegram ──вебхук──▶ Supabase Edge Function «bot» ──▶ SQL kaleido.bot(): ответ
pg_cron (раз в минуту) ──▶ bot?tick=1 ──▶ kaleido.bot_due(): рассылки и напоминания → Telegram
```

| Файл | Что в нём |
|---|---|
| `supabase/functions/bot/index.ts` | Edge Function: вебхук, рассылки, самонастройка бота |
| `supabase/migrations/01_bot.sql` | схема `kaleido`: таблицы, логика бота, тексты и программа |
| `supabase/migrations/02_cron.sql` | расписание раз в минуту |
| `data/bot.json` | тексты и программа (исходник; в базе — таблица `kaleido.bot_content`) |
| `images/` | картинки к сообщениям; бот берёт их отсюда по ссылкам raw.githubusercontent.com |

Секрет один — токен бота. Он хранится в Supabase: Edge Functions → Secrets → `TELEGRAM_BOT_TOKEN`. В коде и в базе токена нет. Сменили токен в @BotFather — обновите секрет. Через минуту бот сам заново поставит вебхук, команды, кнопку «Играть» и описание.

## Управление (Supabase → SQL Editor)

```sql
-- кто может смотреть /stats (user_id — у @userinfobot)
update kaleido.config set value = '123456789,987654321' where key = 'bot_admins';

-- рассылка всем сейчас (картинка — имя файла из images/ или https-адрес)
insert into kaleido.bot_broadcasts (text, image) values ('<b>Игра открыта!</b> Заходи 💎', 'welcome.jpg');

-- рассылка по времени (время Екатеринбурга: +05)
insert into kaleido.bot_broadcasts (text, send_at) values ('Через час — финал!', '2026-12-08 17:00+05');

-- оценка доклада кнопками ★…★★★★★; результаты — /stats
insert into kaleido.bot_broadcasts (kind, text, topic) values ('rating', 'Как тебе открытие?', 'Открытие');

-- статистика
select count(*) from kaleido.bot_chats;
select topic, round(avg(stars), 2), count(*) from kaleido.bot_ratings group by topic;

-- выключить автонапоминания о программе
update kaleido.config set value = 'false' where key = 'program_reminders';
```

Аудитории `not_started`, `unfinished`, `finished` здесь не работают: бот не видит базу игры. Используйте `all`.

## Поменять тексты или программу

Supabase → Table Editor → схема `kaleido` → `bot_content` → строка `content` → поле `value` (JSON). Структура — как в `data/bot.json`:
- `texts` — тексты сообщений;
- `program` — пункты программы;
- `conference` — дата и часовой пояс.

Изменения применяются сразу. Потом обновите `data/bot.json` в репозитории, чтобы не разошлось.

## Проверка

- `https://uirpuiqcciivrtaefdbq.supabase.co/functions/v1/bot?tick=1` — `{"ok":true,...}`; в `log` видно, что сделано.
- Написать боту `/start`.
- Логи: Supabase → Edge Functions → bot → Logs.

## Ограничения бесплатного Supabase

- Проект на бесплатном тарифе ставится на паузу после недели без активности. Расписание раз в минуту и сообщения боту, скорее всего, считаются активностью, но перед конференцией проверьте статус проекта на главной странице Supabase.
- Edge Functions: 500 тысяч вызовов в месяц — с большим запасом.
