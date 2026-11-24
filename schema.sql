-- Kroswed schema. Run once in Supabase > SQL Editor.
create table public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  bio text not null default '' check (char_length(bio) <= 140),
  av int not null default 0 check (av between 0 and 5),
  pts int not null default 0, xp int not null default 0,
  done_easy int not null default 0, done_medium int not null default 0, done_hard int not null default 0,
  joined timestamptz not null default now());
create unique index profiles_username_lower on public.profiles(lower(username));
create table public.score_transactions(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  puzzle_key text not null, difficulty int not null,
  base_points int not null, hint_deduction int not null, final_points int not null,
  xp_awarded int not null, seconds int not null, created_at timestamptz not null default now(),
  unique(user_id, puzzle_key));
create table public.crossword_entries(
  id text primary key, category text not null, difficulty int not null,
  answer text not null, clue1 text not null, clue2 text not null);
alter table public.profiles enable row level security;
alter table public.score_transactions enable row level security;
alter table public.crossword_entries enable row level security;
revoke all on public.profiles, public.score_transactions, public.crossword_entries from anon, authenticated;
grant select on public.profiles to authenticated;
grant update(username, bio, av) on public.profiles to authenticated;
grant select on public.score_transactions to authenticated;
create policy "profiles readable" on public.profiles for select to authenticated using (true);
create policy "own profile update" on public.profiles for update to authenticated using (auth.uid()=id) with check (auth.uid()=id);
create policy "own transactions" on public.score_transactions for select to authenticated using (auth.uid()=user_id);
-- crossword_entries: RLS on, no policy => reachable only through the functions below.

create function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id, username)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', 'player'||substr(new.id::text,1,6)));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create function public.username_available(p_name text) returns boolean language sql security definer set search_path=public stable as $$
  select not exists(select 1 from public.profiles where lower(username)=lower(p_name)) $$;

create function public.submit_completion(p_fp text, p_diff int, p_hints int, p_pen int, p_secs int, p_words jsonb)
returns json language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); n int; ok int; base int; xpb int; fin int; xpg int; ins int; k text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_diff not in (1,2,3) then raise exception 'Invalid difficulty'; end if;
  if p_hints < 0 or p_hints > 60 or p_pen < 0 or p_pen > 200 then raise exception 'Invalid hint data'; end if;
  if jsonb_typeof(p_words) <> 'array' then raise exception 'Invalid submission'; end if;
  n := jsonb_array_length(p_words);
  if n < 5 or n > 12 then raise exception 'Invalid puzzle size'; end if;
  select count(distinct e.id), md5(string_agg(distinct e.id, ',' order by e.id)) into ok, k
    from jsonb_to_recordset(p_words) as w(id text, ans text)
    join public.crossword_entries e on e.id = w.id and e.answer = upper(w.ans);
  if ok <> n then raise exception 'Answers do not match the answer key'; end if;
  if p_secs < n * 3 then raise exception 'Completed too fast'; end if;
  if (select count(*) from public.score_transactions where user_id=uid and created_at > now() - interval '1 day') >= 60
    then raise exception 'Daily reward limit reached'; end if;
  base := case p_diff when 1 then 5 when 2 then 10 else 15 end;
  xpb  := 50 * p_diff;
  fin  := greatest(0, base - p_pen);
  xpg  := greatest(xpb/2, xpb - p_hints*5);
  insert into public.score_transactions(user_id, puzzle_key, difficulty, base_points, hint_deduction, final_points, xp_awarded, seconds)
    values (uid, k, p_diff, base, least(p_pen, base), fin, xpg, p_secs)
    on conflict (user_id, puzzle_key) do nothing;
  get diagnostics ins = row_count;
  if ins = 1 then
    update public.profiles set pts = pts + fin, xp = xp + xpg,
      done_easy = done_easy + (p_diff=1)::int, done_medium = done_medium + (p_diff=2)::int, done_hard = done_hard + (p_diff=3)::int
    where id = uid;
  end if;
  return json_build_object('awarded', ins=1, 'base', base, 'penalty', least(p_pen, base),
    'points', case when ins=1 then fin else 0 end, 'xp', case when ins=1 then xpg else 0 end);
end $$;

