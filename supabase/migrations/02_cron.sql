-- Раз в минуту: рассылки, напоминания о программе и самонастройка бота (Edge Function bot, ?tick=1).
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

select cron.unschedule(jobid) from cron.job where jobname = 'kaleido-bot-tick';
select cron.schedule('kaleido-bot-tick', '* * * * *', $$
  select net.http_post(
    url := 'https://uirpuiqcciivrtaefdbq.supabase.co/functions/v1/bot?tick=1',
    body := '{}'::jsonb,
    headers := '{"content-type": "application/json"}'::jsonb,
    timeout_milliseconds := 120000)
$$);

-- Старые ответы pg_net не копим.
select cron.unschedule(jobid) from cron.job where jobname = 'kaleido-net-cleanup';
select cron.schedule('kaleido-net-cleanup', '17 3 * * *', $$ delete from net._http_response where created < now() - interval '1 day' $$);

select jsonb_build_object('ok', true, 'step', 'cron') as result;
