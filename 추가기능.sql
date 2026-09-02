-- ═══════════════════════════════════════════════════════════════
--  수시 지원 도우미 — 추가 기능 (한 번만 실행하면 됩니다)
--
--  Supabase → 프로젝트 → SQL Editor 에 이 파일을 통째로 붙여넣고 [Run] 하세요.
--  여러 번 실행해도 안전합니다(있으면 새로 덮어씁니다).
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