create function public.leaderboard(p_period text)
returns table(pos bigint, user_id uuid, username text, av int, xp int, pts bigint)
language sql security definer set search_path=public stable as $$
  with t as (
    select s.user_id, sum(s.final_points)::bigint as pts from public.score_transactions s
    where case p_period
      when 'day'  then (s.created_at at time zone 'Asia/Jakarta')::date = (now() at time zone 'Asia/Jakarta')::date
      when 'week' then date_trunc('week', s.created_at at time zone 'Asia/Jakarta') = date_trunc('week', now() at time zone 'Asia/Jakarta')
      else true end
    group by s.user_id having sum(s.final_points) > 0),
  r as (select rank() over (order by t.pts desc, p.xp desc) as pos, t.user_id, p.username, p.av, p.xp, t.pts
        from t join public.profiles p on p.id = t.user_id)
  select * from r where pos <= 100 or user_id = auth.uid() order by pos $$;

revoke execute on function public.submit_completion(text,int,int,int,int,jsonb), public.leaderboard(text), public.username_available(text) from public;
grant execute on function public.submit_completion(text,int,int,int,int,jsonb), public.leaderboard(text) to authenticated;
grant execute on function public.username_available(text) to anon, authenticated;

-- Seed answer key (generated from the game's content list)
insert into public.crossword_entries(id,category,difficulty,answer,clue1,clue2) values
('gk0','general_knowledge',1,'ATOM','Smallest unit of a chemical element','Basic building block of matter'),
('gk1','general_knowledge',1,'OXYGEN','Gas we breathe to live','Element with symbol O'),
('gk2','general_knowledge',1,'GRAVITY','Force that pulls objects toward Earth','Force linked to Newton’s falling apple'),
('gk3','general_knowledge',1,'PLANET','Body orbiting a star','Mars or Venus, for example'),
('gk4','general_knowledge',1,'VOLCANO','Mountain that erupts lava','Vent that spews magma and ash'),
('gk5','general_knowledge',1,'SKELETON','All the bones of the body','Framework of 206 bones in an adult'),
('gk6','general_knowledge',1,'HEART','Organ that pumps blood','Muscular organ in the chest'),
('gk7','general_knowledge',1,'PIANO','Instrument with 88 keys','Keyboard instrument with hammers and strings'),
('gk8','general_knowledge',1,'DOLPHIN','Intelligent marine mammal','Mammal that uses echolocation'),
('gk9','general_knowledge',1,'ENERGY','Capacity to do work','Quantity measured in joules'),
('gk10','general_knowledge',1,'MAGNET','Object that attracts iron','Has north and south poles'),
('gk11','general_knowledge',2,'NEURON','Nerve cell','Cell that transmits electrical signals'),
('gk12','general_knowledge',2,'GALAXY','Vast system of stars, like the Milky Way','Home to billions of stars'),
('gk13','general_knowledge',2,'ENZYME','Protein that speeds up reactions','Biological catalyst'),
('gk14','general_knowledge',2,'MITOSIS','Cell division producing identical cells','Process of body-cell division'),
('gk15','general_knowledge',2,'NEWTON','Unit of force','Physicist behind the laws of motion'),
('gk16','general_knowledge',2,'HELIUM','Second-lightest element','Noble gas used in balloons'),
('gk17','general_knowledge',2,'SONNET','Fourteen-line poem','Form Shakespeare used for 154 poems'),
('gk18','general_knowledge',2,'HAMLET','Shakespeare’s Danish prince','Tragedy set at Elsinore'),
('gk19','general_knowledge',2,'CARBON','Element with atomic number 6','Basis of organic chemistry'),
('gk20','general_knowledge',3,'PENICILLIN','Antibiotic discovered by Fleming','Mold-derived drug found in 1928'),
('gk21','general_knowledge',2,'TELESCOPE','Instrument for viewing distant stars','Galileo used one to see Jupiter’s moons'),
('gk22','general_knowledge',2,'DEMOCRACY','Government by the people','System of rule by elected representatives'),
('gk23','general_knowledge',2,'INFLATION','General rise in prices','Erosion of money’s purchasing power'),
('gk24','general_knowledge',3,'ENTROPY','Thermodynamic measure of disorder','Quantity that tends to rise in isolated systems'),
('gk25','general_knowledge',3,'PHOTON','Quantum of light','Massless particle of electromagnetic radiation'),
('gk26','general_knowledge',3,'ISOTOPE','Atom variant with a different neutron count','Carbon-14 is one'),
('gk27','general_knowledge',3,'CATALYST','Speeds a reaction without being consumed','Enzymes act as this'),
('gk28','general_knowledge',3,'RENAISSANCE','Cultural rebirth that began in Italy','Era of Leonardo and Michelangelo'),
('gk29','general_knowledge',3,'PARADIGM','Model or pattern of thinking','Kuhn’s term for a scientific framework'),
('gk30','general_knowledge',3,'SYNAPSE','Junction between two neurons','Gap crossed by neurotransmitters'),
('gk31','general_knowledge',3,'QUASAR','Extremely luminous galactic core','Bright object powered by a black hole'),
('gk32','general_knowledge',3,'HEMOGLOBIN','Oxygen-carrying protein in blood','Makes red blood cells red'),
('gk33','general_knowledge',3,'ALGORITHM','Step-by-step procedure for solving a problem','Word derived from al-Khwarizmi'),
('geo0','geography',1,'PARIS','Capital of France','City of the Eiffel Tower'),
('geo1','geography',1,'TOKYO','Capital of Japan','Japan’s largest city'),
('geo2','geography',1,'EGYPT','Country of the pyramids','Nation on the Nile in northeast Africa'),
('geo3','geography',1,'ASIA','Largest continent','Continent containing China and India'),
('geo4','geography',1,'NILE','River flowing through Egypt','Famous river of northeast Africa'),
('geo5','geography',1,'PACIFIC','Largest ocean','Ocean bordering Japan and California'),
('geo6','geography',1,'SAHARA','Largest hot desert','Desert spanning North Africa'),
('geo7','geography',1,'EVEREST','Highest mountain above sea level','Peak on the Nepal–Tibet border'),
('geo8','geography',1,'CANADA','Country with capital Ottawa','Nation north of the USA'),
('geo9','geography',1,'BRAZIL','Largest country in South America','Country where Brasília is the capital'),
('geo10','geography',1,'ITALY','Country shaped like a boot','Home of Rome and Venice'),
('geo11','geography',1,'AFRICA','Continent with 54 countries','Continent containing Kenya and Nigeria'),
('geo12','geography',1,'LONDON','Capital of the United Kingdom','City on the River Thames'),
('geo13','geography',1,'CAIRO','Capital of Egypt','City near the Giza pyramids'),
('geo14','geography',2,'AMAZON','South American river with the largest discharge','Rainforest river of Brazil and Peru'),
('geo15','geography',2,'DANUBE','River flowing through Vienna and Budapest','Second-longest river in Europe'),
('geo16','geography',2,'CANBERRA','Capital of Australia','Planned city chosen over Sydney and Melbourne'),
('geo17','geography',2,'ICELAND','Island nation of geysers and volcanoes','Country with capital Reykjavik'),
('geo18','geography',2,'ANDES','Longest continental mountain range','South American mountain chain'),
('geo19','geography',2,'BALTIC','Sea bordered by Sweden and Estonia','Sea north of Poland'),
('geo20','geography',2,'MADAGASCAR','Large island off Africa’s east coast','Home of lemurs'),
('geo21','geography',2,'JAKARTA','Capital of Indonesia','Megacity on Java’s northwest coast'),
('geo22','geography',2,'NAIROBI','Capital of Kenya','East African capital'),
('geo23','geography',2,'BAIKAL','Deepest lake in the world','Siberian lake'),
('geo24','geography',2,'ARCTIC','Ocean around the North Pole','Smallest of the world’s oceans'),
('geo25','geography',2,'GREENLAND','World’s largest island','Autonomous territory of Denmark'),
('geo26','geography',3,'KILIMANJARO','Highest mountain in Africa','Tanzanian volcano'),
('geo27','geography',3,'REYKJAVIK','Northernmost capital of a sovereign state','Capital of Iceland'),
('geo28','geography',3,'TITICACA','Lake on the Peru–Bolivia border','Highest large navigable lake'),
('geo29','geography',3,'MEKONG','River through Laos, Cambodia and Vietnam','Southeast Asian river ending in a delta'),
('geo30','geography',3,'KAZAKHSTAN','World’s largest landlocked country','Central Asian country with capital Astana'),
('geo31','geography',3,'ATACAMA','Extremely arid desert in Chile','South American desert'),
('geo32','geography',3,'BOSPHORUS','Strait dividing Istanbul','Waterway linking the Black Sea and Marmara'),
('geo33','geography',3,'PATAGONIA','Region at South America’s southern tip','Shared by Argentina and Chile'),
('geo34','geography',3,'SERENGETI','Tanzanian plain famed for wildebeest migration','East African savanna ecosystem'),
('geo35','geography',3,'LIECHTENSTEIN','Doubly landlocked Alpine microstate','Country between Switzerland and Austria'),
('geo36','geography',3,'ZAMBEZI','River with Victoria Falls','Major river of southern Africa'),
('geo37','geography',3,'HIMALAYAS','Range containing Everest','Mountains of Nepal and Bhutan');
