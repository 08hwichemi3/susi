-- ═══════════════════════════════════════════════════════════════
--  수시 지원 도우미 — 추가 기능 (한 번만 실행하면 됩니다)
--
--  Supabase → 프로젝트 → SQL Editor 에 이 파일을 통째로 붙여넣고 [Run] 하세요.
--  여러 번 실행해도 안전합니다(있으면 새로 덮어씁니다).
--  ★ 딱 하나, 맨 아래 ⑬번(plan_area 에 'tech' 추가)만은 예외입니다 —
--    그 문단 안의 안내를 따라 두 번에 나눠 실행하세요.
--
--  이 파일이 만드는 것
--    ① admin_create_teacher()   설정 화면에서 [교직원 계정 만들기] 를 쓸 수 있게 합니다
--    ② staff_logins()           교직원 목록에 아이디를 같이 보여 줍니다
--    ③ reset_teacher_password() 되돌린 초기 비밀번호를 화면에 알려 주도록 고칩니다
--    ④ reset_student_password() 학생 비밀번호를 생년월일·전화번호로 다시 맞춥니다
--    ⑤ set_student_contact()    선생님이 학생의 생년월일·전화번호를 바로잡습니다
--    ⑥ delete_staff()            교직원 계정을 완전히 지웁니다 (되돌릴 수 없음)
--    ⑦ delete_student()          학생 계정을 성적·지원계획까지 지웁니다 (되돌릴 수 없음)
--
--  모두 **총관리자(super_admin)만** 부를 수 있습니다. 담임이 불러도 서버가 막습니다.
-- ═══════════════════════════════════════════════════════════════

-- 초기 비밀번호. 바꾸고 싶으면 이 한 줄만 고치면 됩니다.
create or replace function public.initial_teacher_password()
returns text language sql immutable as $$ select '1111'::text $$;

-- 부르는 사람이 총관리자인지 확인한다. 아니면 여기서 멈춘다.
create or replace function public.assert_super_admin()
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_school uuid;
begin
  select school_id into v_school
    from public.profiles
   where id = auth.uid() and role = 'super_admin';
  if v_school is null then
    raise exception '총관리자만 할 수 있습니다';
  end if;
  return v_school;
end $$;

-- ───────── ① 교직원 계정 만들기 ─────────
-- 이름만 주면 **이름이 그대로 아이디**가 됩니다(한글 그대로 로그인 가능).
-- 같은 이름이 이미 있으면 이름을 「김담임2」 처럼 구분해서 넣어야 합니다.
-- 되돌려 주는 값: {"login": "...", "password": "...", "name": "...", "id": "..."}
create or replace function public.admin_create_teacher(
  p_name  text,
  p_login text     default null,
  p_kind  text     default 'general',   -- general | homeroom | all
  p_grade smallint default 3,
  p_class smallint default null
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_school uuid;
  v_login  text;
  v_pw     text := public.initial_teacher_password();
  v_id     uuid;
  n        int := 0;
begin
  v_school := public.assert_super_admin();

  if coalesce(btrim(p_name), '') = '' then
    raise exception '이름을 넣어 주세요';
  end if;

  v_login := lower(btrim(coalesce(p_login, '')));
  if v_login = '' then
    -- 아이디를 안 정했으면 이름이 그대로 아이디가 된다 (한글 로그인 확인함)
    v_login := lower(btrim(p_name));
    if exists (select 1 from auth.users
                where email = v_login || '@susi.local') then
      raise exception '같은 이름의 아이디가 이미 있습니다 — 이름 칸에 「%2」 처럼 구분해서 넣어 주세요', p_name;
    end if;
  else
    if v_login !~ '^[a-z0-9가-힣_.@-]{2,40}$' then
      raise exception '아이디는 한글·영문 소문자·숫자로 2~40자여야 합니다';
    end if;
    if exists (select 1 from auth.users
                where email = case when v_login like '%@%' then v_login
                                   else v_login || '@susi.local' end) then
      raise exception '이미 쓰고 있는 아이디입니다: %', v_login;
    end if;
  end if;

  -- 이미 쓰고 있는 create_teacher() 를 그대로 부른다.
  --   (학교, 아이디, 이름, 비밀번호, 총관리자인가)
  v_id := public.create_teacher(v_school, v_login, btrim(p_name), v_pw,
                                (p_kind = 'all'));

  -- 처음 들어갈 때 비밀번호를 반드시 바꾸게 한다
  update public.profiles
     set must_change_password = true
   where id = v_id;

  if p_kind = 'homeroom' and p_class is not null then
    insert into public.teacher_classes (teacher_id, school_id, grade, class_no)
    values (v_id, v_school, coalesce(p_grade, 3), p_class)
    on conflict do nothing;
  end if;

  return jsonb_build_object('id', v_id, 'login', v_login,
                            'password', v_pw, 'name', btrim(p_name));
end $$;

-- ───────── ② 교직원 아이디 목록 ─────────
create or replace function public.staff_logins()
returns table (id uuid, login text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_school uuid;
begin
  v_school := public.assert_super_admin();
  return query
    select p.id,
           -- 학교에서 만든 계정은 뒤에 @susi.local 이 붙어 있다. 화면에는 앞부분만.
           case when u.email like '%@susi.local'
                then split_part(u.email, '@', 1)
                else u.email end
      from public.profiles p
      join auth.users u on u.id = p.id
     where p.school_id = v_school
       and p.role <> 'student';
end $$;

-- ───────── ③ 교직원 비밀번호 되돌리기 ─────────
-- 예전 판은 아무 것도 돌려주지 않았습니다. 화면에서 "무엇으로 되돌아갔는지" 를
-- 그대로 보여 줄 수 있게 되돌린 값을 함께 줍니다.
drop function if exists public.reset_teacher_password(uuid);
create or replace function public.reset_teacher_password(p_teacher uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_school uuid;
  v_pw text := public.initial_teacher_password();
begin
  v_school := public.assert_super_admin();

  if p_teacher = auth.uid() then
    raise exception '본인 계정은 여기서 되돌릴 수 없습니다. 화면 위의 [비밀번호]를 쓰세요';
  end if;
  if not exists (select 1 from public.profiles
                  where id = p_teacher and school_id = v_school and role <> 'student') then
    raise exception '우리 학교 교직원이 아닙니다';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(v_pw, extensions.gen_salt('bf', 10)),
         updated_at = now()
   where id = p_teacher;

  update public.profiles set must_change_password = true where id = p_teacher;

  return jsonb_build_object('password', v_pw);
end $$;

-- ───────── ④ 학생 비밀번호 되돌리기 ─────────
-- 학생 비밀번호는 늘 「생년월일 6자리 + 전화번호 뒤 4자리」입니다.
-- 등록해 둔 값은 그대로 두고 비밀번호만 그 규칙으로 다시 맞춥니다.
create or replace function public.reset_student_password(p_student uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_school uuid;
  v_birth date;
  v_phone text;
  v_pw    text;
begin
  v_school := public.assert_super_admin();

  select birth_date, phone into v_birth, v_phone
    from public.profiles
   where id = p_student and school_id = v_school and role = 'student';

  if not found then
    raise exception '우리 학교 학생이 아닙니다';
  end if;
  if v_birth is null or coalesce(v_phone, '') = '' then
    raise exception '아직 생년월일·전화번호가 없습니다. [등록 초기화] 를 쓰면 학생이 직접 넣습니다';
  end if;

  v_pw := to_char(v_birth, 'YYMMDD')
       || right(regexp_replace(v_phone, '[^0-9]', '', 'g'), 4);

  update auth.users
     set encrypted_password = extensions.crypt(v_pw, extensions.gen_salt('bf', 10)),
         updated_at = now()
   where id = p_student;

  return jsonb_build_object('ok', true);
end $$;

-- ───────── ⑤ 학생 연락처 바로잡기 ─────────
-- 학생이 생년월일이나 전화번호를 잘못 넣어 못 들어올 때, 선생님이 고쳐 줍니다.
-- 고친 값이 곧 새 비밀번호가 됩니다(학생 비밀번호는 이 두 값에서 나옵니다).
-- 둘 다 null 로 주면 등록을 지웁니다 — 학생이 다음 로그인 때 다시 넣습니다.
create or replace function public.set_student_contact(
  p_student uuid,
  p_birth   date default null,
  p_phone   text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_school uuid;
  v_pw text;
begin
  v_school := public.assert_super_admin();

  if not exists (select 1 from public.profiles
                  where id = p_student and school_id = v_school and role = 'student') then
    raise exception '우리 학교 학생이 아닙니다';
  end if;

  if p_birth is null and coalesce(p_phone, '') = '' then
    update public.profiles
       set birth_date = null, phone = null, first_login_at = null
     where id = p_student;
    return jsonb_build_object('cleared', true);
  end if;

  if p_birth is null or coalesce(p_phone, '') = '' then
    raise exception '생년월일과 전화번호는 둘 다 넣거나 둘 다 비워야 합니다';
  end if;

  update public.profiles
     set birth_date = p_birth, phone = p_phone
   where id = p_student;

  v_pw := to_char(p_birth, 'YYMMDD')
       || right(regexp_replace(p_phone, '[^0-9]', '', 'g'), 4);

  update auth.users
     set encrypted_password = extensions.crypt(v_pw, extensions.gen_salt('bf', 10)),
         updated_at = now()
   where id = p_student;

  return jsonb_build_object('ok', true);
end $$;

-- ───────── ⑥ 교직원 계정 삭제 ─────────
-- 학교를 떠난 선생님의 계정을 완전히 지웁니다. 담당 반 설정도 같이 지웁니다.
-- 본인 계정은 못 지웁니다(마지막 총관리자가 사라지는 사고를 막습니다).
create or replace function public.delete_staff(p_staff uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_school uuid;
begin
  v_school := public.assert_super_admin();

  if p_staff = auth.uid() then
    raise exception '본인 계정은 지울 수 없습니다. 다른 분을 총관리자로 올린 뒤 그분에게 부탁하세요';
  end if;
  if not exists (select 1 from public.profiles
                  where id = p_staff and school_id = v_school and role <> 'student') then
    raise exception '우리 학교 교직원이 아닙니다';
  end if;

  delete from public.teacher_classes where teacher_id = p_staff;
  delete from public.profiles        where id = p_staff;
  delete from auth.users             where id = p_staff;

  return jsonb_build_object('ok', true);
end $$;

-- ───────── ⑦ 학생 계정 삭제 ─────────
-- 전학 등으로 나간 학생의 계정을 지웁니다.
-- 성적(내신·모의고사)과 지원계획도 같이 지워지며, 되돌릴 수 없습니다.
create or replace function public.delete_student(p_student uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_school uuid;
begin
  v_school := public.assert_super_admin();

  if not exists (select 1 from public.profiles
                  where id = p_student and school_id = v_school and role = 'student') then
    raise exception '우리 학교 학생이 아닙니다';
  end if;

  delete from public.applications   where student_id = p_student;
  delete from public.mock_exams     where student_id = p_student;
  delete from public.student_grades where student_id = p_student;
  delete from public.profiles       where id = p_student;
  delete from auth.users            where id = p_student;

  return jsonb_build_object('ok', true);
end $$;

-- ───────── 부를 수 있는 사람 ─────────
-- 함수 안에서 총관리자인지 다시 확인하므로, 실행 권한은 로그인한 사람에게 열어 둡니다.
revoke all on function public.admin_create_teacher(text, text, text, smallint, smallint) from public, anon;
revoke all on function public.staff_logins() from public, anon;
revoke all on function public.reset_teacher_password(uuid) from public, anon;
revoke all on function public.reset_student_password(uuid) from public, anon;
revoke all on function public.set_student_contact(uuid, date, text) from public, anon;
revoke all on function public.assert_super_admin() from public, anon;
revoke all on function public.delete_staff(uuid) from public, anon;
revoke all on function public.delete_student(uuid) from public, anon;

grant execute on function public.admin_create_teacher(text, text, text, smallint, smallint) to authenticated;
grant execute on function public.staff_logins() to authenticated;
grant execute on function public.reset_teacher_password(uuid) to authenticated;
grant execute on function public.reset_student_password(uuid) to authenticated;
grant execute on function public.set_student_contact(uuid, date, text) to authenticated;
grant execute on function public.delete_staff(uuid) to authenticated;
grant execute on function public.delete_student(uuid) to authenticated;

-- PostgREST 가 새 함수를 알아보게 한다 (안 하면 잠깐 "찾을 수 없습니다" 가 뜹니다)
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════
--    ⑧ schools.site_title  — 설정 화면에서 사이트 제목(브랜드명)을 바꿀 수 있게 합니다
--       (로그인 화면·브라우저 탭 제목·안쪽 헤더에 씁니다. 비어 있으면 "계획서"가 기본값)
-- ═══════════════════════════════════════════════════════════════
alter table public.schools add column if not exists site_title text;
comment on column public.schools.site_title is
  '로그인 화면·브라우저 탭·앱 안 브랜드에 쓰는 사이트 제목. 비어 있으면 기본값("계획서")을 쓴다.';

-- ═══════════════════════════════════════════════════════════════
--    ⑨ schools 에 update 정책이 없었습니다 — 설정 화면에서 학교 이름·사이트
--       제목을 저장해도 화면에는 "저장했습니다"가 뜨지만 실제로는 아무 것도
--       바뀌지 않는 문제가 있었습니다(update 를 막는 규칙이 없으면 조용히
--       0줄만 바뀌고 끝나며, 오류로 뜨지 않습니다). 총관리자만, 자기 학교
--       것만 고칠 수 있게 정책을 추가합니다.
-- ═══════════════════════════════════════════════════════════════
drop policy if exists schools_update_admin on public.schools;
create policy schools_update_admin on public.schools
  for update
  using (id = private.my_school() and private.my_role() = 'super_admin')
  with check (id = private.my_school() and private.my_role() = 'super_admin');

-- ═══════════════════════════════════════════════════════════════
--    ⑩ applications.final_date — 최종 발표일
--       전형 단계는 1단계 → 면접·실기·논술 → 최종 순인데 마지막 칸이 없었습니다.
--       달력이 읽는 형식은 'YYYY/MM/DD' 이며, 화면에서 자동으로 그 형식으로
--       맞춰 줍니다(1127 · 11/27 · 2026-11-27 → 2026/11/27).
-- ═══════════════════════════════════════════════════════════════
alter table public.applications add column if not exists final_date text;
comment on column public.applications.final_date is
  '최종 발표일. 1단계 → 면접/실기/논술 → 최종 순서의 마지막 단계 날짜.';

-- 칸을 새로 만들었으면 반드시 알려 줘야 합니다. 이 줄이 없으면 화면에서 저장할 때
-- "final_date 칸을 찾을 수 없다" 는 오류가 납니다(주소창 API 가 칸 목록을 캐둡니다).
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════
--    ⑪ site_brand() — 로그인 전 화면에 학교 이름·제목을 보여 주기 위한 함수
--       schools 는 로그인한 사람에게만 열려 있어서, 로그인 화면과 브라우저 탭
--       제목이 늘 기본값("계획서")으로만 보였습니다(링크를 받은 사람·처음
--       들어온 사람은 특히). 이름과 제목 두 칸만 내주는 함수를 두고 로그인
--       전에는 이것만 물어봅니다. 반 개수 등 나머지 정보는 그대로 잠겨 있습니다.
--       (로그인 화면에 어차피 적히는 값이라 공개해도 되는 정보입니다.)
--       학교 하나당 Supabase 프로젝트 하나를 쓰므로 가장 먼저 만들어진 학교를 줍니다.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.site_brand()
returns table (name text, site_title text)
language sql
security definer
set search_path = public
stable
as $$
  select s.name, s.site_title
  from public.schools s
  order by s.created_at
  limit 1
$$;

revoke all on function public.site_brand() from public;
grant execute on function public.site_brand() to anon, authenticated;

-- ═══════════════════════════════════════════════════════════════
--    ⑫ profiles.sees_all — 총관리자는 아니지만 전체 학생을 보는 교직원
--       담임은 자기 반만, 총관리자는 전체를 보는데, 그 사이(교감 선생님처럼
--       담임은 아니지만 전체를 봐야 하는 경우)가 없었습니다. role 은 그대로
--       'teacher' 로 두고 sees_all 만 true 로 켜면 됩니다 — 관리자 화면(계정
--       관리·설정)은 여전히 role='super_admin' 만 볼 수 있어 구분됩니다.
--       설정 화면의 [역할/반 설정] 에 "전체보기" 단추가 추가됩니다.
-- ═══════════════════════════════════════════════════════════════
alter table public.profiles add column if not exists sees_all boolean not null default false;
comment on column public.profiles.sees_all is '총관리자는 아니지만 전체 학생을 볼 수 있는 교직원(교감 등)';

create or replace function private.can_see_student(sid uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $$
  select
    sid = auth.uid()
    or exists (
      select 1 from profiles me, profiles st
      where me.id = auth.uid() and st.id = sid
        and me.role = 'super_admin' and me.school_id = st.school_id)
    or exists (
      select 1 from profiles me, profiles st
      where me.id = auth.uid() and st.id = sid
        and me.role = 'teacher' and me.sees_all = true and me.school_id = st.school_id)
    or exists (
      select 1 from profiles st
      join teacher_classes tc
        on tc.school_id = st.school_id
       and tc.grade = st.grade
       and tc.class_no = st.class_no
      where st.id = sid and tc.teacher_id = auth.uid())
$$;

create or replace function public.set_teacher_role(p_teacher uuid, p_kind text, p_grade smallint default 3, p_class smallint default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_school uuid; v_target_school uuid; v_n smallint;
begin
  if coalesce(private.my_role()::text,'') <> 'super_admin' then
    raise exception '역할 지정은 총관리자만 할 수 있습니다';
  end if;
  v_school := private.my_school();

  select school_id into v_target_school from profiles where id = p_teacher;
  if v_target_school is null then raise exception '그런 계정이 없습니다'; end if;
  if v_target_school is distinct from v_school then
    raise exception '다른 학교 계정은 건드릴 수 없습니다';
  end if;
  if (select role from profiles where id = p_teacher) = 'student' then
    raise exception '학생 계정에는 역할을 지정할 수 없습니다';
  end if;

  if p_teacher = auth.uid() and p_kind <> 'all' then
    raise exception '스스로 총관리자 권한을 내려놓을 수는 없습니다. 다른 분을 먼저 총관리자로 올려 주세요';
  end if;

  delete from teacher_classes where teacher_id = p_teacher;
  update profiles set sees_all = false where id = p_teacher;

  if p_kind = 'all' then
    update profiles set role = 'super_admin' where id = p_teacher;

  elsif p_kind = 'all_view' then
    update profiles set role = 'teacher', sees_all = true where id = p_teacher;

  elsif p_kind = 'general' then
    update profiles set role = 'teacher' where id = p_teacher;

  elsif p_kind = 'homeroom' then
    select class_count into v_n from schools where id = v_school;
    if p_class is null or p_class < 1 or p_class > v_n then
      raise exception '1~%반 사이에서 골라 주세요', v_n;
    end if;
    update profiles set role = 'teacher' where id = p_teacher;
    insert into teacher_classes (teacher_id, school_id, grade, class_no)
    values (p_teacher, v_school, coalesce(p_grade,3), p_class)
    on conflict do nothing;

  else
    raise exception '알 수 없는 역할입니다: %', p_kind;
  end if;
end $$;

-- 계정을 새로 만들 때도 '전체보기(비관리자)' 로 바로 만들 수 있게 p_kind 에
-- 'all_view' 를 추가합니다(기존 general|homeroom|all 은 그대로 동작합니다).
create or replace function public.admin_create_teacher(
  p_name  text,
  p_login text     default null,
  p_kind  text     default 'general',   -- general | homeroom | all | all_view
  p_grade smallint default 3,
  p_class smallint default null
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_school uuid;
  v_login  text;
  v_pw     text := public.initial_teacher_password();
  v_id     uuid;
  n        int := 0;
begin
  v_school := public.assert_super_admin();

  if coalesce(btrim(p_name), '') = '' then
    raise exception '이름을 넣어 주세요';
  end if;

  v_login := lower(btrim(coalesce(p_login, '')));
  if v_login = '' then
    v_login := lower(btrim(p_name));
    if exists (select 1 from auth.users
                where email = v_login || '@susi.local') then
      raise exception '같은 이름의 아이디가 이미 있습니다 — 이름 칸에 「%2」 처럼 구분해서 넣어 주세요', p_name;
    end if;
  else
    if v_login !~ '^[a-z0-9가-힣_.@-]{2,40}$' then
      raise exception '아이디는 한글·영문 소문자·숫자로 2~40자여야 합니다';
    end if;
    if exists (select 1 from auth.users
                where email = case when v_login like '%@%' then v_login
                                   else v_login || '@susi.local' end) then
      raise exception '이미 쓰고 있는 아이디입니다: %', v_login;
    end if;
  end if;

  v_id := public.create_teacher(v_school, v_login, btrim(p_name), v_pw,
                                (p_kind = 'all'));

  update public.profiles
     set must_change_password = true
   where id = v_id;

  if p_kind = 'homeroom' and p_class is not null then
    insert into public.teacher_classes (teacher_id, school_id, grade, class_no)
    values (v_id, v_school, coalesce(p_grade, 3), p_class)
    on conflict do nothing;
  end if;

  if p_kind = 'all_view' then
    update public.profiles set sees_all = true where id = v_id;
  end if;

  return jsonb_build_object('id', v_id, 'login', v_login,
                            'password', v_pw, 'name', btrim(p_name));
end $$;

notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════
--    ⑭ applications.manual_grade — 대학별로 다시 계산한 내신
--       대학마다 내신 반영 과목·가중치가 달라서, 앱이 쓰는 '계열 평균 내신'
--       하나로 상향/적정/하향을 판단하면 맞지 않는 경우가 있습니다. 그 대학
--       기준으로 다시 계산한 내신을 카드에 적어 두면 그 카드만 이 값으로
--       판정합니다(비워 두면 지금까지처럼 평균 내신을 씁니다).
-- ═══════════════════════════════════════════════════════════════
alter table public.applications add column if not exists manual_grade numeric;
comment on column public.applications.manual_grade is
  '이 대학 기준으로 다시 계산한 내신 등급. 비어 있으면 계열 평균 내신을 쓴다.';
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════
--    ⑬ plan_area 에 'tech' 추가 — 과학기술원(KAIST 등) 전용 칸
--       수시 지원은 원래 6회 제한이 있지만, 과학기술원(KAIST·GIST·DGIST·
--       UNIST)과 KENTECH 은 이 6회 제한과 무관한 특별법인 학교라 별도로
--       지원할 수 있습니다. 전문대(college)처럼 개수 제한이 없습니다.
--
--       ★★★ 이 문단만은 이 파일을 통째로 실행하면 안 됩니다 ★★★
--       Postgres 는 방금 추가한 열거형 값을 같은 실행(트랜잭션) 안에서 바로
--       쓰지 못합니다. 아래 두 덩어리를 따로따로(마우스로 골라서) 실행하세요.
--
--       1단계 — 이 줄만 마우스로 골라서 [Run]:
-- ═══════════════════════════════════════════════════════════════
alter type public.plan_area add value if not exists 'tech';

-- ═══════════════════════════════════════════════════════════════
--       2단계 — 1단계가 성공한 뒤, 아래 블록만 다시 골라서 [Run]:
-- ═══════════════════════════════════════════════════════════════
alter table public.applications drop constraint if exists applications_slot_range;
alter table public.applications add constraint applications_slot_range
  check (
    ((area = 'main'::plan_area) and (slot >= 1) and (slot <= 6))
    or ((area = 'cand'::plan_area) and (slot >= 1) and (slot <= 3))
    or ((area = 'college'::plan_area) and (slot >= 1))
    or ((area = 'tech'::plan_area) and (slot >= 1))
  );
notify pgrst, 'reload schema';
